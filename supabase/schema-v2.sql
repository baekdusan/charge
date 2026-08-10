-- Charge 멀티유저 스키마 (v2)
-- 사용자별 데이터 격리(RLS) + 수집기 페어링. v1(tokenbar_*)과 독립적으로 공존한다.
--
-- 흐름:
--   앱(로그인) ── charge_create_pairing_code() ──▶ 6자리 코드 표시
--   수집기     ── charge_claim_pairing_code(코드) ─▶ 디바이스 토큰 발급 (해시만 저장)
--   수집기     ── charge_upload(토큰, 데이터) ────▶ 본인 행 upsert (5분 간격)
--   앱         ── RLS(user_id = auth.uid())로 본인 행만 select

create extension if not exists pgcrypto;

-- MARK: 수집기 인증 (데이터 테이블이 참조하므로 먼저 정의)

create table if not exists public.charge_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token_hash text not null unique,   -- sha256(토큰) — 원문은 저장하지 않는다
  label text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);

-- MARK: 데이터 테이블
-- daily/live는 디바이스(머신)별 행 — 여러 컴퓨터가 서로 덮어쓰지 않고, 앱이 날짜별로 합산해 표시한다.
-- providers는 계정 단위 값(레이트리밋·플랜)이라 최신 업로드가 덮어쓰는 게 맞다.

create table if not exists public.charge_daily (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.charge_devices(id) on delete cascade,
  period date not null,
  total_cost double precision not null default 0,
  total_tokens bigint not null default 0,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  cache_read_tokens bigint not null default 0,
  cache_creation_tokens bigint not null default 0,
  models jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id, period)
);

create table if not exists public.charge_live (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.charge_devices(id) on delete cascade,
  active_block jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

create table if not exists public.charge_providers (
  user_id uuid not null references auth.users(id) on delete cascade,
  id text not null,
  account text not null default '',  -- 프로바이더 계정 해시 — 머신마다 다른 계정이면 행(카드)이 분리된다
  name text not null,
  plan text,
  session jsonb,
  weekly jsonb,
  extras jsonb,
  status jsonb,
  device_id uuid references public.charge_devices(id) on delete cascade,  -- 마지막 보고 머신 (계정 전환·기기 삭제 시 유령 카드 정리용)
  device_label text,                 -- 이 계정을 마지막으로 보고한 머신 이름 (계정이 여럿일 때 앱에 표시)
  updated_at timestamptz not null default now(),
  primary key (user_id, id, account)
);

create table if not exists public.charge_pairing_codes (
  code text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  claimed_at timestamptz
);

-- 페어링 코드 무차별 대입 방지용 실패 카운터 (호출자 IP × 분 단위 버킷)
-- 호출자별로 세야 공격자 하나가 전체 페어링을 막지 못한다
create table if not exists public.charge_claim_failures (
  source text not null,
  minute timestamptz not null,
  count int not null default 0,
  primary key (source, minute)
);

-- Data API로 직접 조작하지 못하게 RLS 활성화 (정책 없음 = 함수 경유로만 접근)
alter table public.charge_claim_failures enable row level security;

-- MARK: RLS — 앱은 본인 행만 읽는다. 쓰기 정책은 없음(모든 쓰기는 RPC 경유)

alter table public.charge_daily enable row level security;
alter table public.charge_live enable row level security;
alter table public.charge_providers enable row level security;
alter table public.charge_devices enable row level security;
alter table public.charge_pairing_codes enable row level security;

drop policy if exists "own read" on public.charge_daily;
create policy "own read" on public.charge_daily
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "own read" on public.charge_live;
create policy "own read" on public.charge_live
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "own read" on public.charge_providers;
create policy "own read" on public.charge_providers
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "own read" on public.charge_devices;
create policy "own read" on public.charge_devices
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "own delete" on public.charge_devices;
create policy "own delete" on public.charge_devices
  for delete to authenticated using (user_id = auth.uid());

-- MARK: RPC

-- 앱(로그인 상태)이 호출: 10분짜리 페어링 코드 발급
-- 8자리, 혼동 문자(0/O/1/I/L) 제외 31자 알파벳 ≈ 40비트 — 무차별 대입에 실질적으로 안전
create or replace function public.charge_create_pairing_code()
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
  c text;
  raw bytea;
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  -- 만료된 지 하루 넘은 코드는 정리
  delete from charge_pairing_codes where expires_at < now() - interval '1 day';
  for attempt in 1..5 loop
    raw := gen_random_bytes(8);
    c := '';
    for j in 0..7 loop
      c := c || substr(alphabet, 1 + (get_byte(raw, j) % 31), 1);
    end loop;
    begin
      insert into charge_pairing_codes (code, user_id, expires_at)
      values (c, auth.uid(), now() + interval '10 minutes');
      return c;
    exception when unique_violation then
      -- 충돌 시 재시도
    end;
  end loop;
  raise exception 'could not generate code';
end $$;

-- 수집기(anon)가 호출: 코드를 소비하고 디바이스 토큰 발급.
-- 실패 시 예외 대신 null 반환 — 예외를 던지면 실패 카운터 기록까지 롤백되기 때문.
create or replace function public.charge_claim_pairing_code(p_code text, p_label text default null)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_uid uuid;
  v_dev uuid;
  v_fail int;
  v_source text;
  v_parts text[];
  tok text;
begin
  -- 기기 이름은 앱 목록에 그대로 표시되므로 길이를 제한한다 (실명·과도한 문자열 방어)
  p_label := left(trim(p_label), 64);
  -- 무차별 대입 방지: 호출자(IP)별로 최근 10분 실패 20회 초과 시 차단
  -- x-forwarded-for의 마지막 항목 = 게이트웨이가 덧붙인 실제 클라이언트 IP (앞쪽은 위조 가능)
  v_source := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
  v_parts := string_to_array(v_source, ',');
  v_source := trim(v_parts[array_length(v_parts, 1)]);
  select coalesce(sum(count), 0) into v_fail
  from charge_claim_failures
  where source = v_source and minute > now() - interval '10 minutes';
  if v_fail >= 20 then
    raise exception 'too many attempts, try again later';
  end if;
  delete from charge_claim_failures where minute < now() - interval '1 hour';

  -- 원자적 소비: 조건부 UPDATE라 같은 코드로 동시 요청이 와도 한 쪽만 성공한다
  update charge_pairing_codes
     set claimed_at = now()
   where code = upper(trim(p_code)) and claimed_at is null and expires_at > now()
  returning user_id into v_uid;

  if v_uid is null then
    insert into charge_claim_failures as f (source, minute, count)
    values (v_source, date_trunc('minute', now()), 1)
    on conflict (source, minute) do update set count = f.count + 1;
    return null;
  end if;

  tok := encode(gen_random_bytes(32), 'hex');
  -- 같은 머신(호스트명)이 다시 페어링하면 새 디바이스를 만들지 않고 토큰만 교체한다
  -- (재설치 후 같은 60일 기록이 새 디바이스로 중복 합산되는 것 방지)
  select id into v_dev from charge_devices
  where user_id = v_uid and label is not distinct from p_label
  order by created_at asc limit 1;
  if v_dev is not null then
    update charge_devices
       set token_hash = encode(digest(tok, 'sha256'), 'hex'), last_seen_at = null
     where id = v_dev;
  else
    insert into charge_devices (user_id, token_hash, label)
    values (v_uid, encode(digest(tok, 'sha256'), 'hex'), p_label);
  end if;
  return tok;
end $$;

-- 수집기(anon)가 호출: 디바이스 토큰으로 본인 행 upsert
create or replace function public.charge_upload(
  p_token text,
  p_daily jsonb default '[]'::jsonb,
  p_live jsonb default null,
  p_providers jsonb default '[]'::jsonb
)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_user uuid;
  v_device uuid;
  v_label text;
  v_hash text := encode(digest(p_token, 'sha256'), 'hex');
begin
  select user_id, id, label into v_user, v_device, v_label from charge_devices where token_hash = v_hash;
  if v_user is null then
    raise exception 'invalid device token';
  end if;

  -- 방어적 검증: anon 키가 공개돼 있어 가입자 누구나 유효 토큰을 얻을 수 있으므로,
  -- 행 폭증·거대 blob으로 저장소/비용을 부풀리는 것을 막는다. 정상 수집기 페이로드는
  -- daily 수십 행·providers 수 개·작은 blob이라 아래 상한에 한참 못 미친다.
  if jsonb_typeof(coalesce(p_daily, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_providers, '[]'::jsonb)) <> 'array' then
    raise exception 'invalid payload';
  end if;
  -- daily 상한은 period 필터 창(current_date-400~+2 = 403일)보다 넉넉히 커야
  -- --days 400 같은 정상 수집이 거부되지 않는다. 저장 행 수는 어차피 period 창이 묶는다.
  if jsonb_array_length(coalesce(p_daily, '[]'::jsonb)) > 500
     or jsonb_array_length(coalesce(p_providers, '[]'::jsonb)) > 100 then
    raise exception 'payload has too many rows';
  end if;
  if octet_length(coalesce(p_daily, '[]'::jsonb)::text) > 512 * 1024
     or octet_length(coalesce(p_providers, '[]'::jsonb)::text) > 256 * 1024
     or octet_length(coalesce(p_live, 'null'::jsonb)::text) > 64 * 1024 then
    raise exception 'payload too large';
  end if;

  update charge_devices set last_seen_at = now() where token_hash = v_hash;

  -- period를 합리적 범위로 제한(무한 과거/미래 행 방지)하고, 숫자는 음수·NaN·Infinity를
  -- 걷어내고, models blob은 행당 64KB로 제한한다. period 범위 + 기존 은퇴 로직이
  -- 디바이스당 charge_daily/charge_providers 행 수를 상수로 묶는다.
  insert into charge_daily (user_id, device_id, period, total_cost, total_tokens, input_tokens,
                            output_tokens, cache_read_tokens, cache_creation_tokens, models, updated_at)
  select v_user, v_device, s.period,
         -- Postgres는 NaN을 자기 자신과 '같고' 모든 값보다 '크게' 취급한다(IEEE754와 반대).
         -- 그래서 NaN 판별은 s.cost <> s.cost 가 아니라 s.cost = 'NaN' 이어야 한다.
         case when s.cost = 'NaN'::double precision or s.cost = 'Infinity'::double precision then 0
              else least(greatest(s.cost, 0), 1e12) end,
         greatest(s.toks, 0), greatest(s.inp, 0), greatest(s.outp, 0),
         greatest(s.cread, 0), greatest(s.ccreate, 0),
         case when octet_length(s.models::text) > 64 * 1024 then '[]'::jsonb else s.models end,
         now()
  from (
    select (d->>'period')::date as period,
           coalesce((d->>'total_cost')::double precision, 0) as cost,
           coalesce((d->>'total_tokens')::bigint, 0) as toks,
           coalesce((d->>'input_tokens')::bigint, 0) as inp,
           coalesce((d->>'output_tokens')::bigint, 0) as outp,
           coalesce((d->>'cache_read_tokens')::bigint, 0) as cread,
           coalesce((d->>'cache_creation_tokens')::bigint, 0) as ccreate,
           coalesce(d->'models', '[]'::jsonb) as models
    from jsonb_array_elements(p_daily) d
    where (d->>'period')::date between current_date - 400 and current_date + 2
  ) s
  on conflict (user_id, device_id, period) do update set
    total_cost = excluded.total_cost,
    total_tokens = excluded.total_tokens,
    input_tokens = excluded.input_tokens,
    output_tokens = excluded.output_tokens,
    cache_read_tokens = excluded.cache_read_tokens,
    cache_creation_tokens = excluded.cache_creation_tokens,
    models = excluded.models,
    updated_at = now();

  insert into charge_live (user_id, device_id, active_block, updated_at)
  values (v_user, v_device, p_live, now())
  on conflict (user_id, device_id) do update set
    active_block = excluded.active_block,
    updated_at = now();

  if jsonb_array_length(coalesce(p_providers, '[]'::jsonb)) > 0 then
    -- 계정 해시가 파악된 업로드가 오면, 같은 프로바이더의 계정 미상('') 행은 정리한다
    delete from charge_providers cp
    where cp.user_id = v_user and cp.account = ''
      and exists (select 1 from jsonb_array_elements(p_providers) p
                  where p->>'id' = cp.id and coalesce(p->>'account', '') <> '');

    -- 이 머신이 마지막으로 보고했던 행 중, 이번 업로드에 없는 (프로바이더, 계정)은 은퇴 처리
    -- (머신이 계정을 갈아탄 경우의 유령 카드 방지 — 다른 머신이 아직 쓰는 행은 그 머신이 계속 갱신한다)
    delete from charge_providers cp
    where cp.user_id = v_user and cp.device_id = v_device
      and not exists (select 1 from jsonb_array_elements(p_providers) p
                      where p->>'id' = cp.id and coalesce(p->>'account', '') = cp.account);

    -- 보고 머신 미기록(구버전) 행 정리 — 살아 있는 머신은 다음 5분 주기에 자기 행을 다시 채운다
    delete from charge_providers cp
    where cp.user_id = v_user and cp.device_id is null
      and exists (select 1 from jsonb_array_elements(p_providers) p where p->>'id' = cp.id);
  end if;

  insert into charge_providers (user_id, id, account, name, plan, session, weekly, extras, status, device_id, device_label, updated_at)
  select v_user, p->>'id', coalesce(p->>'account', ''), p->>'name', p->>'plan',
         p->'session', p->'weekly', p->'extras', p->'status', v_device, v_label, now()
  from jsonb_array_elements(p_providers) p
  on conflict (user_id, id, account) do update set
    name = excluded.name,
    plan = excluded.plan,
    session = excluded.session,
    weekly = excluded.weekly,
    extras = excluded.extras,
    status = excluded.status,
    device_id = excluded.device_id,
    device_label = excluded.device_label,
    updated_at = now();
end $$;

-- 함수 권한: 기본 public 실행 권한을 회수하고 필요한 롤에만 부여
revoke execute on function public.charge_create_pairing_code() from public;
grant execute on function public.charge_create_pairing_code() to authenticated;

revoke execute on function public.charge_claim_pairing_code(text, text) from public;
grant execute on function public.charge_claim_pairing_code(text, text) to anon, authenticated;

revoke execute on function public.charge_upload(text, jsonb, jsonb, jsonb) from public;
grant execute on function public.charge_upload(text, jsonb, jsonb, jsonb) to anon, authenticated;

-- 수집기(anon)가 호출: unpair 시 서버의 디바이스 토큰을 폐기한다.
-- 로컬 config만 지우면 그 토큰은 서버에서 계속 유효해, 유출 시 남이 업로드에 쓸 수 있다.
-- 토큰을 아는 주체만 자기 디바이스를 지운다(업로드와 같은 신뢰 모델). cascade로 데이터도 정리.
create or replace function public.charge_revoke_device(p_token text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  delete from charge_devices where token_hash = encode(digest(p_token, 'sha256'), 'hex');
end $$;

revoke execute on function public.charge_revoke_device(text) from public;
grant execute on function public.charge_revoke_device(text) to anon, authenticated;

-- MARK: 계정 삭제 (App Store 심사 요건)
-- 본인 auth.users 행을 지우면 charge_* 데이터가 전부 on delete cascade로 정리된다.
create or replace function public.charge_delete_account()
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.charge_delete_account() from public;
grant execute on function public.charge_delete_account() to authenticated;

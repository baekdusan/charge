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
  last_seen_at timestamptz,
  collect_status jsonb               -- 프로바이더 id → "ok"|"auth_expired"|"stale"|"error" (null = 미상, 구버전 수집기)
);

-- 기존 DB 마이그레이션 (create table if not exists는 기존 테이블에 컬럼을 더하지 않는다)
alter table public.charge_devices add column if not exists collect_status jsonb;

-- MARK: 데이터 테이블
-- daily/live는 디바이스(머신)별 행 — 여러 컴퓨터가 서로 덮어쓰지 않고, 앱이 날짜별로 합산해 표시한다.
-- providers는 계정 단위 값(레이트리밋, 플랜), 여러 기기가 한 행을 공유한다.
-- providers, live는 업로드 도착 순서가 아니라 수집 시각(collected_at)이 더 신선한 쪽만 덮어쓴다
-- (charge_upload의 신선도 규칙). 토큰 만료 기기의 캐시 폴백이 건강한 기기 데이터를 지우는 것 방지.
-- 단 live에서 "활성 블록 없음" 보고는 확정이라 신선도와 무관하게 즉시 비운다.

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
  collected_at timestamptz,          -- 이 블록을 실제로 관측한 시각 (null = 미상. 아래 신선도 규칙 참고)
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

-- 기존 DB 마이그레이션
alter table public.charge_live add column if not exists collected_at timestamptz;

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
  collected_at timestamptz,          -- 소스에서 실제로 수집된 시각 (null = collected_at 도입 전 수집기가 쓴 행)
  updated_at timestamptz not null default now(),
  primary key (user_id, id, account)
);

-- 기존 DB 마이그레이션
alter table public.charge_providers add column if not exists collected_at timestamptz;

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

-- 잘못된 타임스탬프 문자열이 섞여 와도 업로드 전체가 죽지 않게 null로 삼키는 파서
-- stable(immutable 아님): text::timestamptz 캐스트는 세션 TimeZone 설정에 의존한다
create or replace function public.charge_safe_ts(p text)
returns timestamptz
language plpgsql stable
as $$
begin
  return p::timestamptz;
exception when others then
  return null;
end $$;

-- 숫자/날짜도 같은 이유로 삼킨다: 값 하나가 캐스트에 실패하면 업로드 전체(daily/live/providers)가
-- 롤백돼 그 기기가 영구히 침묵한다. 못 읽는 값은 null로 떨구고 나머지는 살린다.
create or replace function public.charge_num(p text)
returns double precision
language plpgsql immutable
as $$
declare
  v double precision;
begin
  -- 캐스트는 반드시 begin 안에서, declare의 초기화식에서 터진 예외는 이 블록이 못 잡는다
  v := p::double precision;
  -- Postgres는 NaN을 모든 값보다 크게 취급해 greatest/least로 못 거른다(IEEE754와 반대)
  if v = 'NaN'::double precision or v = 'Infinity'::double precision or v = '-Infinity'::double precision then
    return null;
  end if;
  return v;
exception when others then
  return null;
end $$;

create or replace function public.charge_safe_date(p text)
returns date
language plpgsql stable
as $$
begin
  return p::date;
exception when others then
  return null;
end $$;

-- 수집 시각 정규화. null = "수집 시각 미상"이며, 신선도 판정에서 최신이 아니라 판정 유보로 쓰인다.
-- 미래 스탬프를 now()로 클램프하면 오히려 최고 신선도가 되어 시계 오차, 조작 하나로 남의 값을
-- 영구히 덮을 수 있다. 그래서 클램프가 아니라 미상으로 떨군다.
create or replace function public.charge_stamp(p text)
returns timestamptz
language plpgsql stable
as $$
declare
  t timestamptz := charge_safe_ts(p);
begin
  if t > now() + interval '2 minutes' then
    return null;
  end if;
  return t;
end $$;

-- 수집기(anon)가 호출: 디바이스 토큰으로 본인 행 upsert
-- 시그니처가 바뀌면 create or replace가 오버로드를 만들어 PostgREST RPC가 모호성 오류를 내므로 구버전을 먼저 지운다
drop function if exists public.charge_upload(text, jsonb, jsonb, jsonb);
create or replace function public.charge_upload(
  p_token text,
  p_daily jsonb default '[]'::jsonb,
  p_live jsonb default null,
  p_providers jsonb default '[]'::jsonb,
  p_collect_status jsonb default null
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
  -- collect_status: 프로바이더 id → 상태 문자열 평면 객체만 허용.
  -- 값 타입까지 잠근다 — 중첩 객체가 저장되면 앱의 [String: String] 디코딩이 터져
  -- 클라우드 데이터 로드 전체(기기 삭제 UI 포함)가 막힌다.
  if p_collect_status is not null
     and (jsonb_typeof(p_collect_status) <> 'object'
          or octet_length(p_collect_status::text) > 8 * 1024
          or exists (select 1 from jsonb_each(p_collect_status) kv
                     where jsonb_typeof(kv.value) <> 'string')) then
    raise exception 'invalid collect_status';
  end if;

  -- collect_status는 null이어도 그대로 덮는다 — 구버전 수집기의 미상은 미상으로 남긴다
  update charge_devices set last_seen_at = now(), collect_status = p_collect_status where token_hash = v_hash;

  -- period를 합리적 범위로 제한(무한 과거/미래 행 방지)하고, 숫자는 음수·NaN·Infinity를
  -- 걷어내고, models blob은 행당 64KB로 제한한다. period 범위 + 기존 은퇴 로직이
  -- 디바이스당 charge_daily/charge_providers 행 수를 상수로 묶는다.
  insert into charge_daily (user_id, device_id, period, total_cost, total_tokens, input_tokens,
                            output_tokens, cache_read_tokens, cache_creation_tokens, models, updated_at)
  select v_user, v_device, s.period,
         -- NaN/Infinity는 charge_num이 이미 null로 떨궈 coalesce가 0으로 받는다
         least(greatest(s.cost, 0), 1e12),
         least(greatest(s.toks, 0), 9e18)::bigint, least(greatest(s.inp, 0), 9e18)::bigint,
         least(greatest(s.outp, 0), 9e18)::bigint,
         least(greatest(s.cread, 0), 9e18)::bigint, least(greatest(s.ccreate, 0), 9e18)::bigint,
         case when octet_length(s.models::text) > 64 * 1024 then '[]'::jsonb else s.models end,
         now()
  from (
    -- 같은 period가 두 번 실리면 ON CONFLICT가 한 행을 두 번 건드려 SQLSTATE 21000으로 터지고
    -- 업로드 전체(daily/live/providers)가 롤백된다. 뒤에 온 항목을 채택해 서버에서 접는다.
    select distinct on (period) *
    from (
      select charge_safe_date(d->>'period') as period,
             coalesce(charge_num(d->>'total_cost'), 0) as cost,
             -- 토큰 컬럼은 bigint라 지수표기/범위초과 문자열 하나가 캐스트 실패로 업로드 전체를 죽인다.
             -- double로 받아 상한을 씌운 뒤 bigint로 내린다.
             coalesce(charge_num(d->>'total_tokens'), 0) as toks,
             coalesce(charge_num(d->>'input_tokens'), 0) as inp,
             coalesce(charge_num(d->>'output_tokens'), 0) as outp,
             coalesce(charge_num(d->>'cache_read_tokens'), 0) as cread,
             coalesce(charge_num(d->>'cache_creation_tokens'), 0) as ccreate,
             coalesce(d->'models', '[]'::jsonb) as models,
             ord
      from jsonb_array_elements(p_daily) with ordinality as t(d, ord)
      where charge_safe_date(d->>'period') between current_date - 400 and current_date + 2
    ) raw
    order by period, ord desc
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

  -- charge_live의 기본키는 (user_id, device_id), 기기마다 자기 행이라 다른 기기와 경쟁하지 않는다.
  -- 여기서 신선도 가드가 막는 것은 오직 하나, "자기 캐시 재업로드가 자기 최신값을 과거로 되돌리는 것".
  -- 그래서 p_live가 없으면(= "지금 활성 블록 없음"이라는 그 기기의 확정 보고) 가드 없이 항상 비운다.
  -- 가드를 걸면 블록이 끝나도 카드가 15~20분 더 살아남는다.
  -- live의 수집 시각은 p_live 안에 실려 온다, 파라미터를 더 늘리면 PostgREST 오버로드, 배포 순서 문제가 커진다.
  insert into charge_live as cl (user_id, device_id, active_block, collected_at, updated_at)
  select v_user, v_device, p_live, charge_stamp(p_live->>'collected_at'), now()
  on conflict (user_id, device_id) do update set
    active_block = excluded.active_block,
    collected_at = excluded.collected_at,
    updated_at = now()
  -- SQL NULL과 JSON null을 함께 잡는다(PostgREST가 어느 쪽으로 넘겨도 "블록 없음"은 같은 뜻)
  -- 비움 분기 외에는 providers와 똑같은 3분기 신선도 규칙을 쓴다. 낡은 스탬프를 무조건 통과시키면
  -- 방금 비운 행에 캐시 폴백의 묵은 블록이 다시 실려 카드가 부활한다.
  where coalesce(jsonb_typeof(p_live), 'null') = 'null'   -- 활성 블록 없음 보고는 언제나 반영(비움)
     or (excluded.collected_at is null
         and coalesce(cl.collected_at, '-infinity'::timestamptz) < now() - interval '15 minutes')
     or (excluded.collected_at is not null
         and excluded.collected_at > now() - interval '15 minutes'
         and excluded.collected_at >= coalesce(cl.collected_at, '-infinity'::timestamptz))
     or (excluded.collected_at is not null
         and excluded.collected_at <= now() - interval '15 minutes'
         and ((cl.collected_at is not null and excluded.collected_at >= cl.collected_at)
              or (cl.collected_at is null and cl.updated_at < now() - interval '15 minutes')));

  if jsonb_array_length(coalesce(p_providers, '[]'::jsonb)) > 0 then
    -- delete는 ON CONFLICT를 아예 우회한다(행이 사라지면 낡은 페이로드가 무조건 착지한다).
    -- 그래서 셋 다 "이미 묵은 행만" 지우도록 신선도/유예 조건을 건다.

    -- 계정 해시가 파악된 업로드가 오면, 같은 프로바이더의 계정 미상('') 행은 정리한다.
    -- 판정 기준은 '' 행의 나이가 아니라 "이번 업로드 항목이 지금 관측된 것인가"다. '' 행 기준으로
    -- 재면 매 주기 그 행을 갱신하는 기기가 하나라도 있는 한 조건이 영원히 안 서고, 스탬프가 없는
    -- 구버전 업로드도 계정 해시를 들고 왔는데 '' 카드를 못 지워 중복 카드가 남는다.
    -- 막아야 하는 건 낡은 캐시 폴백 업로드뿐이다.
    delete from charge_providers cp
    where cp.user_id = v_user and cp.account = ''
      and exists (select 1 from jsonb_array_elements(p_providers) p
                  where p->>'id' = cp.id and coalesce(p->>'account', '') <> ''
                    and (charge_stamp(p->>'collected_at') is null                              -- 구버전 = 지금 보고된 것으로 본다
                         or charge_stamp(p->>'collected_at') > now() - interval '15 minutes'));

    -- 이 머신이 마지막으로 보고했던 행 중, 이번 업로드에 없는 (프로바이더, 계정)은 은퇴 처리
    -- (머신이 계정을 갈아탄 경우의 유령 카드 방지 — 다른 머신이 아직 쓰는 행은 그 머신이 계속 갱신한다)
    -- 유예 20분: 한 주기 수집 실패로 프로바이더가 빠졌다고 카드가 즉시 증발하면 안 된다
    delete from charge_providers cp
    where cp.user_id = v_user and cp.device_id = v_device
      and cp.updated_at < now() - interval '20 minutes'
      and not exists (select 1 from jsonb_array_elements(p_providers) p
                      where p->>'id' = cp.id and coalesce(p->>'account', '') = cp.account);

    -- 보고 머신 미기록(구버전) 행 정리 — 살아 있는 머신은 다음 5분 주기에 자기 행을 다시 채운다
    delete from charge_providers cp
    where cp.user_id = v_user and cp.device_id is null
      and coalesce(cp.collected_at, '-infinity'::timestamptz) < now() - interval '15 minutes'
      and exists (select 1 from jsonb_array_elements(p_providers) p where p->>'id' = cp.id);
  end if;

  -- 신선도 가드: providers는 (user_id, id, account) 한 행을 여러 기기가 공유하므로 여기가 진짜
  -- 경쟁 지점이다. 토큰 만료 기기가 캐시 폴백(레이트리밋 창 드롭된 값)을 5분마다 올려 건강한 기기가
  -- 쓴 행을 덮는 것을 막는다. WHERE가 거짓이면 기존 행이 통째로 유지된다(아래 3분기 규칙).
  insert into charge_providers as cp (user_id, id, account, name, plan, session, weekly, extras, status, device_id, device_label, collected_at, updated_at)
  -- 한 페이로드에 같은 (id, account)가 두 번 오면 ON CONFLICT가 21000으로 터져 업로드 전체(daily, live 포함)가
  -- 롤백되므로 서버에서 접는다, 스탬프가 가장 신선한 항목만 남긴다(미상은 뒤로).
  select distinct on (p->>'id', coalesce(p->>'account', ''))
         v_user, p->>'id', coalesce(p->>'account', ''), p->>'name', p->>'plan',
         p->'session', p->'weekly', p->'extras', p->'status', v_device, v_label,
         charge_stamp(p->>'collected_at'), now()
  from jsonb_array_elements(p_providers) p
  order by p->>'id', coalesce(p->>'account', ''), charge_stamp(p->>'collected_at') desc nulls last
  on conflict (user_id, id, account) do update set
    name = excluded.name,
    plan = excluded.plan,
    status = excluded.status,
    -- device_id는 보존하지 않고 언제나 실제 마지막 기록자로 갱신한다. charge_providers.device_id는
    -- ON DELETE CASCADE라, 더 이상 쓰지 않는 기기를 계속 가리키게 두면 그 기기를 unpair하는 순간
    -- 여러 기기가 공유하던 카드가 통째로 사라진다.
    device_id = excluded.device_id,
    -- 레이트리밋 창이 비어 있는 업로드(만료 토큰 기기의 캐시 폴백)는 아직 리셋 전인 창을 지우지 못한다.
    -- 리셋 시각이 지나면 조건이 풀려 정상적으로 비워지니 유령 게이지는 생기지 않는다.
    -- 이번 업로드가 실린 창이 하나도 없다면 값의 출처(수집 시각, 보고 기기 이름)도 기존 것을 지켜야 한다 , 
    -- 어긋나면 앱이 옛 값을 "방금 이 기기가 수집" 으로 잘못 표시한다.
    (session, weekly, extras, collected_at, device_label) = (
      select case when k.keep_session then cp.session else excluded.session end,
             case when k.keep_weekly  then cp.weekly  else excluded.weekly  end,
             case when k.keep_extras  then cp.extras  else excluded.extras  end,
             case when k.keep_all then cp.collected_at else excluded.collected_at end,
             case when k.keep_all then cp.device_label else excluded.device_label end
      from (
        -- keep_all은 "세 창이 전부 보존됐는가"가 아니라 "이번 업로드가 기여한 창이 하나도 없는가"다.
        -- extras가 원래 없는 프로바이더(Codex는 항상, Claude도 weekly_scoped 한도가 없으면)는
        -- keep_extras가 영원히 거짓이라, 전자로 재면 창을 전부 보존하고도 collected_at을 빈 업로드
        -- 쪽으로 넘겨준다. 그러면 서버가 5분마다 스탬프를 새로 찍어 앱의 stale 판정이 영영 안 뜬다.
        select w.*,
               not (w.contributed_session or w.contributed_weekly or w.contributed_extras) as keep_all
        from (
          select
            coalesce(jsonb_typeof(excluded.session), 'null') <> 'null' as contributed_session,
            coalesce(jsonb_typeof(excluded.weekly), 'null')  <> 'null' as contributed_weekly,
            coalesce(jsonb_typeof(excluded.extras), 'null')  <> 'null' as contributed_extras,
            coalesce(jsonb_typeof(excluded.session), 'null') = 'null'
              and jsonb_typeof(cp.session) = 'object'
              and coalesce(charge_safe_ts(cp.session->>'resets_at'), '-infinity'::timestamptz) > now()
              as keep_session,
            coalesce(jsonb_typeof(excluded.weekly), 'null') = 'null'
              and jsonb_typeof(cp.weekly) = 'object'
              and coalesce(charge_safe_ts(cp.weekly->>'resets_at'), '-infinity'::timestamptz) > now()
              as keep_weekly,
            coalesce(jsonb_typeof(excluded.extras), 'null') = 'null'
              and jsonb_typeof(cp.extras) = 'array'
              and exists (select 1 from jsonb_array_elements(cp.extras) e
                          where charge_safe_ts(e->'window'->>'resets_at') > now())
              as keep_extras
        ) w
      ) k
    ),
    updated_at = now()
  -- 나이 미상(collected_at is null)을 '-infinity'로 깔면 아무리 오래된 스탬프라도 미상을 이겨서,
  -- 구버전 수집기의 정상값과 신버전의 며칠 묵은 스냅샷이 매 주기 교대로 이기며 카드가 깜빡인다.
  -- 그래서 "미상 = 가장 오래됨"이 아니라 "미상 = 나이를 모를 뿐 방금 보고된 값"으로 취급한다.
  where (
    -- 1) 신선한 스탬프: 더 오래된 스탬프든 나이 미상이든 전부 이긴다
    excluded.collected_at is not null
    and excluded.collected_at > now() - interval '15 minutes'
    and excluded.collected_at >= coalesce(cp.collected_at, '-infinity'::timestamptz)
  ) or (
    -- 2) 낡은 스탬프: 더 낡은 스탬프를 이긴다. 나이 미상 행은 그 행이 15분 넘게 방치됐을 때만 이긴다
    --    (미상 행이 매 주기 갱신되고 있으면 살아 있는 구버전 기기가 보고 중이므로 건드리지 않는다.
    --     반대로 아무도 갱신하지 않는 미상 행까지 지키면, 기기가 하나뿐인 사용자가 낡은 스냅샷
    --     스탬프만 올릴 때 카드가 영구히 얼어붙는다)
    excluded.collected_at is not null
    and excluded.collected_at <= now() - interval '15 minutes'
    and ((cp.collected_at is not null and excluded.collected_at >= cp.collected_at)
         or (cp.collected_at is null and cp.updated_at < now() - interval '15 minutes'))
  ) or (
    -- 3) 스탬프 없음(구버전): 상대가 나이 미상이거나 15분 넘게 묵었을 때만 이긴다
    --   , 구버전만 쓰는 사용자는 자기 행이 늘 미상이라 매 주기 정상 갱신된다
    excluded.collected_at is null
    and coalesce(cp.collected_at, '-infinity'::timestamptz) < now() - interval '15 minutes'
  );
end $$;

-- 함수 권한: 기본 public 실행 권한을 회수하고 필요한 롤에만 부여
revoke execute on function public.charge_create_pairing_code() from public;
grant execute on function public.charge_create_pairing_code() to authenticated;

revoke execute on function public.charge_claim_pairing_code(text, text) from public;
grant execute on function public.charge_claim_pairing_code(text, text) to anon, authenticated;

-- charge_safe_ts, charge_stamp는 내부 헬퍼, RPC로 노출할 이유가 없다 (charge_upload는 security definer라 소유자 권한으로 호출 가능)
revoke execute on function public.charge_safe_ts(text) from public;
revoke execute on function public.charge_stamp(text) from public;
revoke execute on function public.charge_num(text) from public;
revoke execute on function public.charge_safe_date(text) from public;

revoke execute on function public.charge_upload(text, jsonb, jsonb, jsonb, jsonb) from public;
grant execute on function public.charge_upload(text, jsonb, jsonb, jsonb, jsonb) to anon, authenticated;

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

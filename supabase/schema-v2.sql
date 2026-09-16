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
  installation_id text,              -- 수집기 설치 UUID — label(표시 이름)과 분리한 안정적인 기기 식별자
  label text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz,
  collect_status jsonb,              -- 프로바이더 id → "ok"|"shared"|"auth_expired"|"stale"|"error" 접두어 + ";키=값" 파라미터 (null = 미상, 구버전 수집기)
  collector_version text             -- 마지막으로 보고된 수집기 패키지 버전 (null = 미상, 0.2.0 이전 수집기)
);

-- 기존 DB 마이그레이션 (create table if not exists는 기존 테이블에 컬럼을 더하지 않는다)
alter table public.charge_devices add column if not exists collect_status jsonb;
alter table public.charge_devices add column if not exists installation_id text;
alter table public.charge_devices add column if not exists collector_version text;
-- 앱 설정 화면에 그대로 표시되는 값이라 길이와 문자 집합을 잠근다. charge_upload가 이미
-- 거르지만, 다른 쓰기 경로가 생겨도 같은 규칙을 지키게 제약으로도 둔다.
alter table public.charge_devices drop constraint if exists charge_devices_collector_version_check;
alter table public.charge_devices add constraint charge_devices_collector_version_check
  check (collector_version ~ '^[0-9A-Za-z.+-]{1,32}$');
-- 일회성 이행: 이 스키마보다 0.2.0 수집기가 먼저 올라온 기간에는 구버전 charge_upload가
-- "_collector" 키를 collect_status에 그대로 저장했다. charge_upload와 같은 규칙으로 컬럼에 옮기고
-- 키는 뗀다. 옮긴 뒤에는 키가 남지 않아 재실행해도 아무 행도 건드리지 않는다.
update public.charge_devices
   set collector_version = coalesce(
         collector_version,
         case when jsonb_typeof(collect_status->'_collector') = 'string'
                   and (collect_status->>'_collector') ~ '^[0-9A-Za-z.+-]{1,32}$'
              then collect_status->>'_collector'
         end),
       collect_status = collect_status - '_collector'
 where jsonb_typeof(collect_status) = 'object' and collect_status ? '_collector';
create unique index if not exists charge_devices_user_installation_id_key
  on public.charge_devices (user_id, installation_id) where installation_id is not null;

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
  device_id uuid references public.charge_devices(id) on delete set null, -- 호환용 정본 행의 마지막 보고 머신
  device_label text,                 -- 이 계정을 마지막으로 보고한 머신 이름 (계정이 여럿일 때 앱에 표시)
  collected_at timestamptz,          -- 소스에서 실제로 수집된 시각 (null = collected_at 도입 전 수집기가 쓴 행)
  updated_at timestamptz not null default now(),
  primary key (user_id, id, account)
);

-- 기존 DB 마이그레이션
alter table public.charge_providers add column if not exists collected_at timestamptz;

-- 기존 charge_providers의 CASCADE 제약을 SET NULL로 이행한다. 같은 계정을 여러 기기가
-- 보고할 때 마지막 보고 기기를 지웠다는 이유로 공유 카드까지 사라지면 안 된다.
alter table public.charge_providers drop constraint if exists charge_providers_device_id_fkey;
alter table public.charge_providers add constraint charge_providers_device_id_fkey
  foreign key (device_id) references public.charge_devices(id) on delete set null;

-- 기기별 원본 관측. charge_providers는 구버전 앱 호환용 계정 정본을 계속 제공하지만,
-- 새 구조는 각 기기의 관측을 먼저 보존한 뒤 읽을 때 계정별 최신값을 고른다.
-- payload는 검증된 p_providers 항목 하나이며 행 수는 기기×프로바이더×계정으로 제한된다.
create table if not exists public.charge_provider_observations (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.charge_devices(id) on delete cascade,
  provider_id text not null,
  account text not null,
  payload jsonb not null,
  collected_at timestamptz,
  last_reported_at timestamptz not null default now(),
  primary key (user_id, device_id, provider_id, account)
);

-- charge_upload의 14일 정리는 사용자 범위에서 last_reported_at으로 거른다. 기본키는
-- (user_id, device_id, ...)라 사용자 조건까지만 좁히고 나머지 행은 전부 읽어야 하므로,
-- 매 업로드마다 도는 정리가 오래된 행만 바로 찾게 둔다.
create index if not exists charge_provider_observations_user_last_reported_at_idx
  on public.charge_provider_observations (user_id, last_reported_at);

-- 기기 삭제로 카드를 정리하는 책임이 charge_providers의 CASCADE에서 이 테이블의
-- AFTER DELETE 트리거로 옮겨왔다. 이행 직후에는 관측이 한 행도 없어 트리거가 잡을 근거가
-- 없으므로, 그 사이에 기기를 지우면 카드가 device_id만 null인 채 영원히 남는다.
-- 마지막 보고 기기가 남아 있는 canonical 행을 한 번 백필해 두 구조를 같은 상태로 맞춘다.
-- 이미 업로드가 한 번이라도 돌았다면 do nothing이라 재실행에 안전하다.
insert into public.charge_provider_observations
  (user_id, device_id, provider_id, account, payload, collected_at, last_reported_at)
select cp.user_id, cp.device_id, cp.id, cp.account,
       jsonb_strip_nulls(jsonb_build_object(
         'id', cp.id,
         'name', cp.name,
         'plan', cp.plan,
         'session', cp.session,
         'weekly', cp.weekly,
         'extras', cp.extras,
         'status', cp.status
       )) || jsonb_build_object('account', cp.account),
       cp.collected_at,
       coalesce(cp.updated_at, now())
from public.charge_providers cp
where cp.device_id is not null
on conflict (user_id, device_id, provider_id, account) do nothing;

-- Claude 계정 전체를 막는 7일 한도가 100%였던 절대 시간 구간.
-- charge_providers는 최신 스냅샷만 남겨 리셋 뒤에는 "어제 하루 종일 못 썼다"는 사실이
-- 사라지므로, 스트릭 보호 판정에 필요한 최소 이력만 별도로 보존한다. 기기 행에 매달지
-- 않는 이유는 같은 계정을 여러 기기가 보고할 수 있고, 한 기기 연결 해제가 계정의
-- 과거 보호일까지 지우면 안 되기 때문이다. 5시간 세션/다른 프로바이더/모델별 한도는
-- 저장하지 않아 사용자당 최대 행 수를 120일에 약 18개(Claude 계정 하나 기준)로 묶는다.
-- 한 리셋 창에 구간이 여러 개일 수 있어(막힘 -> 한도 증액으로 풀림 -> 다시 막힘)
-- first_seen_at까지 키에 넣는다. 창당 한 행으로 뭉개면 둘 중 하나가 반드시 틀린다:
-- 해제 시각을 지우면 실제로 쓸 수 있었던 날까지 보호하고, 그대로 두면 재차단 뒤
-- 하루 종일 막힌 날을 놓친다.
create table if not exists public.charge_quota_blocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider_id text not null,
  account text not null default '',
  window_kind text not null check (window_kind = 'weekly'),
  reset_at timestamptz not null,
  observed_accounts text[] not null default '{}'::text[],
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null default now(),
  cleared_at timestamptz,
  primary key (user_id, provider_id, account, window_kind, reset_at, first_seen_at)
);

alter table public.charge_quota_blocks add column if not exists cleared_at timestamptz;
alter table public.charge_quota_blocks add column if not exists observed_accounts text[] not null default '{}'::text[];
-- 일회성 정리: window_kind는 도입 이래 'weekly'만 쓴다. 앞으로 창 종류를 늘린다면
-- 이 DELETE부터 지워야 한다. 안 그러면 스키마를 재실행하는 순간 새 종류가 조용히 사라진다.
delete from public.charge_quota_blocks where window_kind <> 'weekly';
alter table public.charge_quota_blocks drop constraint if exists charge_quota_blocks_window_kind_check;
alter table public.charge_quota_blocks add constraint charge_quota_blocks_window_kind_check
  check (window_kind = 'weekly');

-- 창당 한 행이던 구버전 키를 구간 키로 넓힌다. 기존 유일성이 새 유일성을 함의하므로
-- 충돌 없이 교체된다. 이미 넓혀진 DB에서는 아무것도 하지 않아 재실행에 안전하다.
do $$
declare
  v_def text;
  v_want constant text :=
    'PRIMARY KEY (user_id, provider_id, account, window_kind, reset_at, first_seen_at)';
begin
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.charge_quota_blocks'::regclass and c.contype = 'p';

  if v_def is distinct from v_want then
    alter table public.charge_quota_blocks drop constraint if exists charge_quota_blocks_pkey;
    alter table public.charge_quota_blocks
      add constraint charge_quota_blocks_pkey primary key
      (user_id, provider_id, account, window_kind, reset_at, first_seen_at);
  end if;
end $$;

-- 같은 Claude 리셋 시각도 기기별 API 응답에서 흔들린다. 반올림으로 접으면 30초 경계를
-- 사이에 둔 1초 차이가 서로 다른 분으로 갈려 같은 창이 두 행이 되므로, 절삭으로 통일하고
-- 새 구간을 열 때 2분 이내의 기존 리셋 시각을 재사용한다(charge_upload 참조).
-- 여기서는 초 성분이 남은 옛 행만 분 경계로 옮긴다. 이미 분 경계인 행은 건드리지 않아
-- 서로 다른 구간이 하나로 뭉개지지 않는다.
insert into public.charge_quota_blocks as target
  (user_id, provider_id, account, window_kind, reset_at, observed_accounts,
   first_seen_at, last_seen_at, cleared_at)
select distinct on (qb.user_id, qb.provider_id, qb.account, qb.window_kind,
                    date_trunc('minute', qb.reset_at), qb.first_seen_at)
       qb.user_id, qb.provider_id, qb.account, qb.window_kind,
       date_trunc('minute', qb.reset_at),
       qb.observed_accounts, qb.first_seen_at, qb.last_seen_at, qb.cleared_at
from public.charge_quota_blocks qb
where qb.reset_at <> date_trunc('minute', qb.reset_at)
order by qb.user_id, qb.provider_id, qb.account, qb.window_kind,
         date_trunc('minute', qb.reset_at), qb.first_seen_at, qb.last_seen_at desc
on conflict (user_id, provider_id, account, window_kind, reset_at, first_seen_at) do update set
  observed_accounts = (
    select coalesce(array_agg(a order by a), '{}'::text[])
    from (
      select distinct known.account as a
      from unnest(target.observed_accounts || excluded.observed_accounts) known(account)
      order by 1
      limit 32
    ) capped
  ),
  last_seen_at = greatest(target.last_seen_at, excluded.last_seen_at),
  cleared_at = case
    when target.cleared_at is null or excluded.cleared_at is null then null
    else greatest(target.cleared_at, excluded.cleared_at)
  end;

delete from public.charge_quota_blocks
where reset_at <> date_trunc('minute', reset_at);

-- 위 정규화는 초 성분이 남은 행만 건드리므로, 이미 분 경계였던 기존 행의 계정 배열은
-- 상한을 넘긴 채로 남는다. 멱등한 UPDATE로 따로 자른다.
update public.charge_quota_blocks qb
set observed_accounts = (
  select coalesce(array_agg(a order by a), '{}'::text[])
  from (
    select distinct known.account as a
    from unnest(qb.observed_accounts) known(account)
    order by 1
    limit 32
  ) capped
)
where cardinality(qb.observed_accounts) > 32;

-- 기기 삭제 cascade로 마지막 관측이 사라질 때만 호환용 canonical도 정리한다.
-- 같은 계정의 다른 기기 관측이 하나라도 있으면 canonical은 유지되어 구버전 앱도 끊기지 않는다.
-- security definer 함수는 search_path를 public, extensions, pg_temp로 고정한다. pg_temp를 명시하지
-- 않으면 임시 스키마가 맨 앞에서 검색되어, 임시 테이블을 만들 수 있는 호출자가 같은 이름의
-- 테이블로 함수 안의 참조를 가로챌 수 있다. 맨 뒤에 두면 가장 나중에 검색된다.
create or replace function public.charge_cleanup_provider_observation()
returns trigger
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
begin
  if not exists (
    select 1 from charge_provider_observations o
    where o.user_id = old.user_id
      and o.provider_id = old.provider_id
      and o.account = old.account
  ) then
    -- 위 not exists가 이미 "이 계정을 보는 관측이 하나도 남지 않았다"를 보장한다.
    -- 여기에 device_id 일치까지 요구하면, 기기 둘이 같은 계정을 보다가 canonical에
    -- 기록된 기기(A)의 관측이 먼저 사라지고 나중에 B의 관측이 사라졌을 때
    -- canonical.device_id가 여전히 A라 조건이 어긋나 카드가 영원히 남는다.
    delete from charge_providers p
    where p.user_id = old.user_id
      and p.id = old.provider_id
      and p.account = old.account;
  end if;
  return null;
end $$;

drop trigger if exists charge_cleanup_provider_observation on public.charge_provider_observations;
create trigger charge_cleanup_provider_observation
after delete on public.charge_provider_observations
for each row execute function public.charge_cleanup_provider_observation();

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

-- 수집기 자동 업데이트용 서명된 릴리스 목록. 배포 도구(collector/scripts/publish-manifest.js)가
-- DB 비밀번호로 직접 upsert하고, 수집기는 charge_latest_collector()로 최신 한 행만 읽는다.
-- 서명(Ed25519, "charge-connect-release/v1\n" + key_id + "\n" + version + "\n" + integrity + "\n"
-- + tarball)은 수집기가 key_id로 고른 내장 공개키로 검증하므로 이 테이블이 오염돼도 서명 없는
-- 코드는 설치되지 않는다. 수집기는 모르는 key_id를 거부하므로, 키를 바꿀 때는 새 공개키를 실은
-- 수집기를 먼저 퍼뜨린 뒤 새 key_id로 서명한 행을 게시한다.
-- 아래 형식 제약은 보안 경계가 아니다. 잘못 만든 행 하나가 전 기기에서 조용히 검증 실패로
-- 버려지기 전에, 게시하는 순간 오류로 드러나게 하는 장치다(수집기가 서명 검증 전에 거르는 형식과 같다).
-- 버전 문법은 collector/updater.js parseReleaseVersion과 같아야 한다(조각마다 0 또는 앞자리 0 없는
-- 1~6자리). 더 느슨하면 psql로 직접 넣은 "1.02.0" 같은 행이 통과한 뒤 전 기기에서 거부되고,
-- 최신 한 행만 읽으므로 그 행을 지울 때까지 모든 자동 업데이트가 멈춘다. 숫자는 \d가 아니라
-- [0-9]로 쓴다. 로캘에 따라 \d가 ASCII 밖의 숫자까지 받으면 수집기(JavaScript \d)보다 느슨해진다.
-- key_id는 맨 뒤 컬럼이다. 기존 DB에는 아래 add column이 끝에 붙이므로, 새로 만든 DB와
-- 컬럼 순서가 같아야 컬럼 목록 없는 insert나 select *가 환경마다 다르게 동작하지 않는다.
create table if not exists public.charge_collector_releases (
  version text primary key,
  integrity text not null,           -- npm dist.integrity ("sha512-" + base64)
  tarball text not null,             -- npm 레지스트리 tgz URL, 버전과 정확히 일치해야 한다
  signature text not null,           -- 서명 원문 64바이트의 base64
  published_at timestamptz not null default now(),
  key_id text not null               -- 서명 키 식별자, 수집기에 내장된 공개키 맵의 키 (예: k1)
);

-- 기존 DB 마이그레이션. key_id가 없던 행은 옛 서명 형식이라 어떤 수집기도 검증하지 못한다.
-- 수집기는 최신 한 행만 읽으므로 그런 행이 남으면 모든 자동 업데이트가 그 행에서 멈춘다.
-- 그 형식은 운영에 게시된 적이 없어 지워도 잃는 릴리스가 없고, 필요하면 게시 도구로 다시
-- 서명해 올리면 된다. 한 번 적용한 뒤에는 key_id가 not null이라 재실행해도 아무 행도 건드리지 않는다.
alter table public.charge_collector_releases add column if not exists key_id text;
delete from public.charge_collector_releases where key_id is null;
alter table public.charge_collector_releases alter column key_id set not null;

alter table public.charge_collector_releases enable row level security;
alter table public.charge_collector_releases drop constraint if exists charge_collector_releases_format_check;
alter table public.charge_collector_releases add constraint charge_collector_releases_format_check check (
  key_id ~ '^[a-z0-9]{1,16}$'
  and version ~ '^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$'
  and integrity ~ '^sha512-[A-Za-z0-9+/]{86}==$'
  and tarball = 'https://registry.npmjs.org/charge-connect/-/charge-connect-' || version || '.tgz'
  and signature ~ '^[A-Za-z0-9+/]{86}==$'
);

-- Claude 사용량 요청 분담용 임대(poll lease). 같은 사용자의 기기 중 한 대만 한 계정을 읽게 한다.
-- 쓰기는 charge_claim_poll()만 하고 클라이언트가 읽을 일도 없어 정책을 두지 않는다.
-- 사용자 범위 키라 다른 사용자의 임대와는 절대 겹치지 않는다(아래 함수 주석 참고).
create table if not exists public.charge_poll_leases (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider_id text not null,
  account text not null,             -- 프로바이더 계정 해시 (unknown:*은 받지 않는다)
  device_id uuid not null references public.charge_devices(id) on delete cascade, -- 지금 임대를 쥔 기기
  expires_at timestamptz not null,   -- DB 시계 기준 만료 시각 (기기 시계는 쓰지 않는다)
  primary key (user_id, provider_id, account)
);

alter table public.charge_poll_leases enable row level security;

-- MARK: RLS — 앱은 본인 행만 읽는다. 쓰기 정책은 없음(모든 쓰기는 RPC 경유)

alter table public.charge_daily enable row level security;
alter table public.charge_live enable row level security;
alter table public.charge_providers enable row level security;
alter table public.charge_provider_observations enable row level security;
alter table public.charge_quota_blocks enable row level security;
alter table public.charge_devices enable row level security;
alter table public.charge_pairing_codes enable row level security;

drop policy if exists "own read" on public.charge_daily;
create policy "own read" on public.charge_daily
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own read" on public.charge_live;
create policy "own read" on public.charge_live
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own read" on public.charge_providers;
create policy "own read" on public.charge_providers
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own read" on public.charge_provider_observations;
create policy "own read" on public.charge_provider_observations
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own read" on public.charge_quota_blocks;
create policy "own read" on public.charge_quota_blocks
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own read" on public.charge_devices;
create policy "own read" on public.charge_devices
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own delete" on public.charge_devices;
create policy "own delete" on public.charge_devices
  for delete to authenticated using (user_id = (select auth.uid()));

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
-- 구버전 두 인자 함수를 남겨두면 PostgREST가 기본 인자 함수와 구분하지 못하므로 먼저 제거한다.
drop function if exists public.charge_claim_pairing_code(text, text);
create or replace function public.charge_claim_pairing_code(
  p_code text,
  p_label text default null,
  p_install_id text default null
)
returns text
language plpgsql security definer set search_path = public, extensions, pg_temp
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
  p_install_id := nullif(lower(trim(p_install_id)), '');
  if p_install_id is not null
     and p_install_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'invalid installation id';
  end if;
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
  -- 신버전은 설치 UUID로만 같은 기기를 판정한다. 이름이 같은 별도 PC나 같은 PC의
  -- 다른 OS 사용자가 서로의 토큰을 폐기하면 안 된다. 첫 이행 때만 UUID가 없는 동일 라벨
  -- 레거시 행을 한 번 승계해 기존 60일 기록의 중복 합산을 막는다.
  if p_install_id is not null then
    select id into v_dev from charge_devices
    where user_id = v_uid and installation_id = p_install_id
    order by created_at asc limit 1;
    if v_dev is null then
      select id into v_dev from charge_devices
      where user_id = v_uid and installation_id is null and label is not distinct from p_label
      order by created_at asc limit 1;
    end if;
  else
    -- 구버전 수집기는 설치 UUID가 없다. 라벨만 보고 아무 행이나 고르면 같은 호스트명을 쓰는
    -- 다른 PC의 신형 기기 행을 빼앗아 그쪽 토큰을 무효화한다(그 기기는 다음 업로드부터
    -- invalid device token으로 멈춘다). 설치 UUID가 아직 없는 행, 즉 같은 구버전 계보만
    -- 승계하고 없으면 새 기기로 등록한다.
    select id into v_dev from charge_devices
    where user_id = v_uid and installation_id is null and label is not distinct from p_label
    order by created_at asc limit 1;
  end if;
  if v_dev is not null then
    update charge_devices
       set token_hash = encode(digest(tok, 'sha256'), 'hex'),
           installation_id = coalesce(p_install_id, installation_id),
           label = p_label,
           last_seen_at = null
     where id = v_dev;
  else
    insert into charge_devices (user_id, token_hash, installation_id, label)
    values (v_uid, encode(digest(tok, 'sha256'), 'hex'), p_install_id, p_label);
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
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid;
  v_device uuid;
  v_label text;
  v_collector text;
  v_hash text := encode(digest(p_token, 'sha256'), 'hex');
begin
  select user_id, id, label into v_user, v_device, v_label from charge_devices where token_hash = v_hash;
  if v_user is null then
    raise exception 'invalid device token';
  end if;

  -- 같은 사용자의 여러 기기 업로드만 짧게 직렬화한다. 계정 단위 한도 이력의
  -- dedupe/상한 정리가 동시에 엇갈려 중복 또는 상한 초과가 되는 것을 막는다.
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));

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
  -- 수집기 버전은 collect_status의 예약 키 "_collector"로 실려 온다. 파라미터를 늘리면
  -- PostgREST 오버로드와 배포 순서 문제가 커지므로(p_live 안의 collected_at과 같은 이유) 키로 받는다.
  -- 검증 전에 떼어 내 기기 컬럼으로 옮기므로 아래 8KB 상한과 문자열 값 검사는 나머지 키에만
  -- 걸린다. 형식이 틀린 버전은 업로드를 거부하지 않고 버린다(키가 없던 것과 같게 기존 값 유지).
  -- 값 하나가 이상하면 그 값만 떨구고 나머지는 살리는 charge_num, charge_stamp와 같은 원칙이다.
  if jsonb_typeof(p_collect_status) = 'object' and p_collect_status ? '_collector' then
    if jsonb_typeof(p_collect_status->'_collector') = 'string'
       and (p_collect_status->>'_collector') ~ '^[0-9A-Za-z.+-]{1,32}$' then
      v_collector := p_collect_status->>'_collector';
    end if;
    p_collect_status := p_collect_status - '_collector';
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

  -- 항목별 문자열 길이 상한. 페이로드 전체 바이트만 재면 짧은 요청 하나로도 파생 저장물이
  -- 요청 대비 수십 배로 부푼다(계정 문자열은 canonical, 관측, 한도 이력의 observed_accounts에
  -- 각각 복제된다). 원본을 여기서 한 번 자르면 이후 모든 참조가 같은 잘린 값을 쓰므로
  -- 테이블 사이에서 계정 키가 어긋나지 않는다. 정상 수집기 값은 계정 해시 16자, 이름 수십 자다.
  -- id가 없는 항목은 여기서 버린다. 그대로 두면 provider_id NOT NULL 위반으로 업로드
  -- 전체(daily, live 포함)가 롤백돼 그 기기가 영구히 침묵한다. 값 하나가 이상하면
  -- 그 값만 떨구고 나머지는 살리는 charge_num, charge_stamp와 같은 원칙이다.
  -- strip_nulls는 plan이 없던 프로바이더에 "plan": null 키를 새로 만들지 않게 한다.
  p_providers := coalesce((
    select jsonb_agg(
             p || jsonb_strip_nulls(jsonb_build_object(
               'id', left(p->>'id', 64),
               'name', left(p->>'name', 128),
               'plan', left(p->>'plan', 64),
               'account', left(coalesce(p->>'account', ''), 128)
             ))
             order by ord
           )
    from jsonb_array_elements(p_providers) with ordinality as t(p, ord)
    where jsonb_typeof(t.p) = 'object'
      and nullif(trim(t.p->>'id'), '') is not null
  ), '[]'::jsonb);

  -- collect_status는 null이어도 그대로 덮는다 — 구버전 수집기의 미상은 미상으로 남긴다
  -- 수집기 버전은 반대로 실려 온 경우에만 덮는다. 버전 키가 없는 업로드(구버전 수집기,
  -- p_collect_status를 뺀 재시도 경로)는 마지막으로 알려진 버전을 지우지 않는다.
  update charge_devices
     set last_seen_at = now(),
         collect_status = p_collect_status,
         collector_version = coalesce(v_collector, collector_version)
   where token_hash = v_hash;

  -- 같은 Claude 7일 리셋 창에서 사용률이 다시 100% 아래로 내려갔다면 플랜 변경·한도 증액 등으로
  -- 예상보다 일찍 풀린 것이다. reset_at까지 막혔다고 남기지 않도록 그 시각에 구간을 닫는다.
  update charge_quota_blocks qb set
    cleared_at = least(coalesce(qb.cleared_at, x.collected_at), x.collected_at),
    last_seen_at = greatest(qb.last_seen_at, now())
  from (
    select distinct on (p->>'id', coalesce(p->>'account', ''), w.kind)
           p->>'id' as provider_id, coalesce(p->>'account', '') as account,
           w.kind, charge_stamp(p->>'collected_at') as collected_at,
           charge_num(w.payload->>'percent') as percent
    from jsonb_array_elements(p_providers) p
    cross join lateral (values ('weekly', p->'weekly')) as w(kind, payload)
    where p->>'id' = 'claude' and jsonb_typeof(w.payload) = 'object'
    order by p->>'id', coalesce(p->>'account', ''), w.kind,
             charge_stamp(p->>'collected_at') desc nulls last
  ) x
  where qb.user_id = v_user
    and qb.provider_id = x.provider_id and qb.account = x.account and qb.window_kind = x.kind
    and qb.cleared_at is null and qb.reset_at > x.collected_at
    and x.collected_at > now() - interval '15 minutes'
    and x.collected_at >= qb.first_seen_at
    and x.percent < 100;

  -- 신선하게 직접 읽은 Claude 7일 한도만 이력으로 남긴다. 캐시 폴백의 묵은 100%를
  -- 지금 처음 발견한 것으로 저장하면 실제로 사용할 수 있었던 날까지 보호일이 되는 거짓
  -- 양성이 생긴다. 5시간 세션과 extras는 장기 스트릭 보호 대상이 아니며, 이를 제외하면
  -- 이력 행 수도 Claude 계정당 주 1개 이하로 제한된다.
  -- 한 요청에 같은 계정이 중복돼도 DISTINCT ON으로 한 행만 만들어 21000을 피한다.
  -- first_seen_at은 "이 창에 열려 있는 구간이 있으면 그 구간의 시작"이라 충돌이 나고
  -- 관측 시각만 갱신된다. 해제된 뒤 다시 100%가 되면 열린 구간이 없어 새 구간이 열린다.
  insert into charge_quota_blocks as qb
    (user_id, provider_id, account, window_kind, reset_at, observed_accounts, first_seen_at, last_seen_at)
  select distinct on (p->>'id', coalesce(p->>'account', ''), w.kind, n.reset_at)
         v_user, p->>'id', coalesce(p->>'account', ''), w.kind,
         n.reset_at,
         -- 이 구간에 "그때 함께 쓰이던 계정"을 박아 둔다. 앱은 여기 적힌 계정 전부가 그날
         -- 종일 막혔을 때만 스트릭을 보호한다. 그래서 곧 사라질 키를 넣으면 만족할 수 없는
         -- 조건이 되어 그 구간이 덮는 날의 보호가 통째로 꺼진다. 계정 미상('') 행과
         -- 이번 업로드 뒤 은퇴할 옛 계정 행은 아래 정리 구문이 곧 지우므로 제외한다.
         array(
           select distinct known.account
           from (
             select cp.account
             from charge_providers cp
             where cp.user_id = v_user and cp.id = 'claude'
               and cp.account <> ''
               and cp.updated_at > now() - interval '20 minutes'
             union all
             select q->>'account'
             from jsonb_array_elements(p_providers) q
             where q->>'id' = 'claude' and coalesce(q->>'account', '') <> ''
           ) known(account)
           where known.account is not null
           order by known.account
           limit 32
         ),
         coalesce(
           o.open_first_seen,
           greatest(r.collected_at, o.last_cleared_at + interval '1 microsecond')
         ), now()
  from jsonb_array_elements(p_providers) p
  cross join lateral (values ('weekly', p->'weekly')) as w(kind, payload)
  cross join lateral (
    select charge_stamp(p->>'collected_at') as collected_at,
           charge_safe_ts(w.payload->>'resets_at') as raw_reset,
           charge_num(w.payload->>'percent') as percent
  ) r
  -- 리셋 시각은 절삭으로 접되 2분 이내에 이미 기록된 값이 있으면 그것을 재사용한다.
  -- 반올림(30초 더하고 절삭)은 경계를 사이에 둔 1초 차이를 서로 다른 분으로 갈라
  -- 같은 창을 두 행으로 만든다. 절삭만 써도 분 경계에서 같은 문제가 남으므로,
  -- 기존 값 재사용이 실제 dedupe를 담당하고 절삭은 첫 관측의 표기만 정한다.
  cross join lateral (
    select coalesce(
             -- 저장된 값은 이미 절삭된 분 경계이므로 비교도 절삭값 기준으로 한다. 원시 시각
             -- 기준으로 재면 최대 59초의 절삭 손실만큼 창이 좁아져, 2분 안에 있는 값을
             -- 놓치고 새 행을 만든다.
             (select qb2.reset_at
                from charge_quota_blocks qb2
               where qb2.user_id = v_user and qb2.provider_id = p->>'id'
                 and qb2.account = coalesce(p->>'account', '') and qb2.window_kind = w.kind
                 and qb2.reset_at between date_trunc('minute', r.raw_reset) - interval '2 minutes'
                                      and date_trunc('minute', r.raw_reset) + interval '2 minutes'
               order by abs(extract(epoch from (qb2.reset_at - date_trunc('minute', r.raw_reset)))),
                        qb2.reset_at
               limit 1),
             date_trunc('minute', r.raw_reset)
           ) as reset_at
  ) n
  -- 새 구간의 시작은 수집 시각이지만, 방금 닫힌 구간과 시작이 겹치면 PK가 같아져
  -- 재차단이 조용히 무시된다(닫힌 행에 충돌해 last_seen만 갱신되고 cleared_at이 그대로 남는다).
  -- 마지막 해제 시각보다는 반드시 뒤로 밀어 구간이 항상 새로 열리게 한다.
  -- 아래 WHERE의 "해제 이후에 수집된 관측만" 가드가 있는 한 이 밀어내기는 실제로 발동하지
  -- 않는다(timestamptz 해상도가 마이크로초라 가드가 참이면 이미 1마이크로초 뒤다).
  -- 그 가드가 나중에 느슨해져도 PK 충돌로 구간이 사라지지 않게 남겨 두는 이중 방어다.
  cross join lateral (
    select (select qb3.first_seen_at
              from charge_quota_blocks qb3
             where qb3.user_id = v_user and qb3.provider_id = p->>'id'
               and qb3.account = coalesce(p->>'account', '') and qb3.window_kind = w.kind
               and qb3.reset_at = n.reset_at and qb3.cleared_at is null
             order by qb3.first_seen_at desc
             limit 1) as open_first_seen,
           (select max(qb4.cleared_at)
              from charge_quota_blocks qb4
             where qb4.user_id = v_user and qb4.provider_id = p->>'id'
               and qb4.account = coalesce(p->>'account', '') and qb4.window_kind = w.kind
               and qb4.reset_at = n.reset_at) as last_cleared_at
  ) o
  where p->>'id' = 'claude'
    and jsonb_typeof(w.payload) = 'object'
    and charge_num(w.payload->>'window_minutes') >= 10080
    and r.percent >= 100
    and r.collected_at > now() - interval '15 minutes'
    and n.reset_at > now()
    and n.reset_at <= now() + interval '45 days'
    -- 새 구간은 마지막 해제 이후에 수집된 관측만 열 수 있다. 다른 기기가 해제보다 먼저
    -- 읽어둔 100%를 조금 늦게 올리면(15분 창 안에서 순서가 뒤집히면) 이미 풀린 한도를
    -- 다시 막힌 것으로 기록하게 된다. 열린 구간을 갱신하는 경우는 이 판정과 무관하다.
    and (o.open_first_seen is not null
         or o.last_cleared_at is null
         or r.collected_at > o.last_cleared_at)
  order by p->>'id', coalesce(p->>'account', ''), w.kind, n.reset_at, r.collected_at
  on conflict (user_id, provider_id, account, window_kind, reset_at, first_seen_at) do update set
    observed_accounts = (
      select coalesce(array_agg(a order by a), '{}'::text[])
      from (
        select distinct known.account as a
        from unnest(qb.observed_accounts || excluded.observed_accounts) known(account)
        order by 1
        limit 32
      ) capped
    ),
    last_seen_at = greatest(qb.last_seen_at, excluded.last_seen_at);

  -- 앱은 최대 120일 일별 이력을 읽는다. 약간의 여유를 둔 뒤 지워 계정별 행 수가
  -- 영구히 늘지 않게 한다(Claude 계정당 최대 약 18행).
  delete from charge_quota_blocks
  where user_id = v_user and reset_at < now() - interval '125 days';

  -- 정상 Claude 계정은 125일에 최대 약 18개 주간 창이고 창마다 구간이 하나, 드물게 둘이다.
  -- 깨진/조작된 payload가 매번 다른 미래 reset_at을 보내도 저장량을 늘릴 수 없도록
  -- 이중 하드 상한을 둔다. 넘친 이력을 버리면 보호가 덜 적용되는 쪽(false negative)이라
  -- 스트릭을 부당하게 보호하거나 다른 계정에 적용하는 것보다 안전하다.
  delete from charge_quota_blocks qb
  using (
    select user_id, provider_id, account, window_kind, reset_at, first_seen_at
    from (
      select user_id, provider_id, account, window_kind, reset_at, first_seen_at,
             row_number() over (
               partition by user_id, provider_id, account
               order by reset_at desc, first_seen_at desc, last_seen_at desc
             ) as position
      from charge_quota_blocks
      where user_id = v_user
    ) ranked
    where position > 40
  ) excess
  where qb.user_id = excess.user_id and qb.provider_id = excess.provider_id
    and qb.account = excess.account and qb.window_kind = excess.window_kind
    and qb.reset_at = excess.reset_at and qb.first_seen_at = excess.first_seen_at;

  delete from charge_quota_blocks qb
  using (
    select user_id, provider_id, account, window_kind, reset_at, first_seen_at
    from (
      select user_id, provider_id, account, window_kind, reset_at, first_seen_at,
             row_number() over (
               order by reset_at desc, first_seen_at desc, last_seen_at desc
             ) as position
      from charge_quota_blocks
      where user_id = v_user
    ) ranked
    where position > 256
  ) excess
  where qb.user_id = excess.user_id and qb.provider_id = excess.provider_id
    and qb.account = excess.account and qb.window_kind = excess.window_kind
    and qb.reset_at = excess.reset_at and qb.first_seen_at = excess.first_seen_at;

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

  -- 기기별 관측을 canonical charge_providers로 접기 전에 독립 보존한다. 같은 계정을
  -- 여러 기기가 보고해도 행을 공유하지 않으므로 한 기기 삭제/계정 전환이 다른 관측을
  -- 지우지 않는다. 더 오래된 캐시가 오면 내용은 지키되 last_reported_at은 갱신해
  -- "이 기기가 아직 이 계정 키를 보고 중"이라는 사실은 남긴다.
  -- 설치 UUID 수집기로 이행하면서 account=''가 기기별 unknown:* 키로 바뀌면, 같은
  -- 기기의 레거시 미상 관측은 즉시 치워 일시적으로 카드가 둘 생기지 않게 한다.
  -- 범위를 기기로 좁히면 이미 꺼진 다른 기기가 남긴 '' 관측을 아무도 못 지운다. 그 관측은
  -- isTracking이 거짓이라 앱의 은퇴 판정에도 걸리지 않아, 계정 해시가 붙은 카드와 나란히
  -- 유령 카드가 영구히 한 장 더 뜬다. canonical 쪽 '' 정리와 같은 사용자 범위로 맞춘다.
  delete from charge_provider_observations cpo
  where cpo.user_id = v_user and cpo.account = ''
    and exists (
      select 1 from jsonb_array_elements(p_providers) p
      where p->>'id' = cpo.provider_id and coalesce(p->>'account', '') <> ''
    );

  -- 14일 넘게 어느 업로드에도 실리지 않은 관측은 사용자 범위에서 치운다. 기기별 은퇴 규칙은
  -- 그 기기가 다시 업로드해야만 돌기 때문에, 꺼진 채 버려진 기기나 수집이 계속 실패하는 기기의
  -- 옛 계정 키는 영원히 남아 앱에 한 달 묵은 카드로 뜬다. 14일은 앱이 그리는 가장 긴 창(7일)의
  -- 두 배라 며칠 꺼둔 노트북의 마지막 관측은 남는다. 마지막 관측이 사라지면 정리 트리거가
  -- canonical 카드도 지우고, 스트릭 이력(charge_quota_blocks)은 계정 단위 별도 테이블이라 남는다.
  -- (user_id, last_reported_at) 인덱스로 지울 행만 바로 찾는다.
  delete from charge_provider_observations cpo
  where cpo.user_id = v_user
    and cpo.last_reported_at < now() - interval '14 days';

  -- 이 기기가 계정 해시를 알아낸 업로드를 보내면, 같은 기기가 해시를 모르던 때 남긴 그 프로바이더의
  -- unknown:* 관측은 바로 치운다. 20분 은퇴를 기다리는 동안에도 앱에 "Unidentified account" 카드가
  -- 한 장 더 뜨고, 그 프로바이더가 실패로 보고되는 동안에는 은퇴 자체가 돌지 않는다.
  -- unknown:* 키는 설치 UUID와 프로바이더로 만든 기기별 값이라 다른 기기의 관측은 대상이 아니다.
  -- 여기서도 마지막 관측이 사라지면 정리 트리거가 canonical 카드를 지운다.
  delete from charge_provider_observations cpo
  where cpo.user_id = v_user and cpo.device_id = v_device
    and cpo.account like 'unknown:%'
    and exists (
      select 1 from jsonb_array_elements(p_providers) p
      where p->>'id' = cpo.provider_id
        and coalesce(p->>'account', '') <> ''
        and p->>'account' not like 'unknown:%'
    );

  -- 이 기기가 더는 보고하지 않는 (프로바이더, 계정) 관측을 은퇴시킨다. canonical 쪽과 같은
  -- 20분 유예를 둬 한 주기 수집 실패로 카드가 증발하지 않게 하고, 그 프로바이더가 실패
  -- 중이라고 보고되면 마지막 정상 관측을 남긴다(앱의 은퇴 판정과 같은 규칙).
  -- 이 정리가 없으면 계정을 갈아탈 때마다 옛 키가 영구히 쌓이고, 앱은 이 테이블을
  -- 상한 없이 전부 조회한다. 상태를 아예 모르는 구버전 업로드에서는 아무것도 지우지 않는다.
  delete from charge_provider_observations cpo
  where cpo.user_id = v_user and cpo.device_id = v_device
    and cpo.last_reported_at < now() - interval '20 minutes'
    and not exists (
      select 1 from jsonb_array_elements(p_providers) p
      where p->>'id' = cpo.provider_id and coalesce(p->>'account', '') = cpo.account
    )
    and (
      -- 상태를 아예 모르는 구버전 수집기 업로드에서는 canonical 은퇴와 똑같은 규칙만 쓴다.
      -- 여기서 정리를 통째로 끄면, 0.1.4 수집기를 쓰는 사용자가 계정을 바꿨을 때
      -- canonical에서 사라진 키가 관측에 남아 유령 카드로 되살아나고, 그 계정은 다시는
      -- 차단될 수 없으므로 그 프로바이더의 스트릭 보호까지 영구히 무력화된다.
      p_collect_status is null
      -- 상태를 아는 경우에만 예외를 건다. 맵에 그 프로바이더 키가 없으면 "정상 수집했는데
      -- 사라졌다"가 아니라 "이번엔 그 소스를 열거하지 못했다"일 수 있으므로 보존한다.
      -- "shared"(같은 계정의 poll lease를 다른 기기가 쥐고 있어 요청을 건너뜀)는 ok와 같게 은퇴시킨다.
      or (p_collect_status ? cpo.provider_id
          and p_collect_status->>cpo.provider_id !~ '^(error|auth_expired)')
    );

  -- 절대 상한. 위 은퇴 규칙은 "이번 업로드에 없는 키"만 지우므로, 매번 새로운 키를 보내는
  -- 클라이언트에게는 걸리지 않는다. charge_daily는 period 창이, charge_providers는 은퇴가,
  -- charge_quota_blocks는 40/256 상한이 묶는데 이 테이블만 상한이 없었다.
  delete from charge_provider_observations cpo
  using (
    select user_id, device_id, provider_id, account
    from (
      select user_id, device_id, provider_id, account,
             row_number() over (
               partition by user_id, device_id
               order by last_reported_at desc, provider_id, account
             ) as position
      from charge_provider_observations
      where user_id = v_user and device_id = v_device
    ) ranked
    where position > 200
  ) excess
  where cpo.user_id = excess.user_id and cpo.device_id = excess.device_id
    and cpo.provider_id = excess.provider_id and cpo.account = excess.account;

  insert into charge_provider_observations as cpo
    (user_id, device_id, provider_id, account, payload, collected_at, last_reported_at)
  select distinct on (p->>'id', coalesce(p->>'account', ''))
         v_user, v_device, p->>'id', coalesce(p->>'account', ''),
         -- payload 안의 수집 시각도 컬럼과 같은 규칙으로 정규화한다. 원문을 그대로 두면
         -- 서버가 미래 스탬프를 미상으로 떨궈도 앱이 payload에서 그 값을 다시 주워
         -- 시계가 앞선 기기의 묵은 값을 신선한 것으로 그린다.
         (case
            when charge_stamp(p->>'collected_at') is null then p - 'collected_at'
            else p || jsonb_build_object(
                        'collected_at',
                        to_char(charge_stamp(p->>'collected_at') at time zone 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
          end) || jsonb_build_object('account', coalesce(p->>'account', '')),
         charge_stamp(p->>'collected_at'), now()
  from jsonb_array_elements(p_providers) p
  order by p->>'id', coalesce(p->>'account', ''), charge_stamp(p->>'collected_at') desc nulls last
  on conflict (user_id, device_id, provider_id, account) do update set
    payload = case
      when excluded.collected_at is not null
           and (cpo.collected_at is null or excluded.collected_at >= cpo.collected_at)
        then excluded.payload
      when excluded.collected_at is null and cpo.collected_at is null
        then excluded.payload
      else cpo.payload
    end,
    collected_at = case
      when excluded.collected_at is not null
           and (cpo.collected_at is null or excluded.collected_at >= cpo.collected_at)
        then excluded.collected_at
      when excluded.collected_at is null and cpo.collected_at is null
        then null
      else cpo.collected_at
    end,
    last_reported_at = now();

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
    -- device_id는 보존하지 않고 언제나 실제 마지막 기록자로 갱신한다. 이 값은 구버전 앱을 위한
    -- canonical 출처 표시이며, FK는 SET NULL이라 마지막 기록 기기를 지워도 공유 카드는 유지된다.
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

-- 함수 권한: 기본 public 실행 권한을 회수하고 필요한 롤에만 부여.
-- PUBLIC에서만 회수하면 Supabase 기본 권한으로 anon에 붙은 EXECUTE가 남아 로그인이
-- 필요한 RPC까지 PostgREST 목록에 노출된다. 함수 안 auth.uid() 검사가 실제 호출은
-- 막지만, 애초에 목록에 없는 편이 낫다.
revoke execute on function public.charge_create_pairing_code() from public, anon;
grant execute on function public.charge_create_pairing_code() to authenticated;

revoke execute on function public.charge_claim_pairing_code(text, text, text) from public;
grant execute on function public.charge_claim_pairing_code(text, text, text) to anon, authenticated;

-- charge_safe_ts, charge_stamp는 내부 헬퍼, RPC로 노출할 이유가 없다 (charge_upload는 security definer라 소유자 권한으로 호출 가능)
-- PUBLIC에서만 회수하면 Supabase가 public 스키마에 걸어둔 기본 권한으로 anon/authenticated에
-- 명시 부여된 실행 권한이 남아 PostgREST RPC로 그대로 노출된다. 두 롤도 함께 회수한다.
revoke execute on function public.charge_safe_ts(text) from public, anon, authenticated;
revoke execute on function public.charge_stamp(text) from public, anon, authenticated;
revoke execute on function public.charge_num(text) from public, anon, authenticated;
revoke execute on function public.charge_safe_date(text) from public, anon, authenticated;
revoke execute on function public.charge_cleanup_provider_observation() from public, anon, authenticated;

revoke execute on function public.charge_upload(text, jsonb, jsonb, jsonb, jsonb) from public;
grant execute on function public.charge_upload(text, jsonb, jsonb, jsonb, jsonb) to anon, authenticated;

-- 최근 관측 시각을 알려주던 동료 관측 RPC는 poll lease(charge_claim_poll)로 대체됐다. 운영에 배포된 적은
-- 없지만, 이전 초안을 적용한 DB에 남아 PostgREST 목록에 노출되지 않게 지운다. 없으면 아무 일도 없다.
drop function if exists public.charge_peer_observations(text);

-- 수집기(anon)가 Claude 사용량 요청 직전에 호출: 같은 사용자의 기기 중 한 대만 그 계정을 읽게 한다.
-- Claude 사용량 API는 계정 단위로 시간당 요청 수를 제한하는데, 한 계정을 여러 기기가 5분마다
-- 따로 읽으면 전부 429에 걸린다. 다른 기기의 최근 관측 시각을 보고 건너뛰는 방식은 예약이 아니라서,
-- 5분 주기가 업로드 지연 안쪽으로 겹친 두 기기는 둘 다 묵은 관측만 보고 매 주기 함께 읽는다.
-- 그래서 조회가 아니라 원자적인 임대로 정한다.
-- true = 이 기기가 임대를 새로 쥐었거나 갱신했다(요청해도 된다). false = 다른 기기가 아직 쥐고 있다
-- (수집기는 요청 없이 "shared"로 보고한다). 쥔 기기는 매 주기 갱신하고, 다른 기기는 임대가 만료된
-- 뒤에만 넘겨받는다. 429로 막힌 기기도 매 주기 갱신하므로 같은 사용자의 다른 기기도 함께 조용해진다.
-- TTL 270초는 서버가 정한다. 수집 주기(5분)보다 짧아 쥔 기기가 잠들거나 꺼지면 다음 주기에 다른
-- 기기가 넘겨받고, 만료 판정은 DB 시계(now())로만 해 기기 시계 오차가 임대를 늘리거나 줄이지 못한다.
-- 사용자 범위 임대다. 계정 해시만으로 사용자를 넘나들게 하면, 다른 사용자의 임대에 막힌 기기는 자기
-- 사용자에게 Claude 데이터를 영영 올리지 못하고, 누가 같은 Claude 계정을 쓰는지도 드러난다.
-- 인증은 charge_upload와 같다(토큰 해시로 기기를 찾고, 없으면 같은 예외로 거부).
create or replace function public.charge_claim_poll(p_token text, p_provider text, p_account text)
returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid;
  v_device uuid;
  v_claimed boolean;
begin
  -- 인증하면서 사용자 행, 기기 행 순서로 KEY SHARE 잠금을 먼저 잡는다. 임대 행을 쥔 채 이 두 행을 기다리지
  -- 않게 하려는 것이다. 계정 삭제는 auth.users 행부터 잠근 뒤 cascade로 기기 행과 임대 행을 지우고, 연결
  -- 해제는 기기 행부터 잠근 뒤 임대 행을 지운다. 넘겨받기(device_id 변경)와 새 행의 외래 키 검사는 기기 행과
  -- 사용자 행을 KEY SHARE로 잠그므로, 임대 행을 먼저 쥐면 삭제와 교착되고 cascade 순서에 따라 계정 삭제가
  -- 실패한다. 잠금을 먼저 잡으면 삭제가 앞선 경우 이 호출이 삭제 커밋을 기다렸다가 토큰이 사라져 거부되고
  -- (수집기는 fail open), 호출이 앞선 경우 삭제가 이 짧은 트랜잭션을 기다린다. KEY SHARE는 charge_upload의
  -- last_seen_at 갱신이나 로그인 기록 갱신과 충돌하지 않고, 행을 지우거나 키를 바꿀 때만 막는다.
  select user_id into v_user
  from charge_devices where token_hash = encode(digest(p_token, 'sha256'), 'hex');
  if v_user is not null then
    perform 1 from auth.users where id = v_user for key share;
    select user_id, id into v_user, v_device
    from charge_devices where token_hash = encode(digest(p_token, 'sha256'), 'hex')
    for key share;
  end if;
  if v_user is null then
    raise exception 'invalid device token';
  end if;

  -- 입력이 이상하면 임대 없이 true를 준다(fail open). false나 예외를 내면 수집기 쪽 형식 실수 하나가
  -- 그 계정 수집을 영구히 멈춘다. 쓰지 않고 돌아가므로 이상한 키가 테이블에 쌓이지도 않는다.
  -- 계정 미상(unknown:*)은 기기별 값이라 같은 계정인지 판정할 수 없어 임대 대상이 아니다.
  if p_provider is null or p_provider !~ '^[a-z0-9_-]{1,32}$'
     or p_account is null or char_length(p_account) not between 1 and 64
     or p_account like 'unknown:%' then
    return true;
  end if;

  -- 원자적 임대: 행이 없으면 넣고, 있으면 만료됐거나 이미 이 기기 것일 때만 넘겨받는다.
  -- 동시에 두 기기가 오면 한쪽은 다른 쪽 커밋을 기다린 뒤 갱신된 행으로 조건을 다시 재므로 하나만 이긴다.
  -- 만료 행 정리보다 먼저 한다. TTL(270초)이 주기(5분)보다 짧아 쥔 기기가 갱신할 때 자기 임대는 늘
  -- 만료돼 있는데, 먼저 지우면 갱신이 DELETE와 INSERT가 된다. 그러면 INSERT의 외래 키 검사가 이 기기
  -- 행을 기다리는 동안 그 기기를 지우는 cascade(연결 해제, 앱의 기기 삭제)는 지워진 임대 행을 기다려
  -- 교착된다. 제자리 UPDATE는 device_id가 그대로라 외래 키 검사도 기기 행 잠금도 없다.
  insert into charge_poll_leases as l (user_id, provider_id, account, device_id, expires_at)
  values (v_user, p_provider, p_account, v_device, now() + interval '270 seconds')
  on conflict (user_id, provider_id, account) do update
    set device_id = excluded.device_id,
        expires_at = excluded.expires_at
    where l.expires_at <= now() or l.device_id = excluded.device_id
  returning true into v_claimed;

  -- 그다음 이 사용자의 만료된 임대를 치운다. 만료된 임대는 없는 것과 같아 결과는 바뀌지 않고, 계정 키를
  -- 바꿔 가며 호출해도 행이 쌓이지 않는다. 기본키가 user_id로 시작한다. 다른 트랜잭션이 잠근 행(기기 삭제
  -- cascade가 지우는 중인 행, 다른 호출이 정리하는 중인 행)은 기다리지 않고 건너뛴다. 위에서 쥔 임대 행을
  -- 그 트랜잭션이 기다리고 있을 수 있어 여기서 기다리면 교착이 되고, 건너뛴 행은 그쪽이나 다음 호출이 치운다.
  delete from charge_poll_leases l
  where (l.user_id, l.provider_id, l.account) in (
    select x.user_id, x.provider_id, x.account
    from charge_poll_leases x
    where x.user_id = v_user and x.expires_at <= now()
    for update skip locked
  );

  return coalesce(v_claimed, false);
end $$;

revoke execute on function public.charge_claim_poll(text, text, text) from public;
grant execute on function public.charge_claim_poll(text, text, text) to anon, authenticated;

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

revoke execute on function public.charge_delete_account() from public, anon;
grant execute on function public.charge_delete_account() to authenticated;

-- MARK: 수집기 자동 업데이트
-- 수집기(anon)가 12시간마다 호출: 가장 최근에 게시된 릴리스 한 행. 테이블은 정책이 없어 직접
-- 읽을 수 없고 이 함수로만 노출된다. 게시 시각이 같으면 숫자로 비교한 버전이 큰 쪽을 준다
-- (문자열 비교는 0.10.0을 0.9.0보다 작게 본다. 형식 제약이 x.y.z 숫자만 허용해 캐스트가 안전하다).
-- 반환 형식에 key_id를 더했다. create or replace는 반환 형식을 바꾸지 못하므로 먼저 지운다. 지우면
-- 권한도 사라지지만 바로 아래 revoke/grant가 다시 건다(재실행해도 결과는 같다).
drop function if exists public.charge_latest_collector();
create or replace function public.charge_latest_collector()
returns table(version text, integrity text, tarball text, signature text, key_id text)
language sql stable security definer set search_path = public, extensions, pg_temp
as $$
  select r.version, r.integrity, r.tarball, r.signature, r.key_id
  from charge_collector_releases r
  order by r.published_at desc, string_to_array(r.version, '.')::int[] desc
  limit 1
$$;

revoke execute on function public.charge_latest_collector() from public;
grant execute on function public.charge_latest_collector() to anon, authenticated;

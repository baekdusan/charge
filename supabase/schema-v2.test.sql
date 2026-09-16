-- 로컬 PostgreSQL 전용 회귀 테스트.
-- schema-v2.sql 적용 뒤 superuser로 실행하며, 전체를 rollback하므로 테스트 행은 남지 않는다.
-- 백필 검증에서 psql의 \ir(스크립트 위치 기준 include)을 쓰므로 psql -f로 실행한다.
-- supabase/test-local.sh가 임시 클러스터에 Supabase 기본 요소를 흉내 내고 이 순서를 그대로 돈다.
begin;

-- pgcrypto가 public이 아니라 extensions에 설치된 재현 환경에서도 digest()를 찾게 한다.
set local search_path = public, extensions;

-- MARK: 이행 백필 (charge_provider_observations 생성 직후 1회)
-- 관측 테이블 도입 전에 쌓인 canonical 카드는 관측 행이 하나도 없어, 그 기기를 지워도
-- 정리 트리거가 잡을 근거가 없다. 백필이 빠지면 카드가 device_id만 null인 채 영원히 남는다.
-- 백필은 함수가 아니라 최상위 문이라 호출할 수 없으므로, 이행 직전 상태를 만든 뒤 스키마를
-- 다시 적용해 검증한다. 재적용이 무해해야 한다는 요구사항도 함께 확인하는 셈이다.
do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000009';
  v_dev uuid;
begin
  insert into auth.users (id) values (v_user);
  insert into charge_devices (user_id, token_hash, installation_id, label)
  values (v_user, encode(digest('backfill-token', 'sha256'), 'hex'),
          '20000000-0000-4000-8000-000000000009', 'Backfill-Mac')
  returning id into v_dev;
  -- 구조 이행 직전 상태: 마지막 보고 기기가 남아 있는 canonical 행만 있고 관측은 없다.
  insert into charge_providers
    (user_id, id, account, name, plan, session, device_id, device_label, collected_at)
  values (v_user, 'claude', 'acct-backfill', 'Claude', 'max',
          jsonb_build_object('percent', 12, 'window_minutes', 300),
          v_dev, 'Backfill-Mac', now() - interval '1 minute');
  assert not exists (
    select 1 from charge_provider_observations where user_id = v_user
  ), 'backfill fixture is broken: an observation already exists';

  -- 리셋 시각 정규화 INSERT는 초 성분이 남은 행만 옮기므로, 이미 분 경계였던 기존 행의
  -- 계정 배열은 상한을 넘긴 채로 남는다. 업로드 경로의 상한만 고쳐두면 이행 전에 부푼
  -- 배열이 영원히 그대로다. 마이그레이션이 직접 잘라야 한다.
  insert into charge_quota_blocks
    (user_id, provider_id, account, window_kind, reset_at, observed_accounts,
     first_seen_at, last_seen_at)
  values (v_user, 'claude', 'acct-array', 'weekly',
          date_trunc('minute', now() + interval '10 days'),
          array(select 'acct-arr-' || to_char(g, 'FM000') from generate_series(1, 40) g),
          now() - interval '1 day', now());
end $$;

-- 새 컬럼과 릴리스 테이블도 재적용에 무해해야 한다. 또 0.2.0 수집기가 스키마보다 먼저 올라온
-- 기간에 구버전 charge_upload가 collect_status에 그대로 저장한 "_collector" 키는 이행이 기기
-- 컬럼으로 옮겨야 한다. 옮기지 않으면 그 기기는 다음 업로드 전까지 버전 미상으로 보이고,
-- "_" 키를 모르는 구버전 앱은 그 키를 프로바이더 상태로 읽는다.
do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000019';
begin
  insert into auth.users (id) values (v_user);
  insert into charge_devices (user_id, token_hash, label, collect_status, collector_version)
  values (v_user, encode(digest('version-kept', 'sha256'), 'hex'), 'Version-Kept',
          '{"claude":"ok"}'::jsonb, '0.2.0'),
         (v_user, encode(digest('version-legacy', 'sha256'), 'hex'), 'Version-Legacy',
          '{"claude":"ok","_collector":"0.2.1"}'::jsonb, null),
         (v_user, encode(digest('version-garbage', 'sha256'), 'hex'), 'Version-Garbage',
          '{"claude":"ok","_collector":"0.2.1 beta!"}'::jsonb, null),
         (v_user, encode(digest('version-nonstring', 'sha256'), 'hex'), 'Version-Nonstring',
          '{"_collector":3}'::jsonb, null);
  insert into charge_collector_releases (version, integrity, tarball, signature, key_id, published_at)
  values ('0.0.1', 'sha512-' || repeat('A', 86) || '==',
          'https://registry.npmjs.org/charge-connect/-/charge-connect-0.0.1.tgz',
          repeat('B', 86) || '==', 'k1', '2026-09-01T00:00:00Z');
  -- 살아 있는 임대도 재적용으로 바뀌면 안 된다. 쥔 기기가 바뀌거나 만료가 당겨지면 두 기기가 함께 읽는다.
  insert into charge_poll_leases (user_id, provider_id, account, device_id, expires_at)
  select v_user, 'claude', 'acct-lease-kept', id, '2100-01-01T00:00:00Z'
  from charge_devices where user_id = v_user and label = 'Version-Kept';

  -- key_id 도입 이전 초안을 적용한 DB를 흉내 낸다: key_id 없는 옛 서명 행, 네 컬럼만 돌려주는
  -- charge_latest_collector, 동료 관측 RPC(아래 최상위 문). 재적용이 셋을 모두 정리해야 한다.
  -- 옛 반환 형식을 남긴 채 create or replace하면 적용 자체가 실패한다.
  alter table charge_collector_releases alter column key_id drop not null;
  insert into charge_collector_releases (version, integrity, tarball, signature, published_at)
  values ('0.0.2', 'sha512-' || repeat('A', 86) || '==',
          'https://registry.npmjs.org/charge-connect/-/charge-connect-0.0.2.tgz',
          repeat('B', 86) || '==', '2026-09-02T00:00:00Z');
end $$;

drop function public.charge_latest_collector();
create function public.charge_latest_collector()
returns table(version text, integrity text, tarball text, signature text)
language sql stable security definer set search_path = public
as $$
  select r.version, r.integrity, r.tarball, r.signature
  from charge_collector_releases r
  order by r.published_at desc
  limit 1
$$;
create function public.charge_peer_observations(p_token text)
returns table(provider_id text, account text, collected_at timestamptz)
language sql stable security definer set search_path = public, extensions
as $$
  select null::text, null::text, null::timestamptz where false
$$;
grant execute on function public.charge_peer_observations(text) to anon, authenticated;

-- Supabase는 public 스키마 기본 권한으로 새로 만든 함수마다 anon/authenticated에 EXECUTE를
-- 붙인다. 로컬 재현 환경에는 그 기본 권한이 없을 수 있어, 회수 테스트가 저절로 통과하는
-- 것을 막으려면 직접 붙여 둬야 한다. 아래 스키마 재적용이 이것을 걷어내야 하고, 걷어내지
-- 못하면 내부 헬퍼와 로그인 전용 RPC가 그대로 PostgREST RPC로 노출된다.
grant execute on function public.charge_safe_ts(text) to anon, authenticated;
grant execute on function public.charge_stamp(text) to anon, authenticated;
grant execute on function public.charge_num(text) to anon, authenticated;
grant execute on function public.charge_safe_date(text) to anon, authenticated;
grant execute on function public.charge_cleanup_provider_observation() to anon, authenticated;
grant execute on function public.charge_create_pairing_code() to anon;
grant execute on function public.charge_delete_account() to anon;
grant execute on function public.charge_claim_poll(text, text, text) to public;

set local client_min_messages = warning;
\ir schema-v2.sql
reset client_min_messages;

do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000009';
  v_payload jsonb;
begin
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-array'
      and observed_accounts = array(
            select 'acct-arr-' || to_char(g, 'FM000') from generate_series(1, 32) g)
  ), 'migration left an oversized observed_accounts array untouched';
  select payload into v_payload from charge_provider_observations
  where user_id = v_user and provider_id = 'claude' and account = 'acct-backfill';
  assert v_payload is not null, 'legacy canonical card was not backfilled into observations';
  assert v_payload->>'account' = 'acct-backfill' and v_payload->>'name' = 'Claude'
     and v_payload->'session'->>'percent' = '12',
    'backfilled observation lost the canonical payload';
  -- 비어 있던 컬럼이 payload에 null 키로 되살아나면, 앱이 "값이 지워졌다"와 "원래 없다"를
  -- 구분하지 못한다.
  assert not (v_payload ? 'weekly') and not (v_payload ? 'extras') and not (v_payload ? 'status'),
    'backfill turned empty canonical columns into explicit null keys';
end $$;

-- 이행 문은 재실행에 안전해야 한다. 스키마를 다시 적용해도 배열이 더 잘리거나 백필이
-- 관측을 다시 만들어 덮어쓰면 안 된다.
set local client_min_messages = warning;
\ir schema-v2.sql
reset client_min_messages;

do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000019';
begin
  assert exists (
    select 1 from charge_devices
    where user_id = v_user and label = 'Version-Kept'
      and collector_version = '0.2.0' and collect_status = '{"claude":"ok"}'::jsonb
  ), 're-applying the schema changed a stored collector version';
  assert exists (
    select 1 from charge_devices
    where user_id = v_user and label = 'Version-Legacy'
      and collector_version = '0.2.1' and collect_status = '{"claude":"ok"}'::jsonb
  ), 'migration did not move a stored _collector key into the device column';
  assert exists (
    select 1 from charge_devices
    where user_id = v_user and label = 'Version-Garbage'
      and collector_version is null and collect_status = '{"claude":"ok"}'::jsonb
  ), 'migration stored a malformed collector version or kept its key';
  assert exists (
    select 1 from charge_devices
    where user_id = v_user and label = 'Version-Nonstring'
      and collector_version is null and collect_status = '{}'::jsonb
  ), 'migration kept a non-string _collector key';
  assert exists (
    select 1 from charge_collector_releases
    where version = '0.0.1' and key_id = 'k1' and published_at = '2026-09-01T00:00:00Z'
  ), 're-applying the schema changed the collector release manifest';
  -- 수집기는 최신 한 행만 읽으므로 옛 서명 형식의 행이 남으면 모든 자동 업데이트가 그 행에서 멈춘다.
  assert not exists (select 1 from charge_collector_releases where version = '0.0.2'),
    'a release row signed before key ids existed survived the migration';
  assert (select a.attnotnull from pg_attribute a
          where a.attrelid = 'public.charge_collector_releases'::regclass and a.attname = 'key_id'),
    'the migration did not make key_id mandatory';
  assert to_regprocedure('public.charge_peer_observations(text)') is null,
    'the replaced peer observation RPC survived the migration';
  assert pg_get_function_result('public.charge_latest_collector()'::regprocedure)
         = 'TABLE(version text, integrity text, tarball text, signature text, key_id text)',
    'the migration kept a manifest RPC that does not return key_id';
  assert exists (
    select 1 from charge_poll_leases l join charge_devices d on d.id = l.device_id
    where l.user_id = v_user and l.provider_id = 'claude' and l.account = 'acct-lease-kept'
      and d.label = 'Version-Kept' and l.expires_at = '2100-01-01T00:00:00Z'
  ), 're-applying the schema changed a live poll lease';
end $$;

do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000009';
  v_count int;
begin
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-array'
      and observed_accounts = array(
            select 'acct-arr-' || to_char(g, 'FM000') from generate_series(1, 32) g)
  ), 're-applying the schema changed an already capped observed_accounts array';
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-array';
  assert v_count = 1, 're-applying the schema duplicated a quota history row';
  select count(*) into v_count
  from charge_provider_observations where user_id = v_user;
  assert v_count = 1, 're-applying the schema duplicated a backfilled observation';

  -- 백필 덕분에 관측이 존재하므로, 마지막 보고 기기를 지우면 카드도 함께 정리된다.
  delete from charge_devices where user_id = v_user;
  assert not exists (
    select 1 from charge_providers where user_id = v_user and account = 'acct-backfill'
  ), 'device deletion left an orphan card (backfill did not arm the cleanup trigger)';
end $$;

do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000001';
  v_install_a constant text := '20000000-0000-4000-8000-000000000001';
  v_install_b constant text := '20000000-0000-4000-8000-000000000002';
  v_install_legacy constant text := '20000000-0000-4000-8000-000000000003';
  v_token_a text;
  v_token_a2 text;
  v_token_b text;
  v_device_b uuid;
  v_payload jsonb;
  v_count int;
  v_reset timestamptz;
begin
  insert into auth.users (id) values (v_user);

  -- 표시 이름이 같아도 설치 UUID가 다르면 별도 기기다.
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTA001', v_user, now() + interval '10 minutes'),
         ('TESTB001', v_user, now() + interval '10 minutes');
  v_token_a := charge_claim_pairing_code('TESTA001', 'Same-Mac', v_install_a);
  v_token_b := charge_claim_pairing_code('TESTB001', 'Same-Mac', v_install_b);
  assert v_token_a is not null and v_token_b is not null and v_token_a <> v_token_b;
  select count(*) into v_count from charge_devices where user_id = v_user;
  assert v_count = 2, 'same-label installations collapsed into one device';

  -- 같은 설치를 재페어링하면 행은 유지하고 토큰만 회전한다.
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTA002', v_user, now() + interval '10 minutes');
  v_token_a2 := charge_claim_pairing_code('TESTA002', 'Renamed-Mac', v_install_a);
  select count(*) into v_count from charge_devices where user_id = v_user;
  assert v_count = 2, 're-pair created a duplicate device';
  assert not exists (
    select 1 from charge_devices
    where token_hash = encode(digest(v_token_a, 'sha256'), 'hex')
  ), 'old token survived re-pair';
  assert exists (
    select 1 from charge_devices
    where installation_id = v_install_a and label = 'Renamed-Mac'
  ), 're-pair did not preserve installation identity or update label';

  -- UUID가 없던 레거시 행은 최초 신버전 페어링에서 한 번 승계한다.
  insert into charge_devices (user_id, token_hash, label)
  values (v_user, encode(digest('legacy-token', 'sha256'), 'hex'), 'Legacy-Mac');
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTL001', v_user, now() + interval '10 minutes');
  perform charge_claim_pairing_code('TESTL001', 'Legacy-Mac', v_install_legacy);
  select count(*) into v_count from charge_devices where user_id = v_user;
  assert v_count = 3, 'legacy adoption created a duplicate device';
  assert exists (
    select 1 from charge_devices where user_id = v_user and installation_id = v_install_legacy
  ), 'legacy device did not adopt installation id';

  -- 기존 account='' 관측은 같은 기기가 namespaced 계정을 보고하면 즉시 이행된다.
  v_reset := date_trunc('minute', now() + interval '2 days');
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'codex', 'name', 'Codex', 'account', '', 'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"codex":"ok"}'::jsonb);
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'codex', 'name', 'Codex', 'account', 'unknown:0123456789abcdef', 'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"codex":"ok"}'::jsonb);
  assert not exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'codex' and account = ''
  ), 'legacy unknown observation survived namespaced upload';

  -- 같은 서비스 계정을 두 기기가 보고해도 canonical은 하나, 원본 관측은 기기별 두 개다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude',
    'name', 'Claude',
    'account', 'acct-shared',
    'session', jsonb_build_object(
      'percent', 42,
      'resets_at', now() + interval '2 hours',
      'window_minutes', 300
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  perform charge_upload(v_token_b, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);

  -- Claude 7일 한도 100%는 기기가 둘이어도 리셋 창 하나로 접혀 스트릭 보호 이력에 남는다.
  -- session 0%가 함께 있어도 weekly 100%가 실제 사용을 막는 현재 사용자 사례를 그대로 재현한다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude',
    'name', 'Claude',
    'account', 'acct-blocked',
    'session', jsonb_build_object('percent', 0, 'window_minutes', 300),
    'weekly', jsonb_build_object(
      'percent', 100,
      'resets_at', v_reset - interval '400 milliseconds',
      'window_minutes', 10080
    ),
    'extras', jsonb_build_array(jsonb_build_object(
      'name', 'Fable',
      'window', jsonb_build_object('percent', 100, 'resets_at', now() + interval '2 days')
    )),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  -- 다른 기기의 같은 창은 리셋 시각이 수백 ms 흔들려도 같은 분 버킷으로 접혀야 한다.
  v_payload := jsonb_set(
    v_payload,
    '{0,weekly,resets_at}',
    to_jsonb(v_reset + interval '400 milliseconds')
  );
  perform charge_upload(v_token_b, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks
  where user_id = v_user and provider_id = 'claude' and account = 'acct-blocked'
    and window_kind = 'weekly';
  assert v_count = 1, 'same account quota block duplicated across devices';
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and provider_id = 'claude' and account = 'acct-blocked'
      and observed_accounts @> array['acct-shared', 'acct-blocked']::text[]
  ), 'quota block forgot another known Claude account';
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and provider_id = 'claude' and account = 'acct-blocked'
      and window_kind = 'session'
  ), 'zero-percent session became a quota block';

  -- 화면은 현재 스냅샷으로 5시간 한도 소진을 표시하지만, 짧은 창은 하루 전체를
  -- 막을 수 없으므로 DB 이력에는 쌓지 않는다. 사용자당 행 수 상한을 작게 유지한다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-session-only',
    'session', jsonb_build_object(
      'percent', 100, 'resets_at', now() + interval '5 hours', 'window_minutes', 300
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-session-only'
  ), 'short session limit consumed quota history rows';

  -- 다른 프로바이더의 장기 한도도 현재 Claude 스트릭 보호 범위를 넘어가므로 저장하지 않는다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'codex', 'name', 'Codex', 'account', 'acct-codex-weekly',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', now() + interval '2 days', 'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"codex":"ok"}'::jsonb);
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-codex-weekly'
  ), 'non-Claude limit consumed quota history rows';

  -- 같은 창이 플랜 변경 등으로 100% 아래로 내려가면 원래 reset_at보다 일찍 닫힌다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-blocked',
    'weekly', jsonb_build_object('percent', 40, 'resets_at', now() + interval '2 days'),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and provider_id = 'claude' and account = 'acct-blocked'
      and window_kind = 'weekly' and cleared_at is not null
  ), 'quota block did not close when utilization dropped below 100';

  -- 오래된 캐시의 100%와 모델별 extras는 프로바이더 전체 보호 이력이 아니다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-stale',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', now() + interval '2 days', 'window_minutes', 10080
    ),
    'collected_at', now() - interval '1 hour'
  ), jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-scoped',
    'extras', jsonb_build_array(jsonb_build_object(
      'name', 'Fable',
      'window', jsonb_build_object('percent', 100, 'resets_at', now() + interval '2 days')
    )),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and provider_id = 'claude'
      and account in ('acct-stale', 'acct-scoped')
  ), 'stale or model-scoped limit became a provider-wide quota block';

  -- 여러 기기 업로드가 역순 도착해도, 차단보다 먼저 수집된 40%가 차단을 닫으면 안 된다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-race',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', now() + interval '3 days', 'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a2, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-race',
    'weekly', jsonb_build_object('percent', 40, 'resets_at', now() + interval '3 days'),
    'collected_at', now() - interval '5 minutes'
  ));
  perform charge_upload(v_token_b, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and provider_id = 'claude' and account = 'acct-race'
      and window_kind = 'weekly' and cleared_at is null
  ), 'older observation from another device cleared a newer quota block';

  -- 비정상 클라이언트가 reset_at/account를 계속 바꿔도 사용자별 이력은 유한해야 한다.
  insert into charge_quota_blocks
    (user_id, provider_id, account, window_kind, reset_at, observed_accounts,
     first_seen_at, last_seen_at)
  select v_user, 'claude', 'acct-cap', 'weekly',
         date_trunc('minute', now()) - g * interval '1 day', array['acct-cap'],
         now() - g * interval '1 day', now()
  from generate_series(1, 45) g;
  perform charge_upload(v_token_a2, '[]'::jsonb, null, '[]'::jsonb, '{}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-cap';
  -- 한 창에 구간이 둘까지 생길 수 있어 계정당 상한은 40행이다.
  assert v_count = 40, 'per-account quota history cap failed';

  insert into charge_quota_blocks
    (user_id, provider_id, account, window_kind, reset_at, observed_accounts,
     first_seen_at, last_seen_at)
  select v_user, 'claude', 'acct-global-' || g::text, 'weekly',
         date_trunc('minute', now()) - g * interval '1 minute',
         array['acct-global-' || g::text], now() - g * interval '1 minute', now()
  from generate_series(1, 300) g;
  perform charge_upload(v_token_a2, '[]'::jsonb, null, '[]'::jsonb, '{}'::jsonb);
  select count(*) into v_count from charge_quota_blocks where user_id = v_user;
  -- 사용자당 상한도 계정당 상한과 같은 비율로 올라가 256행이다.
  assert v_count = 256, 'per-user quota history cap failed';
  -- 상한 정리는 오래된 창부터 버린다. 아직 리셋되지 않은 창(스트릭 보호에 실제로 쓰이는 값)이
  -- 과거 창에 밀려 사라지면 보호가 조용히 꺼진다.
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-blocked' and reset_at > now()
  ), 'quota history cap evicted a still-open future window';

  -- 이 계정은 B만 보고하므로 B 삭제 때 canonical까지 사라져야 한다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'codex',
    'name', 'Codex',
    'account', 'acct-b-only',
    'session', jsonb_build_object(
      'percent', 17,
      'resets_at', now() + interval '2 hours',
      'window_minutes', 300
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_b, '[]'::jsonb, null, v_payload, '{"codex":"ok"}'::jsonb);

  select count(*) into v_count
  from charge_provider_observations
  where user_id = v_user and provider_id = 'claude' and account = 'acct-shared';
  assert v_count = 2, 'per-device provider observations were collapsed';
  select count(*) into v_count
  from charge_providers
  where user_id = v_user and id = 'claude' and account = 'acct-shared';
  assert v_count = 1, 'compatibility canonical provider row was duplicated';

  -- 마지막 보고 기기를 지워도 공유 canonical은 사라지지 않고, 다른 기기 관측은 남는다.
  select id into v_device_b from charge_devices
  where user_id = v_user and installation_id = v_install_b;
  delete from charge_devices where id = v_device_b;
  assert exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'claude' and account = 'acct-shared' and device_id is null
  ), 'shared provider disappeared with the last-reporting device';
  select count(*) into v_count
  from charge_provider_observations
  where user_id = v_user and provider_id = 'claude' and account = 'acct-shared';
  assert v_count = 1, 'deleting one device removed another device observation';
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and provider_id = 'claude' and account = 'acct-blocked'
  ), 'deleting one device removed account-level quota history';
  assert not exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'codex' and account = 'acct-b-only'
  ), 'provider observed only by the deleted device survived';
end $$;

-- MARK: 입력 정규화, 한도 이력 구간 모델, 관측 은퇴
do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000002';
  v_install_c constant text := '20000000-0000-4000-8000-000000000011';
  v_install_d constant text := '20000000-0000-4000-8000-000000000012';
  v_install_e constant text := '20000000-0000-4000-8000-000000000013';
  v_long constant text := repeat('x', 300);
  v_token_c text;
  v_token_d text;
  v_token_e text;
  v_dev_c uuid;
  v_dev_d uuid;
  v_payload jsonb;
  v_count int;
  v_base timestamptz;
  v_reset timestamptz;
  v_first timestamptz;
begin
  insert into auth.users (id) values (v_user);
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTC001', v_user, now() + interval '10 minutes'),
         ('TESTD001', v_user, now() + interval '10 minutes');
  v_token_c := charge_claim_pairing_code('TESTC001', 'Cap-Mac-C', v_install_c);
  v_token_d := charge_claim_pairing_code('TESTD001', 'Cap-Mac-D', v_install_d);

  -- 페이로드 총 바이트만 재면 짧은 요청 하나가 파생 저장물을 수십 배로 부풀린다(계정
  -- 문자열은 canonical, 관측, observed_accounts에 각각 복제된다). 항목별로 잘라야 하고,
  -- 자르기 전에 쓸 수 없는 항목을 버려야 한다. object가 아닌 항목과 id가 없거나 공백뿐인
  -- object는 provider_id가 null이 되어, 남겨두면 그 하나 때문에 업로드 전체(daily, live 포함)가
  -- NOT NULL 위반으로 롤백되고 그 기기가 영구히 침묵한다. 나쁜 값만 떨구고 나머지는 살린다.
  v_payload := jsonb_build_array(
    jsonb_build_object(
      'id', v_long, 'name', v_long, 'plan', v_long, 'account', v_long,
      'collected_at', now()
    ),
    to_jsonb('junk'::text),
    to_jsonb(42),
    jsonb_build_object('name', 'No id at all', 'account', 'acct-noid'),
    jsonb_build_object('id', '   ', 'name', 'Blank id', 'account', 'acct-blank')
  );
  perform charge_upload(
    v_token_c,
    jsonb_build_array(jsonb_build_object(
      'period', current_date, 'total_cost', 7, 'total_tokens', 70
    )),
    jsonb_build_object('collected_at', now()),
    v_payload, '{}'::jsonb);
  -- 항목 하나가 이상해도 같은 요청의 나머지 데이터는 살아남아야 한다.
  assert exists (
    select 1 from charge_daily
    where user_id = v_user and period = current_date and total_cost = 7
  ), 'a malformed provider entry rolled the whole upload back and lost daily rows';
  assert exists (
    select 1 from charge_live where user_id = v_user and active_block is not null
  ), 'a malformed provider entry rolled the whole upload back and lost the live block';
  select count(*) into v_count from charge_providers where user_id = v_user;
  assert v_count = 1, 'provider entries without a usable id were not dropped';
  select count(*) into v_count from charge_provider_observations where user_id = v_user;
  assert v_count = 1, 'provider entries without a usable id reached the observation table';
  assert exists (
    select 1 from charge_providers
    where user_id = v_user and id = left(v_long, 64) and account = left(v_long, 128)
      and length(name) = 128 and length(plan) = 64
  ), 'oversized provider strings were not truncated';
  -- 잘린 값이 테이블마다 다르면 계정 키가 어긋나 카드가 둘로 갈린다.
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = left(v_long, 64) and account = left(v_long, 128)
      and length(payload->>'name') = 128 and length(payload->>'account') = 128
  ), 'observation stored a different key or length than the canonical row';

  -- 정규화가 없던 키를 만들어내면 안 된다. plan이 원래 없는 프로바이더(Codex 등)의 관측
  -- payload에 "plan": null이 새로 생기면, payload를 그대로 재해석하는 쪽이 값의 유무를
  -- 잘못 읽는다(서버가 값을 지운 것인지 원래 없던 것인지 구분이 사라진다).
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'noplan', 'name', 'No Plan', 'account', 'acct-noplan', 'collected_at', now()
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"noplan":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'noplan'
      and not (payload ? 'plan')
      and payload ? 'account' and payload ? 'collected_at'
  ), 'normalization invented a null plan key in the observation payload';

  -- observed_accounts는 계정 문자열을 통째로 복제하므로 상한이 없으면 계정만 바꿔가며
  -- 업로드하는 클라이언트가 배열 하나를 무한히 늘린다. 새로 만들 때와 병합할 때 모두 32개다.
  insert into charge_providers (user_id, id, account, name)
  select v_user, 'claude', 'acct-many-a-' || to_char(g, 'FM000'), 'Claude'
  from generate_series(1, 40) g;
  v_reset := date_trunc('minute', now() + interval '6 days');
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-many',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_reset, 'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select array_length(observed_accounts, 1) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-many';
  assert v_count = 32, 'observed_accounts grew past the 32 entry cap on insert';

  insert into charge_providers (user_id, id, account, name)
  select v_user, 'claude', 'acct-many-b-' || to_char(g, 'FM000'), 'Claude'
  from generate_series(1, 40) g;
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select array_length(observed_accounts, 1) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-many';
  assert v_count = 32, 'observed_accounts grew past the 32 entry cap on conflict merge';

  -- 한 리셋 창에서 막힘 -> 해제 -> 재차단이면 구간이 둘이다. 창당 한 행으로 뭉개면 둘 중
  -- 하나가 반드시 틀린다: 해제 시각을 지우면 실제로 쓸 수 있었던 날까지 보호하고,
  -- 그대로 두면 재차단 뒤 하루 종일 막힌 날을 놓친다.
  v_reset := date_trunc('minute', now() + interval '3 days');
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-reblock',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_reset, 'window_minutes', 10080
    ),
    'collected_at', now() - interval '10 minutes'
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  -- 아직 열려 있는 구간에 100%가 또 들어오면 구간 시작을 그대로 쓰므로 행은 하나다.
  v_payload := jsonb_set(v_payload, '{0,collected_at}',
                         to_jsonb(now() - interval '8 minutes'));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-reblock';
  assert v_count = 1, 'a repeated 100% reading opened a second interval in the same window';

  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-reblock',
    'weekly', jsonb_build_object(
      'percent', 40, 'resets_at', v_reset, 'window_minutes', 10080
    ),
    'collected_at', now() - interval '5 minutes'
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-reblock',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_reset, 'window_minutes', 10080
    ),
    'collected_at', now() - interval '1 minute'
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-reblock';
  assert v_count = 2, 'a re-block after a clear did not open a second interval';
  select count(*) into v_count
  from charge_quota_blocks
  where user_id = v_user and account = 'acct-reblock' and cleared_at is null;
  assert v_count = 1, 'the re-blocked interval is not open (or the cleared one reopened)';
  select first_seen_at into v_first
  from charge_quota_blocks
  where user_id = v_user and account = 'acct-reblock' and cleared_at is null;
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-reblock'
      and cleared_at is not null and cleared_at <= v_first
  ), 'the second interval started before the first one closed';
  -- 창은 하나이므로 리셋 시각은 두 구간이 공유한다.
  select count(distinct reset_at) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-reblock';
  assert v_count = 1, 'the two intervals of one window drifted onto different reset times';

  -- 리셋 시각은 기기별 API 응답에서 초 단위로 흔들린다. 절삭으로 접어야 저장된 값이 창의
  -- 실제 리셋 시각을 넘지 않는다. 반올림(30초 더하고 절삭)은 :30 이후를 다음 분으로 밀어
  -- 아직 리셋되지 않은 창을 이미 지난 것처럼 표기하거나 같은 창을 다른 분에 앉힌다.
  v_base := date_trunc('minute', now() + interval '4 days');
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-secs',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_base + interval '45 seconds', 'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-secs' and reset_at = v_base
  ), 'reset time was rounded up instead of truncated';
  -- 다른 기기가 같은 창을 몇 초 다르게 보고해도 한 행이어야 한다.
  v_payload := jsonb_set(v_payload, '{0,weekly,resets_at}',
                         to_jsonb(v_base + interval '15 seconds'));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-secs';
  assert v_count = 1, 'one window split in two over a few seconds of jitter';

  -- 절삭만으로는 분 경계를 사이에 둔 1초 차이가 여전히 두 행으로 갈린다. 새 구간을 열 때
  -- 2분 이내의 기존 리셋 시각을 재사용해야 두 기기의 :59와 :61이 한 창으로 모인다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-edge',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_base + interval '59 seconds', 'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  v_payload := jsonb_set(v_payload, '{0,weekly,resets_at}',
                         to_jsonb(v_base + interval '61 seconds'));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-edge';
  assert v_count = 1, 'one window split in two across a minute boundary (reset reuse failed)';

  -- 근접 매칭은 저장값과 같은 기준(절삭값)으로 재야 한다. 저장된 값은 이미 분 경계인데
  -- 원시 시각으로 재면 절삭으로 잃은 최대 59초만큼 창이 좁아져, 2분 안에 있는 값을 놓친다.
  -- 10:00:59가 10:00:00으로 저장된 뒤 10:02:58이 오면 원시 기준으로는 2분 2초 차이라 밀려난다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-trunc',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_base + interval '59 seconds', 'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  v_payload := jsonb_set(v_payload, '{0,weekly,resets_at}',
                         to_jsonb(v_base + interval '2 minutes 58 seconds'));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-trunc';
  assert v_count = 1, 'nearby reset time was matched against the raw stamp, not the stored one';

  -- 다른 기기가 해제보다 먼저 읽어둔 100%를 조금 늦게 올리면(15분 창 안에서 도착 순서가
  -- 뒤집히면) 이미 풀린 한도가 다시 막힌 것으로 기록된다. 새 구간은 마지막 해제 이후에
  -- 수집된 관측만 열 수 있다.
  v_reset := date_trunc('minute', now() + interval '7 days');
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-late',
    'weekly', jsonb_build_object(
      'percent', 100, 'resets_at', v_reset, 'window_minutes', 10080
    ),
    'collected_at', now() - interval '10 minutes'
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  v_payload := jsonb_set(v_payload, '{0,weekly,percent}', to_jsonb(40));
  v_payload := jsonb_set(v_payload, '{0,collected_at}', to_jsonb(now() - interval '5 minutes'));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  v_payload := jsonb_set(v_payload, '{0,weekly,percent}', to_jsonb(100));
  v_payload := jsonb_set(v_payload, '{0,collected_at}', to_jsonb(now() - interval '7 minutes'));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  select count(*) into v_count
  from charge_quota_blocks where user_id = v_user and account = 'acct-late';
  assert v_count = 1, 'a 100% reading collected before the clear opened a new interval';
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-late' and cleared_at is null
  ), 'a stale 100% reading reopened an already cleared window';

  -- observed_accounts는 "이 계정들이 전부 그날 종일 막혔어야 보호한다"는 뜻이라, 곧 사라질
  -- 키가 섞이면 만족할 수 없는 조건이 되어 그 구간이 덮는 최대 7일의 보호가 통째로 꺼진다.
  -- 계정 미상('') 행은 애초에 구간이 열릴 수 없는 키이고, 20분 유예가 지난 옛 계정 행은
  -- 같은 업로드의 정리 구문이 곧 지운다. 둘 다 소스에서 빠져야 한다.
  insert into charge_providers (user_id, id, account, name, updated_at)
  values (v_user, 'claude', '', 'Claude', now()),
         (v_user, 'claude', 'acct-h-stale', 'Claude', now() - interval '30 minutes');
  v_reset := date_trunc('minute', now() + interval '8 days');
  v_payload := jsonb_build_array(
    jsonb_build_object(
      'id', 'claude', 'name', 'Claude', 'account', 'acct-h',
      'weekly', jsonb_build_object(
        'percent', 100, 'resets_at', v_reset, 'window_minutes', 10080
      ),
      'collected_at', now()
    ),
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', '',
                       'collected_at', now())
  );
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"claude":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-h' and 'acct-h' = any(observed_accounts)
  ), 'the interval forgot the account it was opened for';
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-h' and '' = any(observed_accounts)
  ), 'an account-less row got recorded as an account that must also be blocked';
  assert not exists (
    select 1 from charge_quota_blocks
    where user_id = v_user and account = 'acct-h' and 'acct-h-stale' = any(observed_accounts)
  ), 'an account that this upload retires got recorded as one that must also be blocked';

  -- 이 기기가 더는 보고하지 않는 (프로바이더, 계정) 관측을 은퇴시키지 않으면 계정을 갈아탈
  -- 때마다 옛 키가 영구히 쌓이고, 앱은 이 테이블을 상한 없이 전부 조회한다.
  v_payload := jsonb_build_array(
    jsonb_build_object('id', 'ret-keep', 'name', 'Keep', 'account', 'acct-ret',
                       'collected_at', now()),
    jsonb_build_object('id', 'ret-drop', 'name', 'Drop', 'account', 'acct-ret',
                       'collected_at', now()),
    jsonb_build_object('id', 'ret-error', 'name', 'Err', 'account', 'acct-ret',
                       'collected_at', now()),
    jsonb_build_object('id', 'ret-absent', 'name', 'Absent', 'account', 'acct-ret',
                       'collected_at', now())
  );
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload,
    '{"ret-keep":"ok","ret-drop":"ok","ret-error":"ok","ret-absent":"ok"}'::jsonb);
  -- 유예 20분이 지난 상태를 만든다. 한 주기 수집 실패로는 관측이 사라지면 안 된다.
  update charge_provider_observations set last_reported_at = now() - interval '30 minutes'
  where user_id = v_user and provider_id like 'ret-%';
  -- 이번 업로드는 ret-keep만 싣고, 상태 맵에는 ret-absent 키가 아예 없다.
  v_payload := jsonb_build_array(
    jsonb_build_object('id', 'ret-keep', 'name', 'Keep', 'account', 'acct-ret',
                       'collected_at', now())
  );
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload,
                        '{"ret-keep":"ok","ret-drop":"ok","ret-error":"error"}'::jsonb);
  assert not exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-drop'
  ), 'observation this device stopped reporting was never retired';
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-error'
  ), 'observation retired while the provider was reported as failing';
  -- 상태 맵에 키가 없다는 것은 "정상 수집했는데 사라졌다"가 아니라 "이번엔 그 소스를
  -- 열거하지 못했다"일 수 있다. 지우는 쪽은 되돌릴 수 없으므로 키가 있을 때만 은퇴시킨다.
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-absent'
  ), 'observation retired although the status map never mentioned that provider';
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-keep'
  ), 'observation retired while the device was still reporting it';

  -- 상태 맵을 보내지 않는 구버전 수집기(0.1.4)에서도 은퇴는 돌아야 한다. 여기서 정리를
  -- 통째로 끄면 그 사용자는 계정을 바꿔도 옛 키가 관측에 영원히 남아, canonical에서 사라진
  -- 계정이 앱 병합에서 유령 카드로 되살아난다. 그 계정은 다시 차단될 수 없으므로 스트릭
  -- 보호의 계정 집합에 들어가는 순간 그 프로바이더의 보호가 영구히 무력화된다.
  -- 상태를 모를 때는 canonical 은퇴와 똑같은 규칙(20분 유예 + 이번 업로드에 없음)만 쓴다.
  update charge_provider_observations set last_reported_at = now() - interval '30 minutes'
  where user_id = v_user and provider_id like 'ret-%';
  v_payload := jsonb_build_array(
    jsonb_build_object('id', 'ret-keep', 'name', 'Keep', 'account', 'acct-ret2',
                       'collected_at', now())
  );
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, null);
  assert not exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-keep' and account = 'acct-ret'
  ), 'legacy upload left the observation of an account the device stopped reporting';
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-keep' and account = 'acct-ret2'
  ), 'legacy upload did not record the new account observation';
  select count(*) into v_count
  from charge_provider_observations where user_id = v_user and provider_id like 'ret-%';
  assert v_count = 1, 'legacy upload skipped the retirement of stale observations';

  -- 상태 맵이 없어도 20분 유예는 그대로다. 한 주기 수집 실패로 카드가 증발하면 안 된다.
  v_payload := jsonb_build_array(
    jsonb_build_object('id', 'ret-fresh', 'name', 'Fresh', 'account', 'acct-ret',
                       'collected_at', now())
  );
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, null);
  perform charge_upload(v_token_c, '[]'::jsonb, null, '[]'::jsonb, null);
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ret-fresh'
  ), 'a fresh observation was retired inside the 20 minute grace';

  -- 두 기기가 같은 계정을 보다가 관측이 하나씩 사라지면(계정 갈아타기, 은퇴, 기기 삭제),
  -- 마지막 관측이 없어지는 순간 canonical 카드도 사라져야 한다. canonical에 박힌 기기와
  -- 마지막으로 사라진 관측의 기기가 다르다는 이유로 남기면, 아무도 보고하지 않는 유령
  -- 카드가 영원히 남는다(그 카드는 다시 갱신되지 않으므로 되살아날 수도 없다).
  select id into v_dev_c from charge_devices where user_id = v_user and installation_id = v_install_c;
  select id into v_dev_d from charge_devices where user_id = v_user and installation_id = v_install_d;
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'shared-x', 'name', 'Shared', 'account', 'acct-two', 'collected_at', now()
  ));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"shared-x":"ok"}'::jsonb);
  -- C의 관측은 더 오래된 수집이라 canonical을 덮지 못한다. canonical에는 D가 박힌 채로
  -- 두 기기의 관측만 나란히 쌓인다.
  v_payload := jsonb_set(v_payload, '{0,collected_at}', to_jsonb(now() - interval '30 minutes'));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"shared-x":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'shared-x' and account = 'acct-two' and device_id = v_dev_d
  ), 'canonical card fixture is broken: it should still point at the first reporting device';
  select count(*) into v_count
  from charge_provider_observations where user_id = v_user and provider_id = 'shared-x';
  assert v_count = 2, 'the two devices did not each keep their own observation';

  delete from charge_provider_observations
  where user_id = v_user and provider_id = 'shared-x' and device_id = v_dev_d;
  assert exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'shared-x' and account = 'acct-two'
  ), 'canonical card vanished while another device was still observing the account';
  delete from charge_provider_observations
  where user_id = v_user and provider_id = 'shared-x' and device_id = v_dev_c;
  assert not exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'shared-x' and account = 'acct-two'
  ), 'canonical card outlived its last observation (device id mismatch left a ghost card)';

  -- payload 안 수집 시각도 컬럼과 같은 규칙으로 정규화한다. 원문을 그대로 두면 서버가 미래
  -- 스탬프를 미상으로 떨궈도 앱이 payload에서 그 값을 다시 주워, 시계가 앞선 기기의 묵은
  -- 값을 가장 신선한 것으로 그린다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'stampx', 'name', 'Stamp', 'account', 'acct-future',
    'collected_at', now() + interval '10 minutes'
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"stampx":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'stampx' and account = 'acct-future'
      and collected_at is null and not (payload ? 'collected_at')
  ), 'future collected_at survived inside the observation payload';

  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'stampx', 'name', 'Stamp', 'account', 'acct-past',
    'collected_at', now() - interval '1 minute'
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"stampx":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'stampx' and account = 'acct-past'
      and payload->>'collected_at' = to_char(
            (now() - interval '1 minute') at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ), 'observation payload kept a non-normalized collect timestamp';

  -- 계정 미상('') 관측 정리는 사용자 전체 범위여야 한다. 자기 기기 것만 지우면, 이미 꺼진
  -- 다른 기기가 남긴 '' 관측은 아무도 못 지운다. 그 기기는 isTracking이 거짓이라 앱의 은퇴
  -- 판정에도 걸리지 않아, 계정 해시 카드 옆에 유령 카드가 영구히 한 장 더 뜬다.
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'ghost', 'name', 'Ghost', 'account', '', 'collected_at', now()
  ));
  perform charge_upload(v_token_d, '[]'::jsonb, null, v_payload, '{"ghost":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ghost' and account = '' and device_id = v_dev_d
  ), 'account-less observation fixture is broken';
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'ghost', 'name', 'Ghost', 'account', 'acct-ghost-hash', 'collected_at', now()
  ));
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{"ghost":"ok"}'::jsonb);
  assert not exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ghost' and account = ''
  ), 'another device kept an account-less observation after the account hash was known';
  assert exists (
    select 1 from charge_provider_observations
    where user_id = v_user and provider_id = 'ghost' and account = 'acct-ghost-hash'
  ), 'the namespaced observation did not replace the account-less one';

  -- 은퇴 규칙은 "이번 업로드에 없는 키"만 지우므로, 매번 새 키를 보내는 클라이언트에는
  -- 영원히 걸리지 않는다. 다른 테이블은 period 창, 은퇴, 40/256 상한이 묶는데 이 테이블만
  -- 상한이 없으면 기기 하나로 행을 무한히 늘릴 수 있다. 기기당 200행에서 멈춰야 한다.
  select jsonb_agg(jsonb_build_object(
           'id', 'bulk-a-' || to_char(g, 'FM000'), 'name', 'Bulk',
           'account', 'acct-bulk', 'collected_at', now()))
    into v_payload from generate_series(1, 90) g;
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{}'::jsonb);
  update charge_provider_observations set last_reported_at = now() - interval '10 minutes'
  where user_id = v_user and provider_id like 'bulk-a-%';
  select jsonb_agg(jsonb_build_object(
           'id', 'bulk-b-' || to_char(g, 'FM000'), 'name', 'Bulk',
           'account', 'acct-bulk', 'collected_at', now()))
    into v_payload from generate_series(1, 90) g;
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{}'::jsonb);
  update charge_provider_observations set last_reported_at = now() - interval '5 minutes'
  where user_id = v_user and provider_id like 'bulk-b-%';
  select jsonb_agg(jsonb_build_object(
           'id', 'bulk-c-' || to_char(g, 'FM000'), 'name', 'Bulk',
           'account', 'acct-bulk', 'collected_at', now()))
    into v_payload from generate_series(1, 90) g;
  perform charge_upload(v_token_c, '[]'::jsonb, null, v_payload, '{}'::jsonb);
  -- 상한은 다음 업로드 초입에 걸린다. 유예 안의 키뿐이라 은퇴로는 한 행도 지워지지 않는다.
  perform charge_upload(v_token_c, '[]'::jsonb, null, '[]'::jsonb, '{}'::jsonb);
  select count(*) into v_count
  from charge_provider_observations where user_id = v_user and device_id = v_dev_c;
  assert v_count = 200, 'observations for one device grew past the 200 row cap';
  select count(*) into v_count
  from charge_provider_observations
  where user_id = v_user and device_id = v_dev_c and provider_id like 'bulk-c-%';
  assert v_count = 90, 'the cap evicted the most recently reported keys';
  select count(*) into v_count
  from charge_provider_observations
  where user_id = v_user and device_id = v_dev_c and provider_id like 'bulk-a-%';
  assert v_count < 90, 'the cap did not evict the least recently reported keys';

  -- 설치 UUID 없는 구버전 페어링이 같은 라벨의 신형 기기 행을 빼앗으면 그 기기의 토큰이
  -- 조용히 무효가 되어(다음 업로드부터 invalid device token) 수집이 멈춘다.
  -- 승계는 설치 UUID가 아직 없는 같은 계보에만 허용한다.
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTE001', v_user, now() + interval '10 minutes'),
         ('TESTE002', v_user, now() + interval '10 minutes'),
         ('TESTE003', v_user, now() + interval '10 minutes');
  v_token_e := charge_claim_pairing_code('TESTE001', 'Twin-Host', v_install_e);
  perform charge_claim_pairing_code('TESTE002', 'Twin-Host');
  select count(*) into v_count
  from charge_devices where user_id = v_user and label = 'Twin-Host';
  assert v_count = 2, 'legacy pairing hijacked a device row that already had an installation id';
  assert exists (
    select 1 from charge_devices
    where token_hash = encode(digest(v_token_e, 'sha256'), 'hex')
      and installation_id = v_install_e
  ), 'legacy pairing revoked the newer installation token';
  assert exists (
    select 1 from charge_devices
    where user_id = v_user and label = 'Twin-Host' and installation_id is null
  ), 'legacy pairing did not register a device row of its own';
  -- 같은 구버전 계보의 재페어링은 종전대로 한 행을 유지한다(중복 합산 방지).
  perform charge_claim_pairing_code('TESTE003', 'Twin-Host');
  select count(*) into v_count
  from charge_devices where user_id = v_user and label = 'Twin-Host';
  assert v_count = 2, 'legacy re-pair created a duplicate device row';
end $$;

-- MARK: 수집기 버전 (collect_status의 예약 키 "_collector")
do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000021';
  v_token text;
  v_dev uuid;
  v_status jsonb;
  v_version text;
  v_bad jsonb;
  v_rejected boolean;
begin
  insert into auth.users (id) values (v_user);
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTV001', v_user, now() + interval '10 minutes');
  v_token := charge_claim_pairing_code('TESTV001', 'Version-Mac',
                                       '20000000-0000-4000-8000-000000000021');
  select id into v_dev from charge_devices
  where token_hash = encode(digest(v_token, 'sha256'), 'hex');

  -- 버전은 기기 컬럼으로 옮기고 collect_status에는 남기지 않는다. 남기면 "_" 키를 모르는
  -- 구버전 앱이 그것을 프로바이더 상태로 읽어 경고와 설정 목록에 없는 프로바이더를 띄운다.
  perform charge_upload(v_token, '[]'::jsonb, null, '[]'::jsonb,
                        '{"claude":"ok","_collector":"0.2.0"}'::jsonb);
  select collect_status, collector_version into v_status, v_version
  from charge_devices where id = v_dev;
  assert v_version = '0.2.0', 'collector version was not moved into the device column';
  assert v_status = '{"claude":"ok"}'::jsonb, 'the reserved _collector key leaked into collect_status';

  -- 버전 키가 없는 업로드는 마지막으로 알려진 버전을 지우지 않는다. 구버전 호출 모양
  -- (p_collect_status를 뺀 4인자 재시도, 토큰만 보내는 호출, 이름 붙은 인자)도 그대로 동작해야 한다.
  perform charge_upload(v_token, '[]'::jsonb, null, '[]'::jsonb, '{"claude":"ok"}'::jsonb);
  perform charge_upload(v_token, '[]'::jsonb, null, '[]'::jsonb);
  perform charge_upload(v_token);
  perform charge_upload(p_token => v_token, p_collect_status => '{"codex":"ok"}'::jsonb);
  select collect_status, collector_version into v_status, v_version
  from charge_devices where id = v_dev;
  assert v_version = '0.2.0', 'an upload without the version key cleared the stored collector version';
  assert v_status = '{"codex":"ok"}'::jsonb, 'a named-parameter upload did not store collect_status';

  -- 형식이 틀린 버전은 업로드를 거부하지 않고 버린다. 거부하면 버전 문자열 하나 때문에 그 기기의
  -- 사용량 업로드 전체가 멈춘다. 키는 어느 경우든 떼어 낸다(남기면 아래 문자열 값 검사에 걸려
  -- 업로드가 거부되거나, 저장돼 앱에 그대로 노출된다).
  for v_bad in
    select value from jsonb_array_elements(jsonb_build_array(
      '0.2.1; drop',              -- 허용 문자 밖
      repeat('1', 33),            -- 32자 초과
      '',                         -- 빈 문자열
      '0.2.1' || chr(10),         -- 줄바꿈
      repeat('9', 9000),          -- 8KB를 넘는 값도 떼어 낸 뒤 버린다(나머지만 상한 검사)
      21,                         -- 문자열이 아님
      null,                       -- JSON null
      jsonb_build_object('v', '0.2.1')
    ))
  loop
    perform charge_upload(v_token, '[]'::jsonb, null, '[]'::jsonb,
                          jsonb_build_object('claude', 'ok', '_collector', v_bad));
    select collect_status, collector_version into v_status, v_version
    from charge_devices where id = v_dev;
    assert v_version = '0.2.0',
      format('a malformed collector version was stored: %s', left(v_bad::text, 40));
    assert v_status = '{"claude":"ok"}'::jsonb,
      format('a malformed collector version stayed in collect_status: %s', left(v_bad::text, 40));
  end loop;

  -- 사전 배포 표기(+, -)는 허용한다. 버전 키만 있던 상태 맵은 빈 객체가 된다.
  perform charge_upload(v_token, '[]'::jsonb, null, '[]'::jsonb,
                        '{"_collector":"0.3.0-rc.1+build.7"}'::jsonb);
  select collect_status, collector_version into v_status, v_version
  from charge_devices where id = v_dev;
  assert v_version = '0.3.0-rc.1+build.7', 'a well-formed pre-release collector version was rejected';
  assert v_status = '{}'::jsonb, 'a status map holding only the version key did not become empty';

  -- 떼어 낸 뒤의 나머지에는 기존 검증(객체, 문자열 값, 8KB)이 그대로 걸린다.
  foreach v_bad in array array[
    '{"claude":{"nested":true},"_collector":"0.4.0"}'::jsonb,
    jsonb_build_object('claude', repeat('x', 9000), '_collector', '0.4.0'),
    '"0.4.0"'::jsonb,
    '["_collector"]'::jsonb
  ] loop
    begin
      perform charge_upload(v_token, '[]'::jsonb, null, '[]'::jsonb, v_bad);
      v_rejected := false;
    exception when others then
      v_rejected := sqlerrm = 'invalid collect_status';
    end;
    assert v_rejected,
      format('collect_status validation was skipped around the version key: %s', left(v_bad::text, 40));
  end loop;
  assert (select collector_version from charge_devices where id = v_dev) = '0.3.0-rc.1+build.7',
    'a rejected upload still changed the collector version';

  -- 업로드가 아닌 쓰기 경로가 생겨도 같은 형식을 지킨다.
  begin
    update charge_devices set collector_version = '0.2.0 (dev)' where id = v_dev;
    v_rejected := false;
  exception when check_violation then
    v_rejected := true;
  end;
  assert v_rejected, 'the collector_version column accepted a malformed value';
end $$;

-- MARK: Claude 사용량 요청 분담 (poll lease)
-- 같은 사용자의 기기 중 한 대만 한 계정을 읽어야 한다. 두 기기가 함께 true를 받으면 계정 단위 429가
-- 그대로 남고, 만료된 임대를 아무도 넘겨받지 못하면 쥔 기기가 꺼진 순간 그 계정 데이터가 멈춘다.
-- 다른 사용자의 임대가 섞이면 남의 기기 때문에 내 데이터가 멈추고, 누가 같은 계정을 쓰는지도 드러난다.
do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000031';
  v_other constant uuid := '10000000-0000-4000-8000-000000000032';
  v_token_1 text;
  v_token_2 text;
  v_token_3 text;
  v_token_4 text;
  v_token_q text;
  v_dev_1 uuid;
  v_dev_2 uuid;
  v_dev_3 uuid;
  v_dev_q uuid;
  v_case record;
  v_bad text;
  v_before text;
  v_rejected boolean;
  v_ins bigint;
  v_upd bigint;
  v_del bigint;
begin
  insert into auth.users (id) values (v_user), (v_other);
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTP001', v_user, now() + interval '10 minutes'),
         ('TESTP002', v_user, now() + interval '10 minutes'),
         ('TESTP003', v_user, now() + interval '10 minutes'),
         ('TESTP004', v_user, now() + interval '10 minutes'),
         ('TESTQ001', v_other, now() + interval '10 minutes');
  v_token_1 := charge_claim_pairing_code('TESTP001', 'Lease-1', '20000000-0000-4000-8000-000000000031');
  v_token_2 := charge_claim_pairing_code('TESTP002', 'Lease-2', '20000000-0000-4000-8000-000000000032');
  v_token_3 := charge_claim_pairing_code('TESTP003', 'Lease-3', '20000000-0000-4000-8000-000000000033');
  v_token_4 := charge_claim_pairing_code('TESTP004', 'Lease-4', '20000000-0000-4000-8000-000000000035');
  v_token_q := charge_claim_pairing_code('TESTQ001', 'Lease-Other', '20000000-0000-4000-8000-000000000034');
  select id into v_dev_1 from charge_devices where token_hash = encode(digest(v_token_1, 'sha256'), 'hex');
  select id into v_dev_2 from charge_devices where token_hash = encode(digest(v_token_2, 'sha256'), 'hex');
  select id into v_dev_3 from charge_devices where token_hash = encode(digest(v_token_3, 'sha256'), 'hex');
  select id into v_dev_q from charge_devices where token_hash = encode(digest(v_token_q, 'sha256'), 'hex');

  -- 비어 있는 임대는 첫 기기가 쥔다. TTL은 호출자가 아니라 서버가 DB 시계로 정한 270초다.
  assert charge_claim_poll(v_token_1, 'claude', 'acct-lease'), 'the first device was denied a free lease';
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'claude' and account = 'acct-lease'
      and device_id = v_dev_1 and expires_at = now() + interval '270 seconds'
  ), 'the lease does not name the first device with a 270 second database clock TTL';

  -- 살아 있는 임대는 같은 사용자의 다른 기기에 넘어가지 않고, 거절은 행을 바꾸지 않는다.
  assert not charge_claim_poll(v_token_2, 'claude', 'acct-lease'),
    'a second device got a lease the first device still holds';
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'claude' and account = 'acct-lease'
      and device_id = v_dev_1 and expires_at = now() + interval '270 seconds'
  ), 'a denied claim changed the lease';

  -- 쥔 기기는 매 주기 갱신한다. 만료가 가까워도 자기 임대는 다시 270초로 늘어난다.
  update charge_poll_leases set expires_at = now() + interval '5 seconds'
  where user_id = v_user and provider_id = 'claude' and account = 'acct-lease';
  assert charge_claim_poll(v_token_1, 'claude', 'acct-lease'), 'the holder could not renew its lease';
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'claude' and account = 'acct-lease'
      and device_id = v_dev_1 and expires_at = now() + interval '270 seconds'
  ), 'renewing did not push the expiry back to 270 seconds';
  -- 이미 만료된 자기 임대도 다시 쥔다(잠에서 깬 기기). TTL이 주기(5분)보다 짧아 평소 갱신도 이 경우다.
  -- 갱신은 제자리 UPDATE 한 번이어야 한다. 지우고 새로 넣으면 INSERT의 외래 키 검사가 기기 행을 잠가,
  -- 같은 순간 그 기기를 지우는 cascade(연결 해제, 앱의 기기 삭제)와 교착된다. 경합은 한 세션에서
  -- 재현할 수 없으므로 이 트랜잭션의 행 변경 수로 확인한다.
  update charge_poll_leases set expires_at = now() - interval '1 minute'
  where user_id = v_user and provider_id = 'claude' and account = 'acct-lease';
  select n_tup_ins, n_tup_upd, n_tup_del into v_ins, v_upd, v_del
  from pg_stat_xact_user_tables where relid = 'public.charge_poll_leases'::regclass;
  assert charge_claim_poll(v_token_1, 'claude', 'acct-lease'), 'the holder could not renew its own expired lease';
  select n_tup_ins - v_ins, n_tup_upd - v_upd, n_tup_del - v_del into v_ins, v_upd, v_del
  from pg_stat_xact_user_tables where relid = 'public.charge_poll_leases'::regclass;
  assert (v_ins, v_upd, v_del) = (0::bigint, 1::bigint, 0::bigint),
    format('renewing an expired own lease was not one in-place update (inserted %s, updated %s, deleted %s)',
           v_ins, v_upd, v_del);
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'claude' and account = 'acct-lease'
      and device_id = v_dev_1 and expires_at = now() + interval '270 seconds'
  ), 'renewing an expired own lease did not restore a full TTL';

  -- 만료 직전에는 넘겨받을 수 없고, 만료 시각이 되면(<= now()) 다른 기기가 넘겨받는다.
  update charge_poll_leases set expires_at = now() + interval '1 millisecond'
  where user_id = v_user and provider_id = 'claude' and account = 'acct-lease';
  assert not charge_claim_poll(v_token_2, 'claude', 'acct-lease'), 'a lease was taken over before it expired';
  update charge_poll_leases set expires_at = now()
  where user_id = v_user and provider_id = 'claude' and account = 'acct-lease';
  assert charge_claim_poll(v_token_2, 'claude', 'acct-lease'), 'another device could not take over an expired lease';
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'claude' and account = 'acct-lease'
      and device_id = v_dev_2 and expires_at = now() + interval '270 seconds'
  ), 'the takeover did not move the lease to the new device for a full TTL';
  assert not charge_claim_poll(v_token_1, 'claude', 'acct-lease'),
    'the previous holder still got the lease after a takeover';

  -- 임대는 (프로바이더, 계정)마다 독립이다.
  assert charge_claim_poll(v_token_1, 'claude', 'acct-lease-2')
     and charge_claim_poll(v_token_1, 'codex', 'acct-lease'),
    'a lease on one account or provider blocked another';

  -- 다른 사용자가 같은 계정 해시를 쓰면 각자 따로 쥐고, 서로의 행을 건드리지 않는다.
  assert charge_claim_poll(v_token_q, 'claude', 'acct-lease'), 'another user''s lease blocked this user';
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_other and provider_id = 'claude' and account = 'acct-lease' and device_id = v_dev_q
  ) and exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'claude' and account = 'acct-lease' and device_id = v_dev_2
      and expires_at = now() + interval '270 seconds'
  ), 'leases of two users on the same account hash interfered';

  -- 입력이 이상하면 임대 없이 true(fail open)이고, 행을 쓰지도 지우지도 않는다. 막아 버리면 수집기의
  -- 형식 실수 하나가 그 계정 수집을 영구히 멈추고, 쓰게 두면 이상한 키가 쌓인다.
  insert into charge_poll_leases (user_id, provider_id, account, device_id, expires_at)
  values (v_user, 'claude', 'acct-lapsed', v_dev_1, now() - interval '1 hour'),
         (v_other, 'claude', 'acct-lapsed', v_dev_q, now() - interval '1 hour');
  select string_agg(to_jsonb(l)::text, ',' order by l.user_id, l.provider_id, l.account)
    into v_before from charge_poll_leases l;
  for v_case in
    select * from (values
      ('', 'acct-lease'),
      (repeat('a', 33), 'acct-lease'),
      ('Claude', 'acct-lease'),
      ('clau de', 'acct-lease'),
      ('claude' || chr(10), 'acct-lease'),
      (null, 'acct-lease'),
      ('claude', ''),
      ('claude', repeat('a', 65)),
      ('claude', 'unknown:0123456789abcdef'),
      ('claude', null)
    ) as t(provider, account)
  loop
    assert charge_claim_poll(v_token_3, v_case.provider, v_case.account),
      format('invalid lease input did not fail open: %L / %L', v_case.provider, v_case.account);
  end loop;
  assert (select string_agg(to_jsonb(l)::text, ',' order by l.user_id, l.provider_id, l.account)
          from charge_poll_leases l) = v_before,
    'invalid lease input wrote, renewed or cleaned up lease rows';

  -- 경계값(32자 프로바이더, 64자 계정, 숫자와 _ -)은 정상 임대다. 정상 호출은 그 사용자의 만료된
  -- 임대만 치운다(만료된 임대는 없는 것과 같다). 다른 사용자의 행과 살아 있는 임대는 그대로다.
  assert charge_claim_poll(v_token_3, 'a_b-9' || repeat('z', 27), repeat('f', 64)),
    'a lease at the input length limits was refused';
  assert exists (
    select 1 from charge_poll_leases
    where user_id = v_user and provider_id = 'a_b-9' || repeat('z', 27)
      and account = repeat('f', 64) and device_id = v_dev_3
  ), 'a lease at the input length limits was not written';
  assert not exists (
    select 1 from charge_poll_leases where user_id = v_user and account = 'acct-lapsed'
  ), 'a valid claim left this user''s expired lease behind';
  assert exists (
    select 1 from charge_poll_leases where user_id = v_other and account = 'acct-lapsed'
  ), 'a claim cleaned up an expired lease of another user';
  assert (select count(*) from charge_poll_leases where user_id = v_user and expires_at > now()) = 4,
    'cleaning up expired leases removed a live lease';

  -- 토큰 거부는 charge_upload와 같고, 입력 검증보다 먼저다(틀린 토큰은 fail open의 true도 못 받는다).
  foreach v_bad in array array['not-a-device-token', '', null] loop
    begin
      perform charge_claim_poll(v_bad, 'claude', 'acct-lease');
      v_rejected := false;
    exception when others then
      v_rejected := sqlerrm = 'invalid device token';
    end;
    assert v_rejected, format('a lease claim accepted token %L', v_bad);
    begin
      perform charge_claim_poll(v_bad, 'Not Valid', 'unknown:x');
      v_rejected := false;
    exception when others then
      v_rejected := sqlerrm = 'invalid device token';
    end;
    assert v_rejected, format('invalid lease input skipped authentication for token %L', v_bad);
  end loop;

  -- 연결 해제(charge_revoke_device)나 앱에서 지운 기기의 임대는 함께 사라져, 남은 기기가 만료를
  -- 기다리지 않고 바로 넘겨받는다. 해제한 토큰으로는 더 이상 임대를 요청할 수 없다.
  perform charge_revoke_device(v_token_2);
  assert not exists (select 1 from charge_poll_leases where device_id = v_dev_2),
    'revoking a device left its lease behind';
  begin
    perform charge_claim_poll(v_token_2, 'claude', 'acct-lease');
    v_rejected := false;
  exception when others then
    v_rejected := sqlerrm = 'invalid device token';
  end;
  assert v_rejected, 'a revoked device token still claimed a lease';
  assert charge_claim_poll(v_token_1, 'claude', 'acct-lease'),
    'the lease of a revoked device still blocked the remaining devices';
  delete from charge_devices where id = v_dev_1;
  assert not exists (select 1 from charge_poll_leases where device_id = v_dev_1),
    'deleting a device left its leases behind';
  -- 계정 삭제(auth.users)도 그 사용자의 임대를 지운다.
  delete from auth.users where id = v_other;
  assert not exists (select 1 from charge_poll_leases where user_id = v_other),
    'deleting an account left its leases behind';

  -- 아래 anon 롤 검증에서 쓴다(트랜잭션 끝까지 유지). 3번과 4번은 같은 사용자의 살아 있는 기기다.
  perform set_config('test.lease_token', v_token_3, true);
  perform set_config('test.lease_token_peer', v_token_4, true);
end $$;

-- MARK: 수집기 릴리스 매니페스트 (자동 업데이트)
do $$
declare
  v_int constant text := 'sha512-' || repeat('I', 86) || '==';
  v_sig constant text := repeat('S', 86) || '==';
  v_url constant text := 'https://registry.npmjs.org/charge-connect/-/charge-connect-';
  v_row record;
  v_bad jsonb;
  v_rejected boolean;
begin
  -- 이 트랜잭션 안에서만 비운다(파일 끝에서 전체 rollback).
  delete from charge_collector_releases;
  assert not exists (select 1 from charge_latest_collector()),
    'an empty release table produced a manifest row';

  -- 최신은 버전 크기가 아니라 게시 시각이 가장 늦은 한 행이다.
  insert into charge_collector_releases (version, integrity, tarball, signature, key_id, published_at)
  values ('0.9.0', v_int, v_url || '0.9.0.tgz', v_sig, 'k1', now() - interval '3 days'),
         ('0.10.0', v_int, v_url || '0.10.0.tgz', v_sig, 'k1', now() - interval '1 day'),
         ('0.2.0', v_int, v_url || '0.2.0.tgz', v_sig, 'k2', now() - interval '1 hour');
  assert (select count(*) from charge_latest_collector()) = 1,
    'the manifest returned more than one release';
  -- 수집기는 key_id로 검증 키를 고르므로, 서명과 같은 행의 key_id가 함께 나와야 한다.
  select * into v_row from charge_latest_collector();
  assert v_row.version = '0.2.0' and v_row.tarball = v_url || '0.2.0.tgz'
     and v_row.integrity = v_int and v_row.signature = v_sig and v_row.key_id = 'k2',
    'the manifest did not return the most recently published release with its key id';

  -- 게시 시각이 같으면 숫자로 큰 버전이다. 문자열로 비교하면 0.9.0이 0.10.0을 이긴다.
  update charge_collector_releases set published_at = now();
  select * into v_row from charge_latest_collector();
  assert v_row.version = '0.10.0' and v_row.key_id = 'k1',
    'a publish time tie was broken by text order, not numeric version';

  -- 형식이 틀린 행은 게시하는 순간 거부된다. 들어가면 전 기기가 서명 검증 전 형식 검사에서 조용히 버린다.
  -- 규칙은 수집기가 서명 검증 전에 거르는 형식과 같다.
  for v_bad in
    select value from jsonb_array_elements(jsonb_build_array(
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.10.0.tgz', 'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', 'https://example.com/charge-connect/-/charge-connect-0.11.0.tgz',
                         'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.0-beta.1', 'integrity', v_int,
                         'tarball', v_url || '0.11.0-beta.1.tgz', 'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.0', 'integrity', 'sha1-' || repeat('a', 27) || '=',
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.0', 'integrity', 'sha512-' || repeat('I', 88),
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', repeat('S', 43) || '=', 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', repeat('S', 88), 'key_id', 'k1'),
      -- 버전 문법은 수집기(updater.js parseReleaseVersion)와 같다: 앞자리 0, 7자리 조각, ASCII 밖의 숫자는 거부
      jsonb_build_object('version', '1.02.0', 'integrity', v_int,
                         'tarball', v_url || '1.02.0.tgz', 'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '1.1234567.0', 'integrity', v_int,
                         'tarball', v_url || '1.1234567.0.tgz', 'signature', v_sig, 'key_id', 'k1'),
      jsonb_build_object('version', '0.11.' || chr(1633), 'integrity', v_int,
                         'tarball', v_url || '0.11.' || chr(1633) || '.tgz', 'signature', v_sig, 'key_id', 'k1'),
      -- key_id는 소문자와 숫자 1~16자다. 수집기의 공개키 맵 조회에 그대로 쓰인다.
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', 'K1'),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', ''),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', repeat('k', 17)),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', 'k-1'),
      jsonb_build_object('version', '0.11.0', 'integrity', v_int,
                         'tarball', v_url || '0.11.0.tgz', 'signature', v_sig, 'key_id', 'k1' || chr(10))
    ))
  loop
    begin
      insert into charge_collector_releases (version, integrity, tarball, signature, key_id)
      values (v_bad->>'version', v_bad->>'integrity', v_bad->>'tarball', v_bad->>'signature',
              v_bad->>'key_id');
      v_rejected := false;
    exception when check_violation then
      v_rejected := true;
    end;
    assert v_rejected, format('a malformed release row was accepted: %s', v_bad);
  end loop;

  -- key_id가 없는 행(키 식별자 이전의 서명 형식)은 게시할 수 없다.
  begin
    insert into charge_collector_releases (version, integrity, tarball, signature)
    values ('0.11.0', v_int, v_url || '0.11.0.tgz', v_sig);
    v_rejected := false;
  exception when not_null_violation then
    v_rejected := true;
  end;
  assert v_rejected, 'a release row without a key id was accepted';

  -- 수집기가 받는 경계값(0 조각, 6자리 조각, 16자 key_id, 숫자만인 key_id)은 그대로 들어간다
  insert into charge_collector_releases (version, integrity, tarball, signature, key_id)
  values ('0.0.999999', v_int, v_url || '0.0.999999.tgz', v_sig, repeat('k', 16)),
         ('100000.0.10', v_int, v_url || '100000.0.10.tgz', v_sig, '0');
  assert (select count(*) from charge_collector_releases where version in ('0.0.999999', '100000.0.10')) = 2,
    'a release row the collector accepts was rejected';
end $$;

-- MARK: 관측 정리 (14일 넘게 보고되지 않은 관측, 같은 기기의 unknown:* 이행)
do $$
declare
  v_user constant uuid := '10000000-0000-4000-8000-000000000041';
  v_other constant uuid := '10000000-0000-4000-8000-000000000042';
  v_token_1 text;
  v_token_2 text;
  v_token_o text;
  v_dev_1 uuid;
  v_dev_2 uuid;
  v_dev_o uuid;
  v_reset constant timestamptz := date_trunc('minute', now() + interval '3 days');
begin
  insert into auth.users (id) values (v_user), (v_other);
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTK001', v_user, now() + interval '10 minutes'),
         ('TESTK002', v_user, now() + interval '10 minutes'),
         ('TESTK003', v_other, now() + interval '10 minutes');
  v_token_1 := charge_claim_pairing_code('TESTK001', 'Clean-1', '20000000-0000-4000-8000-000000000041');
  v_token_2 := charge_claim_pairing_code('TESTK002', 'Clean-2', '20000000-0000-4000-8000-000000000042');
  v_token_o := charge_claim_pairing_code('TESTK003', 'Clean-Other', '20000000-0000-4000-8000-000000000043');
  select id into v_dev_1 from charge_devices where token_hash = encode(digest(v_token_1, 'sha256'), 'hex');
  select id into v_dev_2 from charge_devices where token_hash = encode(digest(v_token_2, 'sha256'), 'hex');
  select id into v_dev_o from charge_devices where token_hash = encode(digest(v_token_o, 'sha256'), 'hex');

  -- 1번 기기가 계정 해시를 모르던 때의 관측을 남긴다. 다른 프로바이더, 다른 기기의 unknown:*도 둔다.
  perform charge_upload(v_token_1, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'unknown:1111111111111111',
                       'collected_at', now()),
    jsonb_build_object('id', 'codex', 'name', 'Codex', 'account', 'unknown:2222222222222222',
                       'collected_at', now())
  ), '{"claude":"ok","codex":"ok"}'::jsonb);
  perform charge_upload(v_token_2, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'unknown:3333333333333333',
                       'collected_at', now())
  ), '{"claude":"ok"}'::jsonb);
  -- 스트릭 이력은 계정 단위라 관측 정리와 함께 지워지면 안 된다.
  insert into charge_quota_blocks
    (user_id, provider_id, account, window_kind, reset_at, observed_accounts,
     first_seen_at, last_seen_at)
  values (v_user, 'claude', 'unknown:1111111111111111', 'weekly', v_reset,
          array['unknown:1111111111111111'], now() - interval '2 days', now()),
         (v_user, 'claude', 'acct-silent', 'weekly', v_reset,
          array['acct-silent'], now() - interval '2 days', now());

  -- 해시 없는 업로드(''나 다른 unknown:*)는 이행 근거가 아니다.
  perform charge_upload(v_token_1, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'unknown:4444444444444444',
                       'collected_at', now()),
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', '', 'collected_at', now())
  ), '{"claude":"ok"}'::jsonb);
  assert exists (
    select 1 from charge_provider_observations
    where device_id = v_dev_1 and provider_id = 'claude' and account = 'unknown:1111111111111111'
  ) and exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'claude' and account = 'unknown:1111111111111111'
  ), 'an upload without a known account hash removed an unidentified observation';

  -- 같은 기기가 계정 해시를 알아내면 그 프로바이더의 unknown:* 관측은 바로 치운다. 캐시 폴백으로
  -- 계정을 싣고 온 실패 보고여도 같다(실패 중에는 20분 은퇴가 돌지 않는다).
  perform charge_upload(v_token_1, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'acct-known', 'collected_at', now())
  ), '{"claude":"error:rate_limited;retry_at=1900000000"}'::jsonb);
  assert not exists (
    select 1 from charge_provider_observations
    where device_id = v_dev_1 and provider_id = 'claude' and account like 'unknown:%'
  ), 'unidentified observations of this device survived an upload that carried the account hash';
  -- 마지막 관측이 사라졌으므로 정리 트리거가 호환용 canonical 카드도 지운다.
  assert not exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'claude'
      and account in ('unknown:1111111111111111', 'unknown:4444444444444444')
  ), 'the canonical card of a migrated unidentified observation survived';
  assert exists (
    select 1 from charge_provider_observations
    where device_id = v_dev_1 and provider_id = 'codex' and account = 'unknown:2222222222222222'
  ), 'an account hash for one provider removed the unidentified observation of another provider';
  assert exists (
    select 1 from charge_provider_observations
    where device_id = v_dev_2 and provider_id = 'claude' and account = 'unknown:3333333333333333'
  ), 'an upload from one device removed the unidentified observation of another device';
  assert exists (
    select 1 from charge_quota_blocks where user_id = v_user and account = 'unknown:1111111111111111'
  ), 'unidentified observation cleanup deleted streak history';

  -- 14일 넘게 아무 업로드에도 실리지 않은 관측은 사용자 범위에서 치운다. 기기별 은퇴는 그 기기가
  -- 다시 업로드해야만 돌기 때문에, 버려진 기기의 관측은 영원히 남아 한 달 묵은 카드로 뜬다.
  perform charge_upload(v_token_1, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'acct-silent', 'collected_at', now()),
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'acct-quiet', 'collected_at', now()),
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'acct-shared', 'collected_at', now())
  ), '{"claude":"ok"}'::jsonb);
  perform charge_upload(v_token_2, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'acct-shared', 'collected_at', now())
  ), '{"claude":"ok"}'::jsonb);
  perform charge_upload(v_token_o, '[]'::jsonb, null, jsonb_build_array(
    jsonb_build_object('id', 'claude', 'name', 'Claude', 'account', 'acct-other-silent',
                       'collected_at', now())
  ), '{"claude":"ok"}'::jsonb);
  update charge_provider_observations set last_reported_at = now() - interval '15 days'
  where (device_id = v_dev_1 and account in ('acct-silent', 'acct-shared'))
     or (device_id = v_dev_o and account = 'acct-other-silent');
  update charge_provider_observations set last_reported_at = now() - interval '13 days'
  where device_id = v_dev_1 and account = 'acct-quiet';

  -- 정리는 업로드한 기기와 무관하게 그 사용자 범위에서 돈다. 2번 기기가 빈 업로드를 보낸다.
  perform charge_upload(v_token_2, '[]'::jsonb, null, '[]'::jsonb, '{}'::jsonb);
  assert not exists (
    select 1 from charge_provider_observations where device_id = v_dev_1 and account = 'acct-silent'
  ), 'an observation nobody reported for 14 days was not cleaned up';
  assert not exists (
    select 1 from charge_providers where user_id = v_user and id = 'claude' and account = 'acct-silent'
  ), 'the canonical card of a long-silent observation survived';
  assert exists (
    select 1 from charge_provider_observations where device_id = v_dev_1 and account = 'acct-quiet'
  ) and exists (
    select 1 from charge_providers where user_id = v_user and id = 'claude' and account = 'acct-quiet'
  ), 'an observation silent for less than 14 days was cleaned up';
  assert not exists (
    select 1 from charge_provider_observations where device_id = v_dev_1 and account = 'acct-shared'
  ), 'a long-silent observation survived because another device still reports the account';
  assert exists (
    select 1 from charge_provider_observations where device_id = v_dev_2 and account = 'acct-shared'
  ) and exists (
    select 1 from charge_providers where user_id = v_user and id = 'claude' and account = 'acct-shared'
  ), 'cleaning one device''s silent observation removed a card another device still reports';
  -- 다른 사용자의 행은 그 사용자의 업로드가 정리한다(업로드마다 자기 사용자 행만 훑는다).
  assert exists (
    select 1 from charge_provider_observations where device_id = v_dev_o and account = 'acct-other-silent'
  ), 'an upload cleaned up observations of another user';
  assert exists (
    select 1 from charge_quota_blocks where user_id = v_user and account = 'acct-silent'
  ), 'long-silent observation cleanup deleted streak history';
end $$;

-- MARK: 14일 정리 인덱스
-- 정리는 업로드마다 사용자 범위에서 돈다. 기본키는 (user_id, device_id, ...)라 last_reported_at 조건을
-- 인덱스로 좁히지 못해, 이 인덱스가 없으면 매 업로드가 그 사용자의 관측을 전부 읽는다.
do $$
declare
  v_line text;
  v_plan text := '';
begin
  -- indkey는 0부터 시작하는 배열이라 1부터 시작하는 배열 리터럴과 바로 비교하면 늘 거짓이다.
  -- 컬럼 이름을 키 순서대로 모아 비교한다.
  assert exists (
    select 1 from pg_index i
    where i.indrelid = 'public.charge_provider_observations'::regclass
      and (select array_agg(a.attname::text order by k.ord)
           from unnest(string_to_array(i.indkey::text, ' ')::int2[]) with ordinality k(attnum, ord)
           join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum)
          = array['user_id', 'last_reported_at']
  ), 'no index on charge_provider_observations (user_id, last_reported_at)';
  -- 순차 스캔만 끄면 플래너는 두 인덱스(기본키, 새 인덱스) 중 정리 조건을 모두 쓰는 쪽을 골라야 한다.
  perform set_config('enable_seqscan', 'off', true);
  for v_line in execute format(
    'explain delete from public.charge_provider_observations cpo
      where cpo.user_id = %L and cpo.last_reported_at < now() - interval %L',
    '10000000-0000-4000-8000-000000000041', '14 days')
  loop
    v_plan := v_plan || v_line || chr(10);
  end loop;
  perform set_config('enable_seqscan', 'on', true);
  assert v_plan like '%charge_provider_observations_user_last_reported_at_idx%',
    format('the 14 day cleanup does not use the (user_id, last_reported_at) index: %s', v_plan);
end $$;

-- MARK: RLS (위 테스트는 전부 superuser 한 세션이라 정책을 통째로 지워도 통과한다)
-- 실제로 남의 행이 보이지 않는지는 authenticated 롤로 바꿔서만 확인할 수 있다.
do $$
declare
  v_a constant uuid := '10000000-0000-4000-8000-0000000000a1';
  v_b constant uuid := '10000000-0000-4000-8000-0000000000b1';
  v_token_a text;
  v_token_b text;
  v_payload jsonb;
  v_daily jsonb;
begin
  insert into auth.users (id) values (v_a), (v_b);
  insert into charge_pairing_codes (code, user_id, expires_at)
  values ('TESTRLSA', v_a, now() + interval '10 minutes'),
         ('TESTRLSB', v_b, now() + interval '10 minutes');
  v_token_a := charge_claim_pairing_code('TESTRLSA', 'RLS-A',
                                         '20000000-0000-4000-8000-0000000000a1');
  v_token_b := charge_claim_pairing_code('TESTRLSB', 'RLS-B',
                                         '20000000-0000-4000-8000-0000000000b1');
  v_daily := jsonb_build_array(jsonb_build_object(
    'period', current_date, 'total_cost', 1, 'total_tokens', 10
  ));
  v_payload := jsonb_build_array(jsonb_build_object(
    'id', 'claude', 'name', 'Claude', 'account', 'acct-rls',
    'weekly', jsonb_build_object(
      'percent', 100,
      'resets_at', date_trunc('minute', now() + interval '5 days'),
      'window_minutes', 10080
    ),
    'collected_at', now()
  ));
  perform charge_upload(v_token_a, v_daily,
                        jsonb_build_object('collected_at', now()), v_payload,
                        '{"claude":"ok"}'::jsonb);
  perform charge_upload(v_token_b, v_daily,
                        jsonb_build_object('collected_at', now()), v_payload,
                        '{"claude":"ok"}'::jsonb);
  -- 임대는 정책이 아예 없어 자기 행조차 읽히면 안 된다. 그걸 보려면 A의 임대가 있어야 한다.
  assert charge_claim_poll(v_token_a, 'claude', 'acct-rls'), 'RLS fixture is broken: no lease for user A';
  -- 두 사용자 모두 여섯 테이블에 행이 있어야 아래 격리 검증이 의미를 가진다.
  assert (select count(*) from charge_daily where user_id in (v_a, v_b)) = 2
     and (select count(*) from charge_live where user_id in (v_a, v_b)) = 2
     and (select count(*) from charge_providers where user_id in (v_a, v_b)) = 2
     and (select count(*) from charge_provider_observations where user_id in (v_a, v_b)) = 2
     and (select count(*) from charge_quota_blocks where user_id in (v_a, v_b)) = 2
     and (select count(*) from charge_devices where user_id in (v_a, v_b)) = 2
     and (select count(*) from charge_poll_leases where user_id = v_a) = 1,
    'RLS fixture is broken: both users must have rows in every table';
end $$;

-- 클라이언트 롤이 테이블을 읽을 수 있어야 RLS 검증에 의미가 있다(권한이 없으면 정책이
-- 있든 없든 못 읽는다). Supabase는 이 권한을 public 스키마 기본 권한으로 이미 주므로,
-- 재현 환경에 없을 때만 채운다. 정책은 그대로 두고 권한만 연다.
grant usage on schema public, auth to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant select on auth.users to anon, authenticated;

-- auth.uid()가 어떤 세션 변수를 읽는지는 재현 환경마다 다르다. 아래 fixture assert가
-- 깨지면 그 환경의 auth.uid() 구현을 보고 여기에 세션 변수를 하나 더 세팅하면 된다.
set local "request.jwt.claim.sub" = '10000000-0000-4000-8000-0000000000a1';
set local "test.uid" = '10000000-0000-4000-8000-0000000000a1';
set local role authenticated;

do $$
declare
  v_a constant uuid := '10000000-0000-4000-8000-0000000000a1';
begin
  assert auth.uid() = v_a, 'RLS fixture is broken: the jwt claim did not reach auth.uid()';
  -- 자기 행은 보이고 남의 행은 한 줄도 보이면 안 된다. 정책을 지우면 앞 조건이,
  -- using (true)로 열면 뒤 조건이 깨진다.
  assert exists (select 1 from charge_daily where user_id = v_a)
     and not exists (select 1 from charge_daily where user_id <> v_a),
    'charge_daily leaked rows across users';
  assert exists (select 1 from charge_live where user_id = v_a)
     and not exists (select 1 from charge_live where user_id <> v_a),
    'charge_live leaked rows across users';
  assert exists (select 1 from charge_providers where user_id = v_a)
     and not exists (select 1 from charge_providers where user_id <> v_a),
    'charge_providers leaked rows across users';
  assert exists (select 1 from charge_provider_observations where user_id = v_a)
     and not exists (select 1 from charge_provider_observations where user_id <> v_a),
    'charge_provider_observations leaked rows across users';
  assert exists (select 1 from charge_quota_blocks where user_id = v_a)
     and not exists (select 1 from charge_quota_blocks where user_id <> v_a),
    'charge_quota_blocks leaked rows across users';
  assert exists (select 1 from charge_devices where user_id = v_a)
     and not exists (select 1 from charge_devices where user_id <> v_a),
    'charge_devices leaked rows across users';
  -- 쓰기 정책은 없다. 모든 쓰기는 RPC를 거쳐야 하며, 특히 페어링 코드는 읽히면 안 된다.
  assert not exists (select 1 from charge_pairing_codes), 'pairing codes are readable by clients';
  -- 릴리스 목록도 정책이 없어 RPC로만 읽는다.
  assert exists (select 1 from charge_latest_collector())
     and not exists (select 1 from charge_collector_releases),
    'collector releases are directly readable by signed-in clients';
  -- 임대는 앱이 읽을 이유가 없다. 자기 기기의 임대도 보이지 않는다.
  assert not exists (select 1 from charge_poll_leases),
    'poll leases are directly readable by signed-in clients';
end $$;

reset role;
reset "request.jwt.claim.sub";
reset "test.uid";

-- 수집기는 anon 키로 호출한다. security definer RPC가 anon 롤에서 실제로 돌아야 하고,
-- 릴리스와 임대 테이블은 정책이 없어 클라이언트가 직접 읽거나 쓸 수 없어야 한다.
set local role anon;

do $$
declare
  v_rejected boolean;
begin
  -- 임대 RPC는 anon이 볼 수 없는 행(RLS)을 보고 판정해야 한다. 소유자 권한으로 돌지 않으면
  -- 다른 기기의 임대를 못 보거나 쓰기 자체가 거부된다.
  assert charge_claim_poll(current_setting('test.lease_token'), 'claude', 'acct-anon'),
    'the anon role could not claim a free lease through the RPC';
  assert not charge_claim_poll(current_setting('test.lease_token_peer'), 'claude', 'acct-anon'),
    'the anon role got a lease another device of the same user holds';
  assert not exists (select 1 from charge_poll_leases),
    'poll leases are directly readable by anon';
  begin
    insert into charge_poll_leases (user_id, provider_id, account, device_id, expires_at)
    values ('10000000-0000-4000-8000-000000000031', 'claude', 'acct-direct',
            gen_random_uuid(), now() + interval '1 day');
    v_rejected := false;
  exception when insufficient_privilege then
    v_rejected := true;
  end;
  assert v_rejected, 'anon wrote a poll lease directly';

  assert exists (select 1 from charge_latest_collector()),
    'the anon role could not read the latest collector release through the RPC';
  assert not exists (select 1 from charge_collector_releases),
    'collector releases are directly readable by anon';
  begin
    insert into charge_collector_releases (version, integrity, tarball, signature, key_id)
    values ('9.9.9', 'sha512-' || repeat('I', 86) || '==',
            'https://registry.npmjs.org/charge-connect/-/charge-connect-9.9.9.tgz',
            repeat('S', 86) || '==', 'k1');
    v_rejected := false;
  exception when insufficient_privilege then
    v_rejected := true;
  end;
  assert v_rejected, 'anon published a collector release directly';
end $$;

reset role;

-- MARK: 함수 실행 권한
-- PUBLIC에서만 회수하면 Supabase가 public 스키마에 걸어둔 기본 권한 때문에 anon/authenticated에
-- 남은 실행 권한으로 내부 헬퍼가 그대로 PostgREST RPC가 된다.
do $$
declare
  v_fn text;
  v_role text;
begin
  foreach v_fn in array array[
    'public.charge_safe_ts(text)',
    'public.charge_stamp(text)',
    'public.charge_num(text)',
    'public.charge_safe_date(text)',
    'public.charge_cleanup_provider_observation()'
  ] loop
    foreach v_role in array array['anon', 'authenticated'] loop
      assert not has_function_privilege(v_role, v_fn, 'execute'),
        format('internal helper %s is still exposed to %s', v_fn, v_role);
    end loop;
  end loop;

  -- 반대로 수집기와 앱이 실제로 쓰는 RPC는 계속 열려 있어야 한다.
  assert has_function_privilege('anon', 'public.charge_upload(text, jsonb, jsonb, jsonb, jsonb)', 'execute')
     and has_function_privilege('anon', 'public.charge_claim_pairing_code(text, text, text)', 'execute')
     and has_function_privilege('anon', 'public.charge_revoke_device(text)', 'execute')
     and has_function_privilege('authenticated', 'public.charge_create_pairing_code()', 'execute')
     and has_function_privilege('authenticated', 'public.charge_delete_account()', 'execute'),
    'a public RPC lost its execute grant';

  -- 로그인이 필요한 RPC는 anon 목록에서도 빠져야 한다. PUBLIC에서만 회수하면 Supabase가
  -- public 스키마에 걸어둔 기본 권한으로 anon에 붙은 EXECUTE가 남아, 세션 없는 호출자에게도
  -- PostgREST가 이 RPC를 노출한다.
  assert not has_function_privilege('anon', 'public.charge_create_pairing_code()', 'execute')
     and not has_function_privilege('anon', 'public.charge_delete_account()', 'execute'),
    'a login-only RPC is still exposed to anon';

  -- 수집기 RPC는 anon 키로 호출되므로 열려 있어야 하고, PUBLIC 기본 실행 권한은 charge_upload처럼
  -- 회수한다. 소유자 권한으로 돌아야 RLS 뒤의 행을 읽을 수 있고, search_path를 고정해야
  -- 호출자가 같은 이름의 객체로 함수 안의 참조를 가로채지 못한다.
  assert has_function_privilege('anon', 'public.charge_claim_poll(text, text, text)', 'execute')
     and has_function_privilege('authenticated', 'public.charge_claim_poll(text, text, text)', 'execute')
     and has_function_privilege('anon', 'public.charge_latest_collector()', 'execute')
     and has_function_privilege('authenticated', 'public.charge_latest_collector()', 'execute'),
    'a collector RPC lost its execute grant';
  assert not exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid in ('public.charge_claim_poll(text, text, text)'::regprocedure,
                    'public.charge_latest_collector()'::regprocedure)
      and a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ), 'a collector RPC is still executable by PUBLIC';
  -- 새로 만들었거나 운영 배포본에서 바뀐 security definer 함수는 search_path를 public, extensions,
  -- pg_temp로 고정한다. pg_temp가 빠지면 임시 스키마가 맨 앞에서 검색되어, 임시 테이블을 만들 수 있는
  -- 호출자가 같은 이름의 테이블로 함수 안의 참조를 가로챌 수 있다.
  assert not exists (
    select 1 from pg_proc p
    where p.oid in ('public.charge_claim_poll(text, text, text)'::regprocedure,
                    'public.charge_latest_collector()'::regprocedure,
                    'public.charge_upload(text, jsonb, jsonb, jsonb, jsonb)'::regprocedure,
                    'public.charge_claim_pairing_code(text, text, text)'::regprocedure,
                    'public.charge_cleanup_provider_observation()'::regprocedure)
      and not (p.prosecdef and p.proconfig = array['search_path=public, extensions, pg_temp'])
  ), 'a new or changed security definer function lacks search_path = public, extensions, pg_temp';
  -- 대체된 동료 관측 RPC가 남으면 PostgREST 목록에 계속 노출된다.
  assert to_regprocedure('public.charge_peer_observations(text)') is null,
    'the replaced peer observation RPC still exists';
  -- 같은 이름의 오버로드가 생기면 PostgREST RPC가 모호성 오류로 멈춘다(구버전 5인자 호출 포함).
  assert (select count(*) from pg_proc
          where pronamespace = 'public'::regnamespace and proname = 'charge_upload') = 1,
    'charge_upload gained an overload';
  assert (select count(*) from pg_proc
          where pronamespace = 'public'::regnamespace
            and proname in ('charge_claim_poll', 'charge_latest_collector')) = 2,
    'a collector RPC gained an overload';
end $$;

-- 로그인 전용 RPC의 1차 방어선은 grant에서 anon을 빼는 것(위 assert)이고, 2차 방어선은
-- 함수 안의 auth.uid() 검사다. authenticated 롤은 실행 권한이 있으므로 sub 클레임이 없는
-- 토큰으로 오면 함수 본문까지 도달한다. 그때 가드가 없으면 페어링 코드가 user_id null로
-- 발급되거나 계정 삭제가 조용히 통과한다.
set local role authenticated;

do $$
declare
  v_guarded boolean;
begin
  assert auth.uid() is null, 'guard fixture is broken: a session leaked into the block';
  begin
    perform charge_create_pairing_code();
    v_guarded := false;
  exception when others then
    v_guarded := sqlerrm = 'not authenticated';
  end;
  assert v_guarded, 'a sessionless caller minted a pairing code';

  begin
    perform charge_delete_account();
    v_guarded := false;
  exception when others then
    v_guarded := sqlerrm = 'not authenticated';
  end;
  assert v_guarded, 'a sessionless caller reached the account deletion RPC';
end $$;

reset role;

rollback;

-- 로컬 PostgreSQL 전용 회귀 테스트.
-- schema-v2.sql 적용 뒤 superuser로 실행하며, 전체를 rollback하므로 테스트 행은 남지 않는다.
begin;

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
  assert not exists (
    select 1 from charge_providers
    where user_id = v_user and id = 'codex' and account = 'acct-b-only'
  ), 'provider observed only by the deleted device survived';
end $$;

rollback;

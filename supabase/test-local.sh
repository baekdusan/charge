#!/usr/bin/env bash
# schema-v2.sql 로컬 회귀 테스트. 임시 PostgreSQL 클러스터를 띄워 Supabase가 이미 제공하는 것
# (anon/authenticated/service_role 롤, auth.users, auth.uid(), extensions 스키마의 pgcrypto,
# public 스키마 기본 권한)만 흉내 낸 뒤, 스키마를 두 번 적용하고 schema-v2.test.sql을 돌린다.
# 끝나면 클러스터를 멈추고 지운다. 운영 DB에는 접속하지 않는다.
#
# 사용법: supabase/test-local.sh
#   PG_BIN=/opt/homebrew/opt/postgresql@17/bin   initdb, pg_ctl, psql 위치 (기본: PATH)
#   CHARGE_PG_PORT=54329                         루프백 TCP 포트 (기본 54329)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="${PG_BIN:+$PG_BIN/}"
port="${CHARGE_PG_PORT:-54329}"
work="$(mktemp -d "${TMPDIR:-/tmp}/charge-pg.XXXXXX")"
export PGHOST=127.0.0.1 PGPORT="$port" PGUSER=postgres
unset PGPASSWORD PGOPTIONS PGDATABASE PGSERVICE

cleanup() {
  "${bin}pg_ctl" -D "$work/data" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

"${bin}initdb" -D "$work/data" -U postgres -A trust -E UTF8 --locale=C >/dev/null
# 유닉스 소켓 경로 상한(macOS 103바이트)에 걸리지 않게 소켓은 끄고 루프백 TCP만 연다.
"${bin}pg_ctl" -D "$work/data" -l "$work/server.log" -w \
  -o "-p $port -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off" \
  start >/dev/null || { cat "$work/server.log" >&2; exit 1; }

"${bin}psql" -X -q -v ON_ERROR_STOP=1 -d postgres -c "create database charge_test;"
run() { "${bin}psql" -X -q -v ON_ERROR_STOP=1 -d charge_test "$@"; }

run <<'SQL'
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create schema extensions;
create extension pgcrypto with schema extensions;
create schema auth;
create table auth.users (id uuid primary key);
-- Supabase의 auth.uid()와 같은 본문
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;
grant usage on schema public, auth, extensions to anon, authenticated, service_role;
-- Supabase는 public에 새로 만든 테이블과 함수마다 클라이언트 롤 권한을 붙인다. 이것이 없으면
-- 스키마의 권한 회수 구문이 실제로 필요한지 테스트가 확인할 수 없다.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter database charge_test set search_path = "$user", public, extensions;
SQL

echo "fresh apply"
run -c "set client_min_messages = warning" -f "$here/schema-v2.sql"
echo "re-apply"
run -c "set client_min_messages = warning" -f "$here/schema-v2.sql"
echo "schema-v2.test.sql"
run -f "$here/schema-v2.test.sql" >/dev/null
echo "ok"

-- TokenBar: 토큰 사용량 동기화 스키마
-- Supabase SQL Editor에 붙여넣어 실행하세요.

create table if not exists public.tokenbar_daily (
  period date primary key,
  total_cost double precision not null default 0,
  total_tokens bigint not null default 0,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  cache_read_tokens bigint not null default 0,
  cache_creation_tokens bigint not null default 0,
  models jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

-- 현재 활성 5시간 블록 스냅샷 (한 행만 유지)
create table if not exists public.tokenbar_live (
  id int primary key default 1 check (id = 1),
  active_block jsonb,
  updated_at timestamptz not null default now()
);

alter table public.tokenbar_daily enable row level security;
alter table public.tokenbar_live enable row level security;

-- 읽기는 anon 허용 (개인 사용량 수치만 담김 — 민감 정보 없음)
-- 쓰기는 정책이 없으므로 service_role(수집기)만 가능
drop policy if exists "anon read tokenbar_daily" on public.tokenbar_daily;
create policy "anon read tokenbar_daily" on public.tokenbar_daily
  for select to anon using (true);

drop policy if exists "anon read tokenbar_live" on public.tokenbar_live;
create policy "anon read tokenbar_live" on public.tokenbar_live
  for select to anon using (true);

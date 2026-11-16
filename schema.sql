-- 사주×MBTI 앱 저장소 설정 (Supabase → SQL Editor에 통째로 붙여넣고 Run)
-- 방문자는 표에 직접 접근 못 하고, 아래 함수 4개로만 쓰기/집계 읽기 가능

create table if not exists rx (
  uid text primary key,
  r jsonb not null default '{}',
  note text not null default '',
  combo text not null default '',
  at timestamptz not null default now()
);
create table if not exists ev (
  id bigserial primary key,
  name text not null,
  src text not null default '',
  combo text not null default '',
  sid text not null default '',
  at timestamptz not null default now()
);
alter table rx enable row level security;
alter table ev enable row level security;
create index if not exists ev_src_name on ev (src, name);

-- 반응 저장 (기기별 익명 번호로 덮어쓰기)
create or replace function rx_save(p_uid text, p_r jsonb, p_note text, p_combo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_uid is null or length(p_uid) < 16 or length(p_uid) > 64 then raise exception 'bad uid'; end if;
  if jsonb_typeof(coalesce(p_r, '{}'::jsonb)) <> 'object' or pg_column_size(p_r) > 20000 then raise exception 'bad r'; end if;
  insert into rx (uid, r, note, combo, at)
  values (p_uid, coalesce(p_r, '{}'), left(coalesce(p_note, ''), 200), left(coalesce(p_combo, ''), 40), now())
  on conflict (uid) do update set r = excluded.r, note = excluded.note, combo = excluded.combo, at = now();
end $$;

-- 통계용: 반응만 (기기 번호·한 줄 메모는 안 내보냄)
create or replace function rx_stats()
returns table (r jsonb, combo text) language sql stable security definer set search_path = public as $$
  select r, combo from rx order by at desc limit 5000;
$$;

-- 방문 기록 (정해진 이름만 받음)
create or replace function track(p_name text, p_src text, p_combo text, p_sid text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_name not in ('visit','result','spicy','share_img','copy','ask','some','group','report') then return; end if;
  if p_sid is null or length(p_sid) < 16 or length(p_sid) > 64 then return; end if;
  insert into ev (name, src, combo, sid)
  values (p_name, left(coalesce(nullif(p_src, ''), 'direct'), 30), left(coalesce(p_combo, ''), 40), p_sid);
end $$;

-- 유입별 단계 집계 (사람 수)
create or replace function ev_stats()
returns table (src text, name text, people bigint) language sql stable security definer set search_path = public as $$
  select src, name, count(distinct sid) from ev group by src, name;
$$;

revoke all on table rx, ev from anon, authenticated;
revoke execute on function rx_save(text, jsonb, text, text), rx_stats(), track(text, text, text, text), ev_stats() from public;
grant execute on function rx_save(text, jsonb, text, text), rx_stats(), track(text, text, text, text), ev_stats() to anon, authenticated;

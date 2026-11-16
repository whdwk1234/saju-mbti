-- 사주×MBTI 앱 2차 설정 (2026-11-16): 단톡방 지도 실시간 + 익명 한 줄 상담소
-- Supabase → SQL Editor에 통째로 붙여넣고 Run. 여러 번 실행해도 안전함.
-- 방문자는 표에 직접 접근 못 하고, 아래 함수로만 쓰기/읽기 가능 (1차와 같은 방식)

-- ───────── 단톡방 지도 ─────────
create table if not exists room (
  code text primary key,
  q smallint[] not null,
  part smallint not null default 1,
  owner text not null,
  at timestamptz not null default now()
);
create table if not exists room_mem (
  code text not null references room(code) on delete cascade,
  name text not null,
  combo text not null,
  a smallint not null,
  uid text not null,
  at timestamptz not null default now(),
  primary key (code, name)
);
create unique index if not exists room_mem_uid on room_mem (code, uid);
create index if not exists room_owner on room (owner, at);
alter table room enable row level security;
alter table room_mem enable row level security;

create or replace function ok_uid(p text) returns boolean language sql immutable as $$
  select p is not null and length(p) between 16 and 64 and p ~ '^[A-Za-z0-9]+$';
$$;
create or replace function ok_combo(p text) returns boolean language sql immutable as $$
  select coalesce(p ~ '^(gap|eul|byeong|jeong|mu|gi|gyeong|sin|im|gye)_[EI][SN][TF][JP]$', false);
$$;

-- 방 만들기: 밸런스 문제 5개(0~19, 중복 없음) → 6글자 방 번호
create or replace function room_make(p_uid text, p_q int[], p_part int default 1)
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int;
begin
  if not ok_uid(p_uid) then raise exception 'bad uid'; end if;
  if p_q is null or array_length(p_q, 1) <> 5 or (select count(distinct x) from unnest(p_q) x where x between 0 and 19) <> 5 then raise exception 'bad q'; end if;
  if p_part is null or p_part < 1 or p_part > 35 then raise exception 'bad part'; end if;
  if (select count(*) from room where owner = p_uid and at > now() - interval '1 day') >= 20 then raise exception 'limit'; end if;
  for i in 1..20 loop
    c := (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 6));
    begin
      insert into room (code, q, part, owner) values (c, p_q::smallint[], p_part, p_uid);
      return c;
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'no code';
end $$;

-- 방 들어가기 (같은 기기는 이름·답만 바꿔 덮어씀). 결과: ok / full / name / nf / bad
create or replace function room_join(p_code text, p_uid text, p_name text, p_combo text, p_a int)
returns text language plpgsql security definer set search_path = public as $$
declare n text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if not ok_uid(p_uid) or not ok_combo(p_combo) or p_a is null or p_a < 0 or p_a > 31 or length(n) < 1 or length(n) > 8 then return 'bad'; end if;
  perform 1 from room where code = p_code for update;
  if not found then return 'nf'; end if;
  if exists (select 1 from room_mem where code = p_code and name = n and uid <> p_uid) then return 'name'; end if;
  if exists (select 1 from room_mem where code = p_code and uid = p_uid) then
    update room_mem set name = n, combo = p_combo, a = p_a where code = p_code and uid = p_uid;
    return 'ok';
  end if;
  if (select count(*) from room_mem where code = p_code) >= 30 then return 'full'; end if;
  insert into room_mem (code, name, combo, a, uid) values (p_code, n, p_combo, p_a, p_uid);
  return 'ok';
end $$;

-- 방 보기 (기기 번호는 안 내보냄, me = 내가 들어간 방이면 내 이름)
create or replace function room_get(p_code text, p_uid text default '')
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'q', r.q, 'part', r.part,
    'me', (select m.name from room_mem m where m.code = r.code and m.uid = p_uid),
    'mem', coalesce((select json_agg(json_build_object('n', m.name, 'c', m.combo, 'a', m.a) order by m.at) from room_mem m where m.code = r.code), '[]'::json))
  from room r where r.code = p_code;
$$;

-- ───────── 익명 한 줄 상담소 (같은 조합끼리) ─────────
create table if not exists qa_q (
  id bigserial primary key,
  uid text not null,
  combo text not null,
  body text not null,
  reports int not null default 0,
  hidden boolean not null default false,
  at timestamptz not null default now()
);
create table if not exists qa_a (
  id bigserial primary key,
  qid bigint not null references qa_q(id) on delete cascade,
  uid text not null,
  combo text not null,
  body text not null,
  reports int not null default 0,
  hidden boolean not null default false,
  at timestamptz not null default now()
);
create table if not exists qa_rep (
  uid text not null,
  kind char(1) not null,
  tid bigint not null,
  at timestamptz not null default now(),
  primary key (uid, kind, tid)
);
-- 금칙어: Table Editor → qa_ban 표에 단어 한 줄씩 추가하면 바로 적용 (띄어쓰기 무시하고 검사)
create table if not exists qa_ban (word text primary key);
insert into qa_ban (word) values
 ('시발'),('씨발'),('ㅅㅂ'),('ㅆㅂ'),('병신'),('ㅂㅅ'),('개새'),('새끼'),('좆'),('존나'),('지랄'),('엠창'),('느금'),('니애미'),('니미'),('애미'),('애비'),
 ('꺼져'),('닥쳐'),('미친년'),('미친놈'),('한남'),('김치녀'),('틀딱'),('급식충'),('장애인새'),('섹스'),('야동'),('보지'),('자지'),('조건만남'),
 ('카톡아이디'),('오픈채팅'),('텔레그램'),('라인아이디'),('인스타아이디'),('번호줘'),('연락처')
on conflict do nothing;
create index if not exists qa_q_combo on qa_q (combo, at desc);
create index if not exists qa_a_qid on qa_a (qid, at);
alter table qa_q enable row level security;
alter table qa_a enable row level security;
alter table qa_rep enable row level security;
alter table qa_ban enable row level security;

-- 글 검사: 길이, 금칙어, 전화번호·링크·이메일
create or replace function qa_check(p text) returns text language sql stable security definer set search_path = public as $$
  select case
    when p is null or length(btrim(p)) < 2 then 'short'
    when length(btrim(p)) > 80 then 'long'
    when p ~ '\d{2,4}[-. ]?\d{3,4}[-. ]?\d{4}' or p ~* '(https?://|www\.|\.com|\.kr|\.net|open\.kakao|@)' then 'contact'
    when exists (select 1 from qa_ban b where position(lower(b.word) in lower(regexp_replace(p, '\s', '', 'g'))) > 0) then 'ban'
    else 'ok' end;
$$;

-- 고민 올리기 (하루 3개). 결과: ok / short / long / contact / ban / limit / bad
create or replace function qa_ask(p_uid text, p_combo text, p_body text)
returns text language plpgsql security definer set search_path = public as $$
declare r text;
begin
  if not ok_uid(p_uid) or not ok_combo(p_combo) then return 'bad'; end if;
  r := qa_check(p_body); if r <> 'ok' then return r; end if;
  if (select count(*) from qa_q where uid = p_uid and at > now() - interval '1 day') >= 3 then return 'limit'; end if;
  insert into qa_q (uid, combo, body) values (p_uid, p_combo, btrim(p_body));
  return 'ok';
end $$;

-- 답하기 (같은 조합만, 하루 30개, 한 고민에 한 사람 3개까지)
create or replace function qa_reply(p_uid text, p_qid bigint, p_combo text, p_body text)
returns text language plpgsql security definer set search_path = public as $$
declare r text; c text;
begin
  if not ok_uid(p_uid) or not ok_combo(p_combo) then return 'bad'; end if;
  select combo into c from qa_q where id = p_qid and not hidden;
  if c is null then return 'nf'; end if;
  if c <> p_combo then return 'combo'; end if;
  r := qa_check(p_body); if r <> 'ok' then return r; end if;
  if (select count(*) from qa_a where uid = p_uid and at > now() - interval '1 day') >= 30
     or (select count(*) from qa_a where uid = p_uid and qid = p_qid) >= 3 then return 'limit'; end if;
  insert into qa_a (qid, uid, combo, body) values (p_qid, p_uid, p_combo, btrim(p_body));
  return 'ok';
end $$;

-- 같은 조합 최근 고민 30개 + 답 (기기 번호는 안 내보냄, mine = 내가 쓴 글)
create or replace function qa_list(p_combo text, p_uid text default '')
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.at desc), '[]'::json) from (
    select q.id, q.body, q.at, (q.uid = p_uid) as mine,
      coalesce((select json_agg(json_build_object('id', a.id, 'body', a.body, 'at', a.at, 'mine', a.uid = p_uid) order by a.at)
                from qa_a a where a.qid = q.id and not a.hidden), '[]'::json) as ans
    from qa_q q where q.combo = p_combo and not q.hidden order by q.at desc limit 30) x;
$$;

-- 신고 (같은 사람은 한 번만, 3번 쌓이면 자동 숨김)
create or replace function qa_report(p_uid text, p_kind text, p_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not ok_uid(p_uid) or p_kind not in ('q', 'a') then return 'bad'; end if;
  insert into qa_rep (uid, kind, tid) values (p_uid, p_kind, p_id) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'dup'; end if;
  if p_kind = 'q' then update qa_q set reports = reports + 1, hidden = hidden or reports + 1 >= 3 where id = p_id;
  else update qa_a set reports = reports + 1, hidden = hidden or reports + 1 >= 3 where id = p_id; end if;
  return 'ok';
end $$;

-- 집계용 숫자 (관리 화면)
create or replace function qa_stats()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'q', (select count(*) from qa_q), 'a', (select count(*) from qa_a),
    'hid', (select count(*) from qa_q where hidden) + (select count(*) from qa_a where hidden),
    'rooms', (select count(*) from room), 'mem', (select count(*) from room_mem));
$$;

-- 방문 기록에 새 단계 이름 추가 (1차 함수 덮어쓰기)
create or replace function track(p_name text, p_src text, p_combo text, p_sid text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_name not in ('visit','result','spicy','share_img','copy','ask','some','group','report','room_in','qa_view','qa_post') then return; end if;
  if p_sid is null or length(p_sid) < 16 or length(p_sid) > 64 then return; end if;
  insert into ev (name, src, combo, sid)
  values (p_name, left(coalesce(nullif(p_src, ''), 'direct'), 30), left(coalesce(p_combo, ''), 40), p_sid);
end $$;

revoke all on table room, room_mem, qa_q, qa_a, qa_rep, qa_ban from anon, authenticated;
revoke all on sequence qa_q_id_seq, qa_a_id_seq from anon, authenticated;
revoke execute on function ok_uid(text), ok_combo(text), qa_check(text),
  room_make(text, int[], int), room_join(text, text, text, text, int), room_get(text, text),
  qa_ask(text, text, text), qa_reply(text, bigint, text, text), qa_list(text, text), qa_report(text, text, bigint), qa_stats() from public;
grant execute on function room_make(text, int[], int), room_join(text, text, text, text, int), room_get(text, text),
  qa_ask(text, text, text), qa_reply(text, bigint, text, text), qa_list(text, text), qa_report(text, text, bigint), qa_stats() to anon, authenticated;

-- ============================================================
-- Shadowing Script (쉐도잉 스크립트) — Supabase 설정
-- Supabase 대시보드 > SQL Editor 에 전체를 붙여 넣고 Run 하세요.
-- 맨 아래 "관리자 키"와 "참여 코드" 두 곳만 먼저 바꿔 주세요.
-- 여러 번 실행해도 안전하고, 이전 버전에서 올린 데이터도 그대로 유지돼요.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- 1) 설정 (관리자 키 해시, 참여 코드) — 아무도 직접 읽을 수 없음
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  admin_hash text not null,
  join_code text
);
alter table public.settings enable row level security;

-- 2) 계정과 로그인 세션 — 직접 읽을 수 없고 아래 함수로만 다룸
create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  login_id text not null unique,
  name text not null,
  pw_hash text not null,
  failed int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
alter table public.accounts enable row level security;

create table if not exists public.sessions (
  token_hash text primary key,
  account_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_used timestamptz not null default now()
);
alter table public.sessions enable row level security;

-- 3) 연습 세트
create table if not exists public.sets (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  script text not null,
  mode text not null default 'auto',
  fmt int not null default 2,
  tts boolean not null default false,
  segs jsonb,
  spk jsonb,
  pr jsonb,
  dur real,
  name text,
  audio_path text,
  audio_mime text,
  author text,
  owner_hash text,
  owner_id uuid references public.accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table public.sets add column if not exists owner_id uuid references public.accounts(id) on delete set null;
alter table public.sets add column if not exists lang text not null default 'id';
alter table public.sets add column if not exists visibility text not null default 'public';
alter table public.sets drop constraint if exists sets_visibility_check;
alter table public.sets add constraint sets_visibility_check check (visibility in ('public', 'partial', 'private'));

-- 일부 공개: 누구에게 공유했는지, 수락했는지
create table if not exists public.shares (
  set_id uuid not null references public.sets(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (set_id, account_id)
);
alter table public.shares enable row level security;
alter table public.sets alter column owner_hash drop not null;
alter table public.sets enable row level security;
drop policy if exists "read sets" on public.sets;
revoke all on public.sets, public.accounts, public.sessions, public.settings, public.shares from anon, authenticated;
-- 전체 공개 세트는 로그인 없이 읽을 수 있고, 나머지 읽기와 모든 쓰기는 로그인해야 해요. 모두 아래 함수로만 가능해요.

-- 4) 내부 함수
create or replace function public.naskah_hash(t text) returns text
language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(coalesce(t, ''), 'UTF8')), 'hex')
$$;

create or replace function public.naskah_acct(p_token text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if coalesce(p_token, '') = '' then return null; end if;
  update sessions set last_used = now()
   where token_hash = naskah_hash(p_token) and last_used > now() - interval '180 days'
   returning account_id into v;
  return v;
end $$;

create or replace function public.naskah_new_session(p_acct uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(32), 'hex');
begin
  insert into sessions (token_hash, account_id) values (naskah_hash(t), p_acct);
  delete from sessions where account_id = p_acct and last_used < now() - interval '180 days';
  return t;
end $$;

create or replace function public.naskah_is_admin_key(p_admin text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_admin, '') <> '' and exists (select 1 from settings where admin_hash = naskah_hash(p_admin))
$$;

create or replace function public.naskah_can(p_id uuid, p_token text, p_admin text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return false; end if;
  return naskah_is_admin_key(p_admin)
      or exists (select 1 from sets where id = p_id and owner_id = v);
end $$;

-- 이 사람이 이 세트를 볼 수 있는지 (전체 공개, 내 세트, 일부 공개로 받아서 수락한 세트)
create or replace function public.naskah_visible(s public.sets, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select s.owner_id is null or s.owner_id = v or s.visibility = 'public'
      or (s.visibility = 'partial' and exists (select 1 from shares h where h.set_id = s.id and h.account_id = v and h.status = 'accepted'))
$$;

create or replace function public.naskah_lang(p text) returns text
language sql immutable as $$
  select case when coalesce(p, '') ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$' then p else 'id' end
$$;

-- 5) 계정 함수
create or replace function public.needs_join_code() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select join_code is not null and join_code <> '' from settings where id = 1), false)
$$;

create or replace function public.sign_up(p_login text, p_name text, p_pw text, p_code text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text; v_id uuid; v_login text := lower(trim(coalesce(p_login, ''))); v_name text := trim(coalesce(p_name, ''));
begin
  select join_code into v_code from settings where id = 1;
  if v_code is not null and v_code <> '' and coalesce(p_code, '') <> v_code then return jsonb_build_object('error', 'join_code'); end if;
  if v_login !~ '^[a-z0-9_.-]{3,20}$' then return jsonb_build_object('error', 'bad_id'); end if;
  if length(v_name) < 1 or length(v_name) > 20 then return jsonb_build_object('error', 'bad_name'); end if;
  if length(coalesce(p_pw, '')) < 6 or length(p_pw) > 72 then return jsonb_build_object('error', 'bad_pw'); end if;
  if exists (select 1 from accounts where login_id = v_login) then return jsonb_build_object('error', 'id_taken'); end if;
  if (select count(*) from accounts) >= 3000 then return jsonb_build_object('error', 'full'); end if;
  insert into accounts (login_id, name, pw_hash) values (v_login, v_name, crypt(p_pw, gen_salt('bf', 8))) returning id into v_id;
  return jsonb_build_object('token', naskah_new_session(v_id), 'id', v_id, 'login', v_login, 'name', v_name);
exception when unique_violation then
  return jsonb_build_object('error', 'id_taken');
end $$;

create or replace function public.sign_in(p_login text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a accounts%rowtype;
begin
  select * into a from accounts where login_id = lower(trim(coalesce(p_login, '')));
  if not found then return jsonb_build_object('error', 'bad_login'); end if;
  if a.locked_until is not null and a.locked_until > now() then return jsonb_build_object('error', 'locked'); end if;
  if a.pw_hash <> crypt(coalesce(p_pw, ''), a.pw_hash) then
    update accounts set
      failed = case when failed + 1 >= 10 then 0 else failed + 1 end,
      locked_until = case when failed + 1 >= 10 then now() + interval '10 minutes' else locked_until end
    where id = a.id;
    return jsonb_build_object('error', 'bad_login');
  end if;
  update accounts set failed = 0, locked_until = null where id = a.id;
  return jsonb_build_object('token', naskah_new_session(a.id), 'id', a.id, 'login', a.login_id, 'name', a.name);
end $$;

create or replace function public.sign_out(p_token text) returns void
language sql security definer set search_path = public as $$
  delete from sessions where token_hash = naskah_hash(p_token)
$$;

create or replace function public.me(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); a accounts%rowtype;
begin
  if v is null then return null; end if;
  select * into a from accounts where id = v;
  return jsonb_build_object('id', a.id, 'login', a.login_id, 'name', a.name);
end $$;

create or replace function public.set_name(p_token text, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_name text := trim(coalesce(p_name, ''));
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if length(v_name) < 1 or length(v_name) > 20 then return jsonb_build_object('error', 'bad_name'); end if;
  update accounts set name = v_name where id = v;
  return jsonb_build_object('name', v_name);
end $$;

create or replace function public.change_password(p_token text, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := naskah_acct(p_token); a accounts%rowtype;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  select * into a from accounts where id = v;
  if a.pw_hash <> crypt(coalesce(p_old, ''), a.pw_hash) then return jsonb_build_object('error', 'bad_login'); end if;
  if length(coalesce(p_new, '')) < 6 or length(p_new) > 72 then return jsonb_build_object('error', 'bad_pw'); end if;
  update accounts set pw_hash = crypt(p_new, gen_salt('bf', 8)) where id = v;
  delete from sessions where account_id = v and token_hash <> naskah_hash(p_token);
  return jsonb_build_object('ok', true);
end $$;

-- 관리자가 비밀번호를 잊은 사용자의 비밀번호를 새로 정해 줄 때
create or replace function public.admin_reset_password(p_token text, p_admin text, p_login text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  if naskah_acct(p_token) is null or not naskah_is_admin_key(p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  if length(coalesce(p_new, '')) < 6 or length(p_new) > 72 then return jsonb_build_object('error', 'bad_pw'); end if;
  update accounts set pw_hash = crypt(p_new, gen_salt('bf', 8)), failed = 0, locked_until = null
   where login_id = lower(trim(coalesce(p_login, ''))) returning id into v;
  if v is null then return jsonb_build_object('error', 'no_user'); end if;
  delete from sessions where account_id = v;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.is_admin(p_admin text) returns boolean
language sql stable security definer set search_path = public as $$
  select naskah_is_admin_key(p_admin)
$$;

-- 6) 세트 함수 (모두 로그인 필요)
-- 로그인하지 않은 사람에게는 전체 공개 세트(휴지통 제외)만 보여 줘요.
create or replace function public.list_sets(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then
    return coalesce((
      select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object('author_name', a.name, 'shared_with_me', false, 'share_count', null) order by s.updated_at desc)
      from (select * from sets x where (x.owner_id is null or x.visibility = 'public') and x.deleted_at is null order by updated_at desc limit 1000) s
      left join accounts a on a.id = s.owner_id
    ), '[]'::jsonb);
  end if;
  return coalesce((
    select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object(
        'author_name', a.name,
        'shared_with_me', s.owner_id is distinct from v and s.visibility = 'partial',
        'share_count', case when s.owner_id = v then (select count(*) from shares h where h.set_id = s.id) else null end
      ) order by s.updated_at desc)
    from (select * from sets x where naskah_visible(x, v) order by updated_at desc limit 1000) s
    left join accounts a on a.id = s.owner_id
  ), '[]'::jsonb);
end $$;

drop function if exists public.create_set(jsonb, text, text);
drop function if exists public.update_set(uuid, text, jsonb);
drop function if exists public.purge_set(uuid, text);
drop function if exists public.naskah_can(uuid, text);

create or replace function public.create_set(p jsonb, p_token text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_mode text; v_acct uuid := naskah_acct(p_token);
begin
  if v_acct is null then raise exception 'auth'; end if;
  if (select count(*) from sets) >= 5000 then raise exception 'full'; end if;
  if length(coalesce(p->>'script', '')) = 0 or length(p->>'script') > 60000 then raise exception 'bad_script'; end if;
  if pg_column_size(p) > 600000 then raise exception 'too_big'; end if;
  v_mode := coalesce(p->>'mode', 'auto');
  if v_mode not in ('auto', 'line', 'sentence') then v_mode := 'auto'; end if;
  insert into sets (title, script, mode, fmt, tts, segs, spk, pr, dur, name, audio_path, audio_mime, author, owner_id, created_at, lang, visibility)
  values (
    left(coalesce(nullif(p->>'title', ''), '제목 없음'), 100),
    p->>'script', v_mode,
    case when p->>'fmt' = '2' then 2 else 1 end,
    coalesce(p->>'tts', 'false') = 'true',
    case when jsonb_typeof(p->'segs') = 'array' then p->'segs' end,
    case when jsonb_typeof(p->'spk') = 'array' then p->'spk' end,
    case when jsonb_typeof(p->'pr') = 'array' then p->'pr' end,
    case when jsonb_typeof(p->'dur') = 'number' then (p->>'dur')::real end,
    left(p->>'name', 200), left(p->>'audio_path', 200), left(p->>'audio_mime', 60),
    (select name from accounts where id = v_acct),
    v_acct,
    case when jsonb_typeof(p->'created_ms') = 'number' then to_timestamp((p->>'created_ms')::double precision / 1000) else now() end,
    naskah_lang(p->>'lang'),
    case when p->>'visibility' in ('public', 'partial', 'private') then p->>'visibility' else 'public' end
  )
  returning id into v_id;
  if jsonb_typeof(p->'share') = 'array' then
    insert into shares (set_id, account_id)
    select v_id, a.id from accounts a
     where a.id::text in (select jsonb_array_elements_text(p->'share')) and a.id <> v_acct
    on conflict do nothing;
  end if;
  return v_id;
end $$;

create or replace function public.update_set(p_id uuid, p_token text, p jsonb, p_admin text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not naskah_can(p_id, p_token, p_admin) then raise exception 'forbidden'; end if;
  if pg_column_size(p) > 600000 then raise exception 'too_big'; end if;
  update sets set
    title = case when p ? 'title' then left(coalesce(nullif(p->>'title', ''), title), 100) else title end,
    lang = case when p ? 'lang' then naskah_lang(p->>'lang') else lang end,
    segs = case when p ? 'segs' and jsonb_typeof(p->'segs') = 'array' then p->'segs' else segs end,
    spk = case when p ? 'spk' and jsonb_typeof(p->'spk') = 'array' then p->'spk' else spk end,
    pr = case when p ? 'pr' and jsonb_typeof(p->'pr') = 'array' then p->'pr' else pr end,
    deleted_at = case when p ? 'deleted' then (case when p->>'deleted' = 'true' then now() else null end) else deleted_at end,
    updated_at = case when p ? 'deleted' then updated_at else now() end
  where id = p_id;
end $$;

create or replace function public.purge_set(p_id uuid, p_token text, p_admin text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  if not naskah_can(p_id, p_token, p_admin) then raise exception 'forbidden'; end if;
  delete from sets where id = p_id returning audio_path into v_path;
  return v_path;
end $$;

-- 공유 범위 바꾸기 (세트 주인만). 일부 공개면 p_users 목록으로 공유 대상을 맞춰요.
create or replace function public.share_set(p_token text, p_id uuid, p_visibility text, p_users uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if not exists (select 1 from sets where id = p_id and owner_id = v) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_visibility not in ('public', 'partial', 'private') then return jsonb_build_object('error', 'bad_visibility'); end if;
  update sets set visibility = p_visibility where id = p_id;
  if p_visibility = 'partial' then
    delete from shares where set_id = p_id and not (account_id = any (coalesce(p_users, '{}')));
    insert into shares (set_id, account_id)
    select p_id, a.id from accounts a where a.id = any (coalesce(p_users, '{}')) and a.id <> v
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 내가 공유한 사람들과 수락 여부 (세트 주인만)
create or replace function public.get_shares(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null or not exists (select 1 from sets where id = p_id and owner_id = v) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'login', a.login_id, 'name', a.name, 'status', h.status) order by h.created_at)
    from shares h join accounts a on a.id = h.account_id where h.set_id = p_id), '[]'::jsonb);
end $$;

-- 멘션할 사람 찾기 (아이디 앞부분 또는 이름 일부)
create or replace function public.find_users(p_token text, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); q text := lower(trim(coalesce(p_q, '')));
begin
  if v is null or q = '' then return '[]'::jsonb; end if;
  q := replace(replace(replace(ltrim(q, '@'), '\', '\\'), '%', '\%'), '_', '\_');
  if q = '' then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'login', login_id, 'name', name)) from (
    select id, login_id, name from accounts
     where id <> v and (login_id like q || '%' or lower(name) like '%' || q || '%')
     order by (login_id like q || '%') desc, login_id limit 10) t), '[]'::jsonb);
end $$;

-- 나에게 온 공유 알림 (아직 수락·거절하지 않은 것)
create or replace function public.list_inbox(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then raise exception 'auth'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('set_id', s.id, 'title', s.title, 'lang', s.lang, 'owner_name', a.name, 'owner_login', a.login_id, 'created_at', h.created_at) order by h.created_at desc)
    from shares h join sets s on s.id = h.set_id left join accounts a on a.id = s.owner_id
    where h.account_id = v and h.status = 'pending' and s.visibility = 'partial' and s.deleted_at is null), '[]'::jsonb);
end $$;

-- 공유 수락·거절, 또는 이미 받은 세트를 내 목록에서 빼기(p_accept = false)
create or replace function public.respond_share(p_token text, p_set_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  update shares set status = case when p_accept then 'accepted' else 'declined' end, responded_at = now()
   where set_id = p_set_id and account_id = v;
  if not found then return jsonb_build_object('error', 'no_share'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 이전 버전(편집 키)으로 올린 세트를 로그인한 계정으로 옮기기
create or replace function public.claim_sets(p_token text, p_key text) returns int
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); n int;
begin
  if v is null or length(coalesce(p_key, '')) < 16 then return 0; end if;
  update sets set owner_id = v where owner_id is null and owner_hash = naskah_hash(p_key);
  get diagnostics n = row_count;
  return n;
end $$;

-- 7) 권한: 공개 함수만 실행 가능
revoke all on function public.naskah_acct(text) from public, anon, authenticated;
revoke all on function public.naskah_new_session(uuid) from public, anon, authenticated;
revoke all on function public.naskah_is_admin_key(text) from public, anon, authenticated;
revoke all on function public.naskah_can(uuid, text, text) from public, anon, authenticated;
revoke all on function public.naskah_visible(public.sets, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'needs_join_code()', 'sign_up(text, text, text, text)', 'sign_in(text, text)', 'sign_out(text)', 'me(text)',
    'set_name(text, text)', 'change_password(text, text, text)', 'admin_reset_password(text, text, text, text)', 'is_admin(text)',
    'list_sets(text)', 'create_set(jsonb, text)', 'share_set(text, uuid, text, uuid[])', 'get_shares(text, uuid)', 'find_users(text, text)', 'list_inbox(text)', 'respond_share(text, uuid, boolean)', 'update_set(uuid, text, jsonb, text)', 'purge_set(uuid, text, text)', 'claim_sets(text, text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- 8) 녹음 파일 저장소 (파일당 20MB, 오디오만)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('audio', 'audio', true, 20971520, array['audio/*', 'video/mp4', 'video/webm'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "naskah upload audio" on storage.objects;
create policy "naskah upload audio" on storage.objects for insert to anon, authenticated with check (bucket_id = 'audio');

notify pgrst, 'reload schema';

-- 9) ★ 여기 두 곳을 바꾸세요 ★
--    관리자 키: 모든 세트를 고치고 지우고, 비밀번호를 잊은 사람의 비밀번호를 새로 정해 줄 수 있는 키. 본인만 알고 있어야 해요.
--    참여 코드: 회원가입할 때 필요한 코드. 아무나 가입해도 되면 null 로 두세요.
insert into public.settings (id, admin_hash, join_code)
values (1, public.naskah_hash('여기에-관리자-키를-적으세요'), '여기에-참여코드')
on conflict (id) do update set admin_hash = excluded.admin_hash, join_code = excluded.join_code;

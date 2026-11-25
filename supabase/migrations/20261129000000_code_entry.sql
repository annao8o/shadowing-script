-- 모두 참여 코드로 입장: 로그인하지 않은 사람도 참여 코드를 넣으면 그 공간의 '전체 공개' 세트와 폴더를 볼 수 있어요.
-- 로그인한 사람은 코드로 그 공간의 멤버가 되어 지금처럼 쓰고요. 관리자의 '로그인 없이 보기' 스위치는 없어져요.
--  - 로그인하지 않은 사람은 기기에 저장한 코드들을 p_codes 로 함께 보내요.
--  - 틀린 코드가 사이트 전체에서 5분 동안 30번을 넘으면 잠시 막아요(계정이 없는 사람도 막기 위해).
--  - 새로 정하는 참여 코드는 6자 이상이어야 해요(이미 쓰던 코드는 그대로 둘 수 있어요).
-- 여러 번 실행해도 안전해요.

-- 틀린 코드 기록 (사이트 전체)
create table if not exists public.space_code_fails (at timestamptz not null default now());
create index if not exists space_code_fails_at_idx on public.space_code_fails (at);
alter table public.space_code_fails enable row level security;
revoke all on public.space_code_fails from anon, authenticated;

-- 이 코드들로 들어갈 수 있는 공간들 (최대 20개 코드)
create or replace function public.naskah_code_spaces(p_codes text[]) returns setof uuid
language sql stable security definer set search_path = public as $$
  select s.id from spaces s
   where lower(s.join_code) in (select lower(trim(c)) from unnest(coalesce(p_codes, '{}')) with ordinality as t(c, n) where n <= 20)
$$;

-- 세트가 '전체 공개'인지 (폴더에 있으면 폴더의 범위로)
create or replace function public.naskah_public_set(s public.sets) returns boolean
language sql stable security definer set search_path = public as $$
  select s.deleted_at is null and case when s.folder_id is not null
    then exists (select 1 from folders f where f.id = s.folder_id and f.visibility = 'public')
    else s.visibility = 'public' end
$$;

-- 멤버 규칙 (스위치로 열던 길은 없앰)
create or replace function public.naskah_folder_visible(f public.folders, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select naskah_member(f.space_id, v) and (
         f.owner_id = v or f.visibility = 'public'
      or (f.visibility = 'partial' and exists (select 1 from folder_shares h where h.folder_id = f.id and h.account_id = v and h.status = 'accepted')))
$$;

create or replace function public.naskah_visible(s public.sets, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select naskah_member(s.space_id, v) and (
         coalesce(s.owner_id is null or s.owner_id = v, false)
      or case when s.folder_id is not null
           then exists (select 1 from folders f where f.id = s.folder_id and coalesce(naskah_folder_visible(f, v), false))
           else s.visibility = 'public'
             or (s.visibility = 'partial' and exists (select 1 from shares h where h.set_id = s.id and h.account_id = v and h.status = 'accepted'))
         end)
$$;

drop function if exists public.naskah_guest_space(uuid);
alter table public.spaces drop column if exists guest_ok;

-- 세트 목록: 멤버로 볼 수 있는 것 + 코드로 들어간 공간의 전체 공개
drop function if exists public.list_sets(text);
create or replace function public.list_sets(p_token text default null, p_codes text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  return coalesce((
    select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object(
        'author_name', a.name,
        'shared_with_me', v is not null and s.owner_id is distinct from v and coalesce(f.visibility, s.visibility) = 'partial' and naskah_member(s.space_id, v),
        'share_count', case when v is not null and s.owner_id = v then (select count(*) from shares h where h.set_id = s.id) else null end
      ) order by s.updated_at desc)
    from (select * from sets x
           where coalesce(naskah_visible(x, v), false)
              or (x.space_id in (select naskah_code_spaces(p_codes)) and naskah_public_set(x))
           order by updated_at desc limit 2000) s
    left join accounts a on a.id = s.owner_id
    left join folders f on f.id = s.folder_id
  ), '[]'::jsonb);
end $$;

drop function if exists public.list_folders(text);
create or replace function public.list_folders(p_token text default null, p_codes text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', f.id, 'title', f.title, 'visibility', f.visibility, 'owner_id', f.owner_id, 'owner_name', a.name, 'space_id', f.space_id,
        'shared_with_me', v is not null and f.owner_id <> v and f.visibility = 'partial' and naskah_member(f.space_id, v),
        'share_count', case when v is not null and f.owner_id = v then (select count(*) from folder_shares h where h.folder_id = f.id) else null end,
        'created_at', f.created_at, 'updated_at', f.updated_at
      ) order by f.created_at)
    from folders f left join accounts a on a.id = f.owner_id
    where coalesce(naskah_folder_visible(f, v), false)
       or (f.visibility = 'public' and f.space_id in (select naskah_code_spaces(p_codes)))
  ), '[]'::jsonb);
end $$;

-- 공간 목록: 멤버인 공간 + 코드로 들어간 공간. 관리자 키가 맞으면 전부와 참여 코드까지.
drop function if exists public.list_spaces(text, text);
create or replace function public.list_spaces(p_token text, p_admin text default null, p_codes text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); adm boolean := v is not null and naskah_is_admin_key(p_admin);
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'member', naskah_member(s.id, v), 'by_code', s.id in (select naskah_code_spaces(p_codes)),
      'members', (select count(*) from space_members m where m.space_id = s.id),
      'join_code', case when adm then s.join_code end, 'created_at', s.created_at) order by s.created_at)
    from spaces s where adm or naskah_member(s.id, v) or s.id in (select naskah_code_spaces(p_codes))), '[]'::jsonb);
end $$;

-- 틀린 코드가 너무 많은지 (사이트 전체 5분에 30번)
create or replace function public.naskah_code_locked() returns boolean
language sql stable security definer set search_path = public as $$
  select (select count(*) from space_code_fails where at > now() - interval '5 minutes') >= 30
$$;

-- 로그인하지 않고 코드 확인하기: 맞으면 공간 이름을 알려 줘요 (기기에 코드를 저장해 두고 쓰기)
create or replace function public.check_code(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sp spaces;
begin
  if naskah_code_locked() then return jsonb_build_object('error', 'too_many'); end if;
  select * into sp from spaces where lower(join_code) = lower(trim(coalesce(p_code, '')));
  if not found then
    insert into space_code_fails default values;
    delete from space_code_fails where at < now() - interval '1 day';
    return jsonb_build_object('error', 'bad_code');
  end if;
  return jsonb_build_object('ok', true, 'id', sp.id, 'name', sp.name);
end $$;

-- 로그인한 사람이 코드로 멤버 되기 (계정별 10분 10번 + 사이트 전체 제한)
create or replace function public.join_space(p_token text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); sp spaces;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if naskah_code_locked() or (select count(*) from space_join_fails where account_id = v and at > now() - interval '10 minutes') >= 10 then
    return jsonb_build_object('error', 'too_many');
  end if;
  select * into sp from spaces where lower(join_code) = lower(trim(coalesce(p_code, '')));
  if not found then
    insert into space_join_fails (account_id) values (v);
    insert into space_code_fails default values;
    delete from space_join_fails where at < now() - interval '1 day';
    delete from space_code_fails where at < now() - interval '1 day';
    return jsonb_build_object('error', 'bad_code');
  end if;
  insert into space_members (space_id, account_id) values (sp.id, v) on conflict do nothing;
  return jsonb_build_object('ok', true, 'id', sp.id, 'name', sp.name);
end $$;

-- 공간 만들기·고치기 (관리자만). 새로 정하는 코드는 6자 이상, 쓰던 코드를 그대로 두는 건 괜찮아요.
drop function if exists public.save_space(text, text, uuid, text, text, boolean);
create or replace function public.save_space(p_token text, p_admin text, p_id uuid, p_name text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_id uuid := p_id; v_name text := left(trim(coalesce(p_name, '')), 40); v_code text := trim(coalesce(p_code, ''));
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if not naskah_is_admin_key(p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  if v_name = '' then return jsonb_build_object('error', 'bad_name'); end if;
  if length(v_code) > 40 or (length(v_code) < 6 and not exists (select 1 from spaces where id = v_id and lower(join_code) = lower(v_code))) then
    return jsonb_build_object('error', 'bad_code');
  end if;
  if exists (select 1 from spaces where lower(join_code) = lower(v_code) and id is distinct from v_id) then
    return jsonb_build_object('error', 'code_taken');
  end if;
  if v_id is null then
    insert into spaces (name, join_code) values (v_name, v_code) returning id into v_id;
    insert into space_members (space_id, account_id) values (v_id, v) on conflict do nothing;
  else
    update spaces set name = v_name, join_code = v_code where id = v_id;
    if not found then return jsonb_build_object('error', 'not_found'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

revoke all on function public.naskah_code_spaces(text[]) from public, anon, authenticated;
revoke all on function public.naskah_public_set(public.sets) from public, anon, authenticated;
revoke all on function public.naskah_code_locked() from public, anon, authenticated;
revoke all on function public.naskah_folder_visible(public.folders, uuid) from public, anon, authenticated;
revoke all on function public.naskah_visible(public.sets, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'list_sets(text, text[])', 'list_folders(text, text[])', 'list_spaces(text, text, text[])',
    'check_code(text)', 'join_space(text, text)', 'save_space(text, text, uuid, text, text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

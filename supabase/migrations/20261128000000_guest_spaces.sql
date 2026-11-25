-- 공간별 '로그인 없이 보기': 관리자가 켜 두면, 로그인하지 않은 방문자(와 멤버가 아닌 사람)도
-- 그 공간의 '전체 공개' 세트와 폴더를 볼 수 있어요. 일부 공개·비공개는 계속 멤버만 봐요. 보기만 할 수 있어요.
-- 여러 번 실행해도 안전해요.

alter table public.spaces add column if not exists guest_ok boolean not null default false;

-- 이 공간이 방문자 보기를 허용하는지
create or replace function public.naskah_guest_space(p_space uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_space is not null and exists (select 1 from spaces where id = p_space and guest_ok)
$$;

create or replace function public.naskah_folder_visible(f public.folders, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (naskah_member(f.space_id, v) and (
           f.owner_id = v or f.visibility = 'public'
        or (f.visibility = 'partial' and exists (select 1 from folder_shares h where h.folder_id = f.id and h.account_id = v and h.status = 'accepted'))))
      or (f.visibility = 'public' and naskah_guest_space(f.space_id))
$$;

create or replace function public.naskah_visible(s public.sets, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (naskah_member(s.space_id, v) and (
           coalesce(s.owner_id is null or s.owner_id = v, false)
        or case when s.folder_id is not null
             then exists (select 1 from folders f where f.id = s.folder_id and coalesce(naskah_folder_visible(f, v), false))
             else s.visibility = 'public'
               or (s.visibility = 'partial' and exists (select 1 from shares h where h.set_id = s.id and h.account_id = v and h.status = 'accepted'))
           end))
      or (s.deleted_at is null and naskah_guest_space(s.space_id) and
           case when s.folder_id is not null
             then exists (select 1 from folders f where f.id = s.folder_id and f.visibility = 'public')
             else s.visibility = 'public'
           end)
$$;

-- 세트 목록: 로그인하지 않으면 '로그인 없이 보기' 공간의 전체 공개 세트만
create or replace function public.list_sets(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then
    return coalesce((
      select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object('author_name', a.name, 'shared_with_me', false, 'share_count', null) order by s.updated_at desc)
      from (select * from sets x where coalesce(naskah_visible(x, null), false) and x.deleted_at is null order by updated_at desc limit 2000) s
      left join accounts a on a.id = s.owner_id
    ), '[]'::jsonb);
  end if;
  return coalesce((
    select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object(
        'author_name', a.name,
        'shared_with_me', s.owner_id is distinct from v and coalesce(f.visibility, s.visibility) = 'partial',
        'share_count', case when s.owner_id = v then (select count(*) from shares h where h.set_id = s.id) else null end
      ) order by s.updated_at desc)
    from (select * from sets x where coalesce(naskah_visible(x, v), false) order by updated_at desc limit 2000) s
    left join accounts a on a.id = s.owner_id
    left join folders f on f.id = s.folder_id
  ), '[]'::jsonb);
end $$;

create or replace function public.list_folders(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', f.id, 'title', f.title, 'visibility', f.visibility, 'owner_id', f.owner_id, 'owner_name', a.name, 'space_id', f.space_id,
        'shared_with_me', v is not null and f.owner_id <> v and f.visibility = 'partial',
        'share_count', case when v is not null and f.owner_id = v then (select count(*) from folder_shares h where h.folder_id = f.id) else null end,
        'created_at', f.created_at, 'updated_at', f.updated_at
      ) order by f.created_at)
    from folders f left join accounts a on a.id = f.owner_id
    where coalesce(naskah_folder_visible(f, v), false)
  ), '[]'::jsonb);
end $$;

-- 공간 목록: 내가 멤버인 공간 + '로그인 없이 보기' 공간 (로그인하지 않아도). 관리자 키가 맞으면 전부와 참여 코드까지.
create or replace function public.list_spaces(p_token text, p_admin text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); adm boolean := v is not null and naskah_is_admin_key(p_admin);
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'member', naskah_member(s.id, v), 'guest', s.guest_ok,
      'members', (select count(*) from space_members m where m.space_id = s.id),
      'join_code', case when adm then s.join_code end, 'created_at', s.created_at) order by s.created_at)
    from spaces s where adm or s.guest_ok or naskah_member(s.id, v)), '[]'::jsonb);
end $$;

-- 공간 만들기·고치기 (관리자만). p_guest: '로그인 없이 보기' (null 이면 그대로, 새 공간은 꺼짐)
drop function if exists public.save_space(text, text, uuid, text, text);
create or replace function public.save_space(p_token text, p_admin text, p_id uuid, p_name text, p_code text, p_guest boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_id uuid := p_id; v_name text := left(trim(coalesce(p_name, '')), 40); v_code text := trim(coalesce(p_code, ''));
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if not naskah_is_admin_key(p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  if v_name = '' then return jsonb_build_object('error', 'bad_name'); end if;
  if length(v_code) < 4 or length(v_code) > 40 then return jsonb_build_object('error', 'bad_code'); end if;
  if exists (select 1 from spaces where lower(join_code) = lower(v_code) and id is distinct from v_id) then
    return jsonb_build_object('error', 'code_taken');
  end if;
  if v_id is null then
    insert into spaces (name, join_code, guest_ok) values (v_name, v_code, coalesce(p_guest, false)) returning id into v_id;
    insert into space_members (space_id, account_id) values (v_id, v) on conflict do nothing;
  else
    update spaces set name = v_name, join_code = v_code, guest_ok = coalesce(p_guest, guest_ok) where id = v_id;
    if not found then return jsonb_build_object('error', 'not_found'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

revoke all on function public.naskah_guest_space(uuid) from public, anon, authenticated;
revoke all on function public.naskah_folder_visible(public.folders, uuid) from public, anon, authenticated;
revoke all on function public.naskah_visible(public.sets, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'list_sets(text)', 'list_folders(text)', 'list_spaces(text, text)', 'save_space(text, text, uuid, text, text, boolean)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

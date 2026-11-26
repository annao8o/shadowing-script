-- 참여 코드 없이 공간에 들어가요.
--  - 공간 목록은 누구에게나 다 보여요. 로그인한 사람은 공간을 고르면 그 공간의 멤버가 돼요 (join_space 에 공간 id).
--  - 로그인하지 않은 사람도 모든 공간의 '전체 공개' 세트와 폴더를 볼 수 있어요.
--  - 공간은 관리자만 만들고 이름을 바꿔요. 참여 코드는 더 이상 쓰지 않아요 (예전 값은 남아 있어도 쓰이지 않아요).
--  - 일부 공개·비공개는 지금처럼 멤버 규칙(naskah_visible)을 따라요.
-- 여러 번 실행해도 안전해요.

alter table public.spaces alter column join_code drop not null;

-- 세트 목록: 멤버로 볼 수 있는 것 + 모든 공간의 전체 공개 (p_codes 는 예전 화면을 위해 받기만 해요)
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
           where coalesce(naskah_visible(x, v), false) or naskah_public_set(x)
           order by updated_at desc limit 2000) s
    left join accounts a on a.id = s.owner_id
    left join folders f on f.id = s.folder_id
  ), '[]'::jsonb);
end $$;

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
    where coalesce(naskah_folder_visible(f, v), false) or f.visibility = 'public'
  ), '[]'::jsonb);
end $$;

-- 공간 목록: 모든 공간과 내가 멤버인지
create or replace function public.list_spaces(p_token text, p_admin text default null, p_codes text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'member', naskah_member(s.id, v),
      'members', (select count(*) from space_members m where m.space_id = s.id),
      'created_at', s.created_at) order by s.created_at)
    from spaces s), '[]'::jsonb);
end $$;

-- 공간 들어가기 (로그인한 사람): 고른 공간의 멤버가 돼요
drop function if exists public.join_space(text, text);
drop function if exists public.check_code(text);
create or replace function public.join_space(p_token text, p_space uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); sp spaces;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  select * into sp from spaces where id = p_space;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  insert into space_members (space_id, account_id) values (sp.id, v) on conflict do nothing;
  return jsonb_build_object('ok', true, 'id', sp.id, 'name', sp.name);
end $$;

-- 공간 만들기·이름 바꾸기 (관리자만)
drop function if exists public.save_space(text, text, uuid, text, text);
create or replace function public.save_space(p_token text, p_admin text, p_id uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_id uuid := p_id; v_name text := left(trim(coalesce(p_name, '')), 40);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if not naskah_is_admin_key(p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  if v_name = '' then return jsonb_build_object('error', 'bad_name'); end if;
  if v_id is null then
    insert into spaces (name) values (v_name) returning id into v_id;
    insert into space_members (space_id, account_id) values (v_id, v) on conflict do nothing;
  else
    update spaces set name = v_name where id = v_id;
    if not found then return jsonb_build_object('error', 'not_found'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'list_sets(text, text[])', 'list_folders(text, text[])', 'list_spaces(text, text, text[])',
    'join_space(text, uuid)', 'save_space(text, text, uuid, text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

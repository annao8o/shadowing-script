-- 대본 / 회화 분류: 스크립트와 폴더마다 어느 탭에 보일지 정해요 ('script' = 대본, 'talk' = 회화).
--  - 폴더 안의 스크립트는 폴더의 분류를 따라요. 폴더 분류를 바꾸면 안의 스크립트도 같이 바뀌어요.
--  - 스크립트 분류는 올린 사람과 관리자가, 폴더 분류는 폴더 주인이 바꿔요.
--  - 회화 탭 맨 위 목록의 순서·고정은 'talk:<공간 id>' 로 따로 저장해요.
-- 여러 번 실행해도 안전해요.

alter table public.sets add column if not exists kind text not null default 'script';
alter table public.folders add column if not exists kind text not null default 'script';

create or replace function public.set_kind(p_token text, p_admin text, p_id uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if naskah_acct(p_token) is null then return jsonb_build_object('error', 'auth'); end if;
  if p_kind not in ('script', 'talk') then return jsonb_build_object('error', 'bad_kind'); end if;
  if not naskah_can(p_id, p_token, p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  update sets set kind = p_kind where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.set_folder_kind(p_token text, p_id uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if p_kind not in ('script', 'talk') then return jsonb_build_object('error', 'bad_kind'); end if;
  update folders set kind = p_kind where id = p_id and owner_id = v;
  if not found then return jsonb_build_object('error', 'forbidden'); end if;
  update sets set kind = p_kind where folder_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 폴더 목록에 분류를 함께
create or replace function public.list_folders(p_token text default null, p_codes text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', f.id, 'title', f.title, 'visibility', f.visibility, 'owner_id', f.owner_id, 'owner_name', a.name, 'space_id', f.space_id,
        'kind', f.kind,
        'shared_with_me', v is not null and f.owner_id <> v and f.visibility = 'partial' and naskah_member(f.space_id, v),
        'share_count', case when v is not null and f.owner_id = v then (select count(*) from folder_shares h where h.folder_id = f.id) else null end,
        'created_at', f.created_at, 'updated_at', f.updated_at
      ) order by f.created_at)
    from folders f left join accounts a on a.id = f.owner_id
    where coalesce(naskah_folder_visible(f, v), false) or f.visibility = 'public'
  ), '[]'::jsonb);
end $$;

-- 순서·고정: 회화 탭 맨 위 목록('talk:<공간 id>')도 받아요
create or replace function public.save_order(p_token text, p_scope text, p_items text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if p_scope is null or p_scope !~ '^(top|talk|folder):[0-9a-f-]{36}$' then return jsonb_build_object('error', 'bad_scope'); end if;
  if coalesce(array_length(p_items, 1), 0) > 3000
     or exists (select 1 from unnest(coalesce(p_items, '{}')) x where x is null or x !~ '^[fs]:[0-9a-f-]{36}$') then
    return jsonb_build_object('error', 'bad_items');
  end if;
  if coalesce(array_length(p_items, 1), 0) = 0 then
    delete from list_orders where account_id = v and scope = p_scope;
  else
    if (select count(*) from list_orders where account_id = v) >= 500
       and not exists (select 1 from list_orders where account_id = v and scope = p_scope) then
      return jsonb_build_object('error', 'full');
    end if;
    insert into list_orders (account_id, scope, items) values (v, p_scope, p_items)
    on conflict (account_id, scope) do update set items = excluded.items, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.save_pins(p_token text, p_admin text, p_scope text, p_items text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if naskah_acct(p_token) is null then return jsonb_build_object('error', 'auth'); end if;
  if not naskah_is_admin_key(p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_scope is null or p_scope !~ '^(top|talk|folder):[0-9a-f-]{36}$' then return jsonb_build_object('error', 'bad_scope'); end if;
  if coalesce(array_length(p_items, 1), 0) > 200
     or exists (select 1 from unnest(coalesce(p_items, '{}')) x where x is null or x !~ '^[fs]:[0-9a-f-]{36}$') then
    return jsonb_build_object('error', 'bad_items');
  end if;
  if coalesce(array_length(p_items, 1), 0) = 0 then
    delete from list_pins where scope = p_scope;
  else
    if (select count(*) from list_pins) >= 2000 and not exists (select 1 from list_pins where scope = p_scope) then
      return jsonb_build_object('error', 'full');
    end if;
    insert into list_pins (scope, items) values (p_scope, p_items)
    on conflict (scope) do update set items = excluded.items, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'set_kind(text, text, uuid, text)', 'set_folder_kind(text, uuid, text)', 'list_folders(text, text[])',
    'save_order(text, text, text[])', 'save_pins(text, text, text, text[])'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

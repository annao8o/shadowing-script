-- 관리자도 다른 사람이 올린 세트의 공개 범위를 바꿀 수 있어요 (지금까지는 세트 주인만).
--  - share_set, get_shares 에 관리자 키 p_admin 을 받아요. 로그인한 상태여야 해요.
--  - 공유 대상은 지금처럼 같은 공간의 멤버만, 세트 주인은 빼요.
-- 여러 번 실행해도 안전해요.

drop function if exists public.share_set(text, uuid, text, uuid[]);
create or replace function public.share_set(p_token text, p_id uuid, p_visibility text, p_users uuid[] default null, p_admin text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_space uuid; v_owner uuid;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if not naskah_can(p_id, p_token, p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  select space_id, owner_id into v_space, v_owner from sets where id = p_id;
  if not found then return jsonb_build_object('error', 'forbidden'); end if;
  if p_visibility not in ('public', 'partial', 'private') then return jsonb_build_object('error', 'bad_visibility'); end if;
  update sets set visibility = p_visibility where id = p_id;
  if p_visibility = 'partial' then
    delete from shares where set_id = p_id and not (account_id = any (coalesce(p_users, '{}')));
    insert into shares (set_id, account_id)
    select p_id, a.id from accounts a
     where a.id = any (coalesce(p_users, '{}')) and a.id is distinct from v_owner and naskah_member(v_space, a.id)
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.get_shares(text, uuid);
create or replace function public.get_shares(p_token text, p_id uuid, p_admin text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not naskah_can(p_id, p_token, p_admin) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'login', a.login_id, 'name', a.name, 'status', h.status) order by h.created_at)
    from shares h join accounts a on a.id = h.account_id where h.set_id = p_id), '[]'::jsonb);
end $$;

revoke all on function public.share_set(text, uuid, text, uuid[], text) from public;
revoke all on function public.get_shares(text, uuid, text) from public;
grant execute on function public.share_set(text, uuid, text, uuid[], text) to anon, authenticated;
grant execute on function public.get_shares(text, uuid, text) to anon, authenticated;

notify pgrst, 'reload schema';

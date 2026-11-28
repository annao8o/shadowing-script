-- 관리자 고정: 관리자가 고정한 스크립트·폴더는 모든 사람의 목록 맨 위에, 관리자가 정한 순서로 나와요.
--  - 목록마다('top:<공간 id>', 'folder:<폴더 id>') 고정 항목('f:<폴더 id>', 's:<스크립트 id>')을 순서대로 저장해요.
--  - 누구나 읽을 수 있어요(보이는 건 각자 볼 수 있는 항목뿐이에요). 바꾸는 건 관리자 키가 있는 로그인한 사람만.
-- 여러 번 실행해도 안전해요.

create table if not exists public.list_pins (
  scope text primary key,
  items text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.list_pins enable row level security;
revoke all on public.list_pins from anon, authenticated;

create or replace function public.list_pins() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_object_agg(scope, to_jsonb(items)) from list_pins), '{}'::jsonb)
$$;

create or replace function public.save_pins(p_token text, p_admin text, p_scope text, p_items text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if naskah_acct(p_token) is null then return jsonb_build_object('error', 'auth'); end if;
  if not naskah_is_admin_key(p_admin) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_scope is null or p_scope !~ '^(top|folder):[0-9a-f-]{36}$' then return jsonb_build_object('error', 'bad_scope'); end if;
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

revoke all on function public.list_pins() from public;
revoke all on function public.save_pins(text, text, text, text[]) from public;
grant execute on function public.list_pins() to anon, authenticated;
grant execute on function public.save_pins(text, text, text, text[]) to anon, authenticated;

notify pgrst, 'reload schema';

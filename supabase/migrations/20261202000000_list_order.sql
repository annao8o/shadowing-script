-- 목록 순서를 각자 정해요. 사람마다, 목록마다(공간의 맨 위 목록 'top:<공간 id>', 폴더 안 'folder:<폴더 id>') 순서를 저장해요.
--  - 항목은 'f:<폴더 id>' 또는 's:<스크립트 id>' 이에요. 순서에 없는 새 항목은 화면에서 맨 위에 보여요.
--  - 본인 것만 읽고 쓸 수 있어요. 로그인하지 않은 사람은 기기에만 저장해요.
-- 여러 번 실행해도 안전해요.

create table if not exists public.list_orders (
  account_id uuid not null references public.accounts(id) on delete cascade,
  scope text not null,
  items text[] not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (account_id, scope)
);
alter table public.list_orders enable row level security;
revoke all on public.list_orders from anon, authenticated;

-- 내 순서들: { "top:<id>": ["f:..","s:.."], ... }
create or replace function public.get_orders(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  return coalesce((select jsonb_object_agg(scope, to_jsonb(items)) from list_orders where account_id = v), '{}'::jsonb);
end $$;

-- 한 목록의 순서 저장 (빈 목록이면 지워요)
create or replace function public.save_order(p_token text, p_scope text, p_items text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if p_scope is null or p_scope !~ '^(top|folder):[0-9a-f-]{36}$' then return jsonb_build_object('error', 'bad_scope'); end if;
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

revoke all on function public.get_orders(text) from public;
revoke all on function public.save_order(text, text, text[]) from public;
grant execute on function public.get_orders(text) to anon, authenticated;
grant execute on function public.save_order(text, text, text[]) to anon, authenticated;

notify pgrst, 'reload schema';

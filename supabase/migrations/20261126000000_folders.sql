-- 폴더: 내 세트를 폴더에 모으고, 폴더 단위로 공개 범위를 정해요. (한 단계만, 폴더 안에 폴더는 없음)
-- 폴더 안에 든 세트는 세트 자신의 공개 범위 대신 폴더의 공개 범위를 따라요.
-- 일부 공개 폴더는 받는 사람이 한 번 수락하면 나중에 넣는 세트도 함께 보여요.
-- 여러 번 실행해도 안전해요.

create table if not exists public.folders (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id) on delete cascade,
  title text not null,
  visibility text not null default 'private' check (visibility in ('public', 'partial', 'private')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.folders enable row level security;

create table if not exists public.folder_shares (
  folder_id uuid not null references public.folders(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (folder_id, account_id)
);
alter table public.folder_shares enable row level security;

alter table public.sets add column if not exists folder_id uuid references public.folders(id) on delete set null;
create index if not exists sets_folder_id_idx on public.sets (folder_id);
revoke all on public.folders, public.folder_shares from anon, authenticated;

-- 이 사람이 이 폴더를 볼 수 있는지 (전체 공개, 내 폴더, 일부 공개로 받아서 수락한 폴더)
create or replace function public.naskah_folder_visible(f public.folders, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select f.owner_id = v or f.visibility = 'public'
      or (f.visibility = 'partial' and exists (select 1 from folder_shares h where h.folder_id = f.id and h.account_id = v and h.status = 'accepted'))
$$;

-- 세트 공개 규칙: 폴더에 들어 있으면 폴더의 범위, 아니면 세트 자신의 범위
create or replace function public.naskah_visible(s public.sets, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(s.owner_id is null or s.owner_id = v, false)
      or case when s.folder_id is not null
           then exists (select 1 from folders f where f.id = s.folder_id and coalesce(naskah_folder_visible(f, v), false))
           else s.visibility = 'public'
             or (s.visibility = 'partial' and exists (select 1 from shares h where h.set_id = s.id and h.account_id = v and h.status = 'accepted'))
         end
$$;

-- 세트 목록: 폴더 규칙을 따르고, 폴더 일부 공개로 받은 세트도 '공유받음'으로 표시해요.
create or replace function public.list_sets(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then
    return coalesce((
      select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object('author_name', a.name, 'shared_with_me', false, 'share_count', null) order by s.updated_at desc)
      from (select * from sets x where naskah_visible(x, null) and x.deleted_at is null order by updated_at desc limit 1000) s
      left join accounts a on a.id = s.owner_id
    ), '[]'::jsonb);
  end if;
  return coalesce((
    select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object(
        'author_name', a.name,
        'shared_with_me', s.owner_id is distinct from v and coalesce(f.visibility, s.visibility) = 'partial',
        'share_count', case when s.owner_id = v then (select count(*) from shares h where h.set_id = s.id) else null end
      ) order by s.updated_at desc)
    from (select * from sets x where naskah_visible(x, v) order by updated_at desc limit 1000) s
    left join accounts a on a.id = s.owner_id
    left join folders f on f.id = s.folder_id
  ), '[]'::jsonb);
end $$;

-- 내가 볼 수 있는 폴더 목록
create or replace function public.list_folders(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', f.id, 'title', f.title, 'visibility', f.visibility, 'owner_id', f.owner_id, 'owner_name', a.name,
        'shared_with_me', v is not null and f.owner_id <> v and f.visibility = 'partial',
        'share_count', case when f.owner_id = v then (select count(*) from folder_shares h where h.folder_id = f.id) else null end,
        'created_at', f.created_at, 'updated_at', f.updated_at
      ) order by f.created_at)
    from folders f left join accounts a on a.id = f.owner_id
    where coalesce(naskah_folder_visible(f, v), false)
  ), '[]'::jsonb);
end $$;

-- 폴더 만들기(p_id 가 null) 또는 이름·공개 범위 바꾸기 (폴더 주인만). 일부 공개면 p_users 로 공유 대상을 맞춰요.
create or replace function public.save_folder(p_token text, p_id uuid, p_title text, p_visibility text, p_users uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_id uuid := p_id; v_title text := left(trim(coalesce(p_title, '')), 80);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if v_title = '' then return jsonb_build_object('error', 'bad_title'); end if;
  if p_visibility not in ('public', 'partial', 'private') then return jsonb_build_object('error', 'bad_visibility'); end if;
  if v_id is null then
    if (select count(*) from folders where owner_id = v) >= 200 then return jsonb_build_object('error', 'full'); end if;
    insert into folders (owner_id, title, visibility) values (v, v_title, p_visibility) returning id into v_id;
  else
    update folders set title = v_title, visibility = p_visibility, updated_at = now() where id = v_id and owner_id = v;
    if not found then return jsonb_build_object('error', 'forbidden'); end if;
  end if;
  if p_visibility = 'partial' then
    delete from folder_shares where folder_id = v_id and not (account_id = any (coalesce(p_users, '{}')));
    insert into folder_shares (folder_id, account_id)
    select v_id, a.id from accounts a where a.id = any (coalesce(p_users, '{}')) and a.id <> v
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 폴더 지우기 (폴더 주인만). 안에 있던 세트는 지우지 않고 폴더 밖으로 꺼내요.
-- 지금 보던 사람이 그대로 볼 수 있게 세트에 폴더의 공개 범위와 공유 대상을 옮겨 줘요.
create or replace function public.delete_folder(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); f folders;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  select * into f from folders where id = p_id and owner_id = v;
  if not found then return jsonb_build_object('error', 'forbidden'); end if;
  if f.visibility = 'partial' then
    insert into shares (set_id, account_id, status, created_at, responded_at)
    select s.id, h.account_id, h.status, h.created_at, h.responded_at
      from sets s join folder_shares h on h.folder_id = f.id
     where s.folder_id = f.id and h.account_id is distinct from s.owner_id
    on conflict (set_id, account_id) do update set status = excluded.status, responded_at = excluded.responded_at;
  end if;
  update sets set visibility = f.visibility, folder_id = null where folder_id = f.id;
  delete from folders where id = f.id;
  return jsonb_build_object('ok', true);
end $$;

-- 폴더를 누구에게 공유했고 수락했는지 (폴더 주인만)
create or replace function public.get_folder_shares(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null or not exists (select 1 from folders where id = p_id and owner_id = v) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'login', a.login_id, 'name', a.name, 'status', h.status) order by h.created_at)
    from folder_shares h join accounts a on a.id = h.account_id where h.folder_id = p_id), '[]'::jsonb);
end $$;

-- 폴더 공유 수락·거절, 또는 받은 폴더를 내 목록에서 빼기(p_accept = false)
create or replace function public.respond_folder_share(p_token text, p_folder_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  update folder_shares set status = case when p_accept then 'accepted' else 'declined' end, responded_at = now()
   where folder_id = p_folder_id and account_id = v;
  if not found then return jsonb_build_object('error', 'no_share'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 공유 알림: 세트 알림(kind = 'set')과 폴더 알림(kind = 'folder')을 함께 보여 줘요.
create or replace function public.list_inbox(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then raise exception 'auth'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
    select jsonb_build_object('kind', 'set', 'set_id', s.id, 'title', s.title, 'lang', s.lang, 'owner_name', a.name, 'owner_login', a.login_id, 'created_at', h.created_at) x
      from shares h join sets s on s.id = h.set_id left join accounts a on a.id = s.owner_id
     where h.account_id = v and h.status = 'pending' and s.visibility = 'partial' and s.folder_id is null and s.deleted_at is null
    union all
    select jsonb_build_object('kind', 'folder', 'folder_id', f.id, 'title', f.title, 'owner_name', a.name, 'owner_login', a.login_id, 'created_at', h.created_at,
             'count', (select count(*) from sets s where s.folder_id = f.id and s.deleted_at is null))
      from folder_shares h join folders f on f.id = h.folder_id left join accounts a on a.id = f.owner_id
     where h.account_id = v and h.status = 'pending' and f.visibility = 'partial'
  ) q), '[]'::jsonb);
end $$;

-- 세트 고치기: 폴더에 넣거나 빼는 것(folder_id)도 할 수 있어요. 폴더는 세트 주인의 폴더여야 해요.
create or replace function public.update_set(p_id uuid, p_token text, p jsonb, p_admin text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not naskah_can(p_id, p_token, p_admin) then raise exception 'forbidden'; end if;
  if pg_column_size(p) > 600000 then raise exception 'too_big'; end if;
  if p ? 'script' and (length(coalesce(p->>'script', '')) = 0 or length(p->>'script') > 60000) then raise exception 'bad_script'; end if;
  if p ? 'folder_id' and p->>'folder_id' is not null and not exists (
       select 1 from folders f join sets s on s.owner_id = f.owner_id
        where s.id = p_id and f.id::text = p->>'folder_id') then raise exception 'bad_folder'; end if;
  update sets set
    title = case when p ? 'title' then left(coalesce(nullif(p->>'title', ''), title), 100) else title end,
    lang = case when p ? 'lang' then naskah_lang(p->>'lang') else lang end,
    script = case when p ? 'script' then p->>'script' else script end,
    mode = case when p ? 'mode' then (case when p->>'mode' in ('auto', 'line', 'sentence') then p->>'mode' else 'auto' end) else mode end,
    tts = case when p ? 'tts' then coalesce(p->>'tts', 'false') = 'true' else tts end,
    dur = case when p ? 'dur' then (case when jsonb_typeof(p->'dur') = 'number' then (p->>'dur')::real end) else dur end,
    name = case when p ? 'name' then left(p->>'name', 200) else name end,
    audio_path = case when p ? 'audio_path' then left(p->>'audio_path', 200) else audio_path end,
    audio_mime = case when p ? 'audio_mime' then left(p->>'audio_mime', 60) else audio_mime end,
    folder_id = case when p ? 'folder_id' then (p->>'folder_id')::uuid else folder_id end,
    segs = case when p ? 'segs' and jsonb_typeof(p->'segs') = 'array' then p->'segs' else segs end,
    spk = case when p ? 'spk' and jsonb_typeof(p->'spk') = 'array' then p->'spk' else spk end,
    pr = case when p ? 'pr' and jsonb_typeof(p->'pr') = 'array' then p->'pr' else pr end,
    deleted_at = case when p ? 'deleted' then (case when p->>'deleted' = 'true' then now() else null end) else deleted_at end,
    updated_at = case when p ? 'deleted' then updated_at else now() end
  where id = p_id;
end $$;

-- 권한: 내부 함수는 막고, 사이트가 부르는 함수만 열어요.
revoke all on function public.naskah_folder_visible(public.folders, uuid) from public, anon, authenticated;
revoke all on function public.naskah_visible(public.sets, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'list_sets(text)', 'list_inbox(text)', 'update_set(uuid, text, jsonb, text)',
    'list_folders(text)', 'save_folder(text, uuid, text, text, uuid[])', 'delete_folder(text, uuid)',
    'get_folder_shares(text, uuid)', 'respond_folder_share(text, uuid, boolean)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

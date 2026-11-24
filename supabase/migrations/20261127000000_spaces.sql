-- 공간: 참여 코드로 들어가는 방. 세트와 폴더는 모두 한 공간에 속하고, 그 공간의 멤버만 볼 수 있어요.
--  - 공간은 관리자만 만들고(이름·참여 코드), 사람들은 참여 코드를 넣어 공간에 들어가요.
--  - 회원가입에는 더 이상 참여 코드가 필요 없어요.
--  - '전체 공개'는 '그 공간의 모든 멤버'라는 뜻이 돼요. 로그인하지 않은 방문자는 아무것도 볼 수 없어요.
--  - 처음 실행할 때 지금까지의 세트·폴더를 '기본 공간'으로 옮기고, 가입한 모든 사람을 그 공간 멤버로 넣어요.
--    기본 공간의 참여 코드는 지금 쓰던 회원가입 참여 코드를 그대로 써요.
-- 여러 번 실행해도 안전해요.

create table if not exists public.spaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  join_code text not null,
  created_at timestamptz not null default now()
);
create unique index if not exists spaces_join_code_idx on public.spaces (lower(join_code));
alter table public.spaces enable row level security;

create table if not exists public.space_members (
  space_id uuid not null references public.spaces(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (space_id, account_id)
);
alter table public.space_members enable row level security;

-- 참여 코드를 계속 틀리는 것을 막기 위한 기록 (10분에 10번까지)
create table if not exists public.space_join_fails (
  account_id uuid not null references public.accounts(id) on delete cascade,
  at timestamptz not null default now()
);
create index if not exists space_join_fails_idx on public.space_join_fails (account_id, at);
alter table public.space_join_fails enable row level security;

alter table public.sets add column if not exists space_id uuid references public.spaces(id) on delete restrict;
alter table public.folders add column if not exists space_id uuid references public.spaces(id) on delete restrict;
create index if not exists sets_space_id_idx on public.sets (space_id);
create index if not exists folders_space_id_idx on public.folders (space_id);
revoke all on public.spaces, public.space_members, public.space_join_fails from anon, authenticated;

-- 한 번만: 기존 데이터를 '기본 공간'으로 옮기기
do $$
declare v_id uuid; v_code text;
begin
  if exists (select 1 from public.spaces) then return; end if;
  if not exists (select 1 from public.accounts) and not exists (select 1 from public.sets) then return; end if;
  select nullif(trim(join_code), '') into v_code from public.settings where id = 1;
  v_code := coalesce(v_code, substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.spaces (name, join_code) values ('기본 공간', v_code) returning id into v_id;
  update public.sets set space_id = v_id where space_id is null;
  update public.folders set space_id = v_id where space_id is null;
  insert into public.space_members (space_id, account_id) select v_id, id from public.accounts on conflict do nothing;
end $$;

-- 회원가입은 참여 코드 없이
update public.settings set join_code = null where id = 1;

-- 이 사람이 이 공간의 멤버인지
create or replace function public.naskah_member(p_space uuid, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select v is not null and p_space is not null and exists (select 1 from space_members m where m.space_id = p_space and m.account_id = v)
$$;

-- 폴더 공개 규칙: 그 공간의 멤버 중에서
create or replace function public.naskah_folder_visible(f public.folders, v uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select naskah_member(f.space_id, v) and (
         f.owner_id = v or f.visibility = 'public'
      or (f.visibility = 'partial' and exists (select 1 from folder_shares h where h.folder_id = f.id and h.account_id = v and h.status = 'accepted')))
$$;

-- 세트 공개 규칙: 그 공간의 멤버 중에서, 폴더에 들어 있으면 폴더의 범위, 아니면 세트 자신의 범위
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

-- 세트 목록: 내가 멤버인 모든 공간의 세트 (space_id 포함). 로그인하지 않으면 빈 목록.
create or replace function public.list_sets(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg((to_jsonb(s) - 'owner_hash') || jsonb_build_object(
        'author_name', a.name,
        'shared_with_me', s.owner_id is distinct from v and coalesce(f.visibility, s.visibility) = 'partial',
        'share_count', case when s.owner_id = v then (select count(*) from shares h where h.set_id = s.id) else null end
      ) order by s.updated_at desc)
    from (select * from sets x where naskah_visible(x, v) order by updated_at desc limit 2000) s
    left join accounts a on a.id = s.owner_id
    left join folders f on f.id = s.folder_id
  ), '[]'::jsonb);
end $$;

create or replace function public.list_folders(p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', f.id, 'title', f.title, 'visibility', f.visibility, 'owner_id', f.owner_id, 'owner_name', a.name, 'space_id', f.space_id,
        'shared_with_me', f.owner_id <> v and f.visibility = 'partial',
        'share_count', case when f.owner_id = v then (select count(*) from folder_shares h where h.folder_id = f.id) else null end,
        'created_at', f.created_at, 'updated_at', f.updated_at
      ) order by f.created_at)
    from folders f left join accounts a on a.id = f.owner_id
    where coalesce(naskah_folder_visible(f, v), false)
  ), '[]'::jsonb);
end $$;

-- 세트 만들기: 내가 멤버인 공간(p->>'space_id')에만
create or replace function public.create_set(p jsonb, p_token text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_mode text; v_acct uuid := naskah_acct(p_token); v_space uuid;
begin
  if v_acct is null then raise exception 'auth'; end if;
  begin v_space := (p->>'space_id')::uuid; exception when others then v_space := null; end;
  if not naskah_member(v_space, v_acct) then raise exception 'no_space'; end if;
  if (select count(*) from sets) >= 5000 then raise exception 'full'; end if;
  if length(coalesce(p->>'script', '')) = 0 or length(p->>'script') > 60000 then raise exception 'bad_script'; end if;
  if pg_column_size(p) > 600000 then raise exception 'too_big'; end if;
  v_mode := coalesce(p->>'mode', 'auto');
  if v_mode not in ('auto', 'line', 'sentence') then v_mode := 'auto'; end if;
  insert into sets (title, script, mode, fmt, tts, segs, spk, pr, dur, name, audio_path, audio_mime, author, owner_id, created_at, lang, visibility, space_id)
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
    case when p->>'visibility' in ('public', 'partial', 'private') then p->>'visibility' else 'public' end,
    v_space
  )
  returning id into v_id;
  if jsonb_typeof(p->'share') = 'array' then
    insert into shares (set_id, account_id)
    select v_id, a.id from accounts a
     where a.id::text in (select jsonb_array_elements_text(p->'share')) and a.id <> v_acct and naskah_member(v_space, a.id)
    on conflict do nothing;
  end if;
  return v_id;
end $$;

-- 세트 고치기: 폴더는 세트 주인의 폴더이면서 같은 공간이어야 해요.
create or replace function public.update_set(p_id uuid, p_token text, p jsonb, p_admin text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not naskah_can(p_id, p_token, p_admin) then raise exception 'forbidden'; end if;
  if pg_column_size(p) > 600000 then raise exception 'too_big'; end if;
  if p ? 'script' and (length(coalesce(p->>'script', '')) = 0 or length(p->>'script') > 60000) then raise exception 'bad_script'; end if;
  if p ? 'folder_id' and p->>'folder_id' is not null and not exists (
       select 1 from folders f join sets s on s.owner_id = f.owner_id and s.space_id is not distinct from f.space_id
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

-- 세트 공유 범위: 공유 대상은 같은 공간의 멤버만
create or replace function public.share_set(p_token text, p_id uuid, p_visibility text, p_users uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_space uuid;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  select space_id into v_space from sets where id = p_id and owner_id = v;
  if not found then return jsonb_build_object('error', 'forbidden'); end if;
  if p_visibility not in ('public', 'partial', 'private') then return jsonb_build_object('error', 'bad_visibility'); end if;
  update sets set visibility = p_visibility where id = p_id;
  if p_visibility = 'partial' then
    delete from shares where set_id = p_id and not (account_id = any (coalesce(p_users, '{}')));
    insert into shares (set_id, account_id)
    select p_id, a.id from accounts a where a.id = any (coalesce(p_users, '{}')) and a.id <> v and naskah_member(v_space, a.id)
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 폴더 만들기·고치기: 새 폴더는 p_space(내가 멤버인 공간)에 만들어요. 공유 대상은 같은 공간의 멤버만.
drop function if exists public.save_folder(text, uuid, text, text, uuid[]);
create or replace function public.save_folder(p_token text, p_id uuid, p_title text, p_visibility text, p_users uuid[] default null, p_space uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); v_id uuid := p_id; v_space uuid := p_space; v_title text := left(trim(coalesce(p_title, '')), 80);
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if v_title = '' then return jsonb_build_object('error', 'bad_title'); end if;
  if p_visibility not in ('public', 'partial', 'private') then return jsonb_build_object('error', 'bad_visibility'); end if;
  if v_id is null then
    if not naskah_member(v_space, v) then return jsonb_build_object('error', 'no_space'); end if;
    if (select count(*) from folders where owner_id = v) >= 200 then return jsonb_build_object('error', 'full'); end if;
    insert into folders (owner_id, title, visibility, space_id) values (v, v_title, p_visibility, v_space) returning id into v_id;
  else
    update folders set title = v_title, visibility = p_visibility, updated_at = now() where id = v_id and owner_id = v returning space_id into v_space;
    if not found then return jsonb_build_object('error', 'forbidden'); end if;
  end if;
  if p_visibility = 'partial' then
    delete from folder_shares where folder_id = v_id and not (account_id = any (coalesce(p_users, '{}')));
    insert into folder_shares (folder_id, account_id)
    select v_id, a.id from accounts a where a.id = any (coalesce(p_users, '{}')) and a.id <> v and naskah_member(v_space, a.id)
    on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 공유할 사람 찾기: 그 공간의 멤버 중에서만
drop function if exists public.find_users(text, text);
create or replace function public.find_users(p_token text, p_q text, p_space uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); q text := lower(trim(coalesce(p_q, '')));
begin
  if v is null or q = '' or not naskah_member(p_space, v) then return '[]'::jsonb; end if;
  q := replace(replace(replace(ltrim(q, '@'), '\', '\\'), '%', '\%'), '_', '\_');
  if q = '' then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'login', login_id, 'name', name)) from (
    select a.id, a.login_id, a.name from accounts a join space_members m on m.account_id = a.id and m.space_id = p_space
     where a.id <> v and (a.login_id like q || '%' or lower(a.name) like '%' || q || '%')
     order by (a.login_id like q || '%') desc, a.login_id limit 10) t), '[]'::jsonb);
end $$;

-- 공유 알림: 내가 멤버인 공간의 것만, 공간 이름과 함께
create or replace function public.list_inbox(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token);
begin
  if v is null then raise exception 'auth'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
    select jsonb_build_object('kind', 'set', 'set_id', s.id, 'title', s.title, 'lang', s.lang, 'owner_name', a.name, 'owner_login', a.login_id, 'created_at', h.created_at,
             'space_id', s.space_id, 'space_name', sp.name) x
      from shares h join sets s on s.id = h.set_id left join accounts a on a.id = s.owner_id left join spaces sp on sp.id = s.space_id
     where h.account_id = v and h.status = 'pending' and s.visibility = 'partial' and s.folder_id is null and s.deleted_at is null and naskah_member(s.space_id, v)
    union all
    select jsonb_build_object('kind', 'folder', 'folder_id', f.id, 'title', f.title, 'owner_name', a.name, 'owner_login', a.login_id, 'created_at', h.created_at,
             'count', (select count(*) from sets s where s.folder_id = f.id and s.deleted_at is null), 'space_id', f.space_id, 'space_name', sp.name)
      from folder_shares h join folders f on f.id = h.folder_id left join accounts a on a.id = f.owner_id left join spaces sp on sp.id = f.space_id
     where h.account_id = v and h.status = 'pending' and f.visibility = 'partial' and naskah_member(f.space_id, v)
  ) q), '[]'::jsonb);
end $$;

-- 내 공간 목록. 관리자 키가 맞으면 모든 공간과 참여 코드를 보여 줘요.
create or replace function public.list_spaces(p_token text, p_admin text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); adm boolean := naskah_is_admin_key(p_admin);
begin
  if v is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'member', naskah_member(s.id, v),
      'members', (select count(*) from space_members m where m.space_id = s.id),
      'join_code', case when adm then s.join_code end, 'created_at', s.created_at) order by s.created_at)
    from spaces s where adm or naskah_member(s.id, v)), '[]'::jsonb);
end $$;

-- 참여 코드로 공간에 들어가기
create or replace function public.join_space(p_token text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid := naskah_acct(p_token); sp spaces;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if (select count(*) from space_join_fails where account_id = v and at > now() - interval '10 minutes') >= 10 then
    return jsonb_build_object('error', 'too_many');
  end if;
  select * into sp from spaces where lower(join_code) = lower(trim(coalesce(p_code, '')));
  if not found then
    insert into space_join_fails (account_id) values (v);
    delete from space_join_fails where at < now() - interval '1 day';
    return jsonb_build_object('error', 'bad_code');
  end if;
  insert into space_members (space_id, account_id) values (sp.id, v) on conflict do nothing;
  return jsonb_build_object('ok', true, 'id', sp.id, 'name', sp.name);
end $$;

-- 공간 만들기(p_id 가 null)·이름과 참여 코드 바꾸기 (관리자만). 만든 사람은 그 공간 멤버가 돼요.
create or replace function public.save_space(p_token text, p_admin text, p_id uuid, p_name text, p_code text) returns jsonb
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
    insert into spaces (name, join_code) values (v_name, v_code) returning id into v_id;
    insert into space_members (space_id, account_id) values (v_id, v) on conflict do nothing;
  else
    update spaces set name = v_name, join_code = v_code where id = v_id;
    if not found then return jsonb_build_object('error', 'not_found'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 권한: 내부 함수는 막고, 사이트가 부르는 함수만 열어요.
revoke all on function public.naskah_member(uuid, uuid) from public, anon, authenticated;
revoke all on function public.naskah_folder_visible(public.folders, uuid) from public, anon, authenticated;
revoke all on function public.naskah_visible(public.sets, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'list_sets(text)', 'list_folders(text)', 'create_set(jsonb, text)', 'update_set(uuid, text, jsonb, text)',
    'share_set(text, uuid, text, uuid[])', 'save_folder(text, uuid, text, text, uuid[], uuid)',
    'find_users(text, text, uuid)', 'list_inbox(text)',
    'list_spaces(text, text)', 'join_space(text, text)', 'save_space(text, text, uuid, text, text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- 한국어로 물어보기: 로그인한 사람이 적은 한국어를 DeepL로 번역해 돌려줘요.
--  - DeepL 키는 settings.deepl_key 에만 있어요. 사이트 주인이 deepl-settings.sql 로 직접 넣고, 어떤 함수도 키를 돌려주지 않아요.
--  - 한 번에 300자, 사람마다 하루 200번·3000자까지만 (DeepL 무료 한도를 한 사람이 다 쓰지 않게).
--  - DeepL 호출은 Supabase의 http 확장으로 해요. 확장을 쓸 수 없는 곳(테스트 등)에서는 만들기만 건너뛰어요.
-- 여러 번 실행해도 안전해요.

do $$
begin
  create extension if not exists http with schema extensions;
exception when others then
  raise warning 'http extension not available: %', sqlerrm;
end $$;

alter table public.settings add column if not exists deepl_key text;

create table if not exists public.translate_uses (
  account_id uuid not null references public.accounts(id) on delete cascade,
  at timestamptz not null default now(),
  chars int not null
);
create index if not exists translate_uses_acct_at_idx on public.translate_uses (account_id, at);
alter table public.translate_uses enable row level security;
revoke all on public.translate_uses from anon, authenticated;

-- p_target: DeepL 대상 언어 코드 (ID, EN-US, JA, ...)
create or replace function public.translate_ko(p_token text, p_text text, p_target text default 'ID') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v uuid := naskah_acct(p_token);
  t text := trim(coalesce(p_text, ''));
  tgt text := upper(coalesce(p_target, 'ID'));
  k text; host text; st int; body text; out text;
  used_n int; used_c int;
begin
  if v is null then return jsonb_build_object('error', 'auth'); end if;
  if t = '' or char_length(t) > 300 then return jsonb_build_object('error', 'bad_text'); end if;
  if tgt not in ('ID', 'EN-US', 'JA', 'ZH-HANS', 'ES', 'FR', 'DE', 'IT', 'PT-BR', 'RU', 'TR', 'AR') then
    return jsonb_build_object('error', 'bad_lang');
  end if;
  select count(*), coalesce(sum(chars), 0) into used_n, used_c from translate_uses where account_id = v and at > now() - interval '1 day';
  if used_n >= 200 or used_c + char_length(t) > 3000 then return jsonb_build_object('error', 'too_many'); end if;
  select nullif(trim(deepl_key), '') into k from settings where id = 1;
  if k is null then return jsonb_build_object('error', 'not_configured'); end if;
  host := case when k like '%:fx' then 'https://api-free.deepl.com' else 'https://api.deepl.com' end;
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '2500');
  exception when others then null;
  end;
  begin
    select h.status, h.content into st, body from extensions.http((
      'POST', host || '/v2/translate',
      array[extensions.http_header('Authorization', 'DeepL-Auth-Key ' || k)],
      'application/json',
      jsonb_build_object('text', jsonb_build_array(t), 'source_lang', 'KO', 'target_lang', tgt)::text
    )::extensions.http_request) h;
  exception when others then
    return jsonb_build_object('error', 'deepl_error');
  end;
  if st = 456 then return jsonb_build_object('error', 'deepl_quota'); end if;
  if st in (401, 403) then return jsonb_build_object('error', 'bad_key'); end if;
  if st is distinct from 200 then return jsonb_build_object('error', 'deepl_error'); end if;
  begin
    out := (body::jsonb) -> 'translations' -> 0 ->> 'text';
  exception when others then
    out := null;
  end;
  if out is null or out = '' then return jsonb_build_object('error', 'deepl_error'); end if;
  insert into translate_uses (account_id, chars) values (v, char_length(t));
  delete from translate_uses where at < now() - interval '2 days';
  return jsonb_build_object('ok', true, 'text', out, 'left', greatest(0, 199 - used_n));
end $$;

revoke all on function public.translate_ko(text, text, text) from public;
grant execute on function public.translate_ko(text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

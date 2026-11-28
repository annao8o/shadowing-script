-- 한국어로 물어보기를 로그인하지 않은 사람도 쓸 수 있어요.
--  - 로그인한 사람: 지금처럼 하루 200번·3000자.
--  - 로그인하지 않은 사람: 접속 주소(IP)마다 하루 50번·1000자, 그리고 로그인하지 않은 사람 전체를 합쳐 하루 8000자까지
--    (DeepL 무료 한도 한 달 50만 자를 지키려고). IP는 그대로 저장하지 않고 해시로만 남기고, 이틀 뒤 지워요.
-- 여러 번 실행해도 안전해요.

alter table public.translate_uses alter column account_id drop not null;
alter table public.translate_uses add column if not exists guest text;
create index if not exists translate_uses_guest_at_idx on public.translate_uses (guest, at);

-- 요청한 사람의 접속 주소를 해시로 (Supabase가 넘겨주는 요청 헤더에서)
create or replace function public.naskah_client_key() returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare h json; ip text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  ip := coalesce(h ->> 'cf-connecting-ip', h ->> 'x-real-ip', trim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)));
  return encode(digest('naskah-ip:' || coalesce(nullif(ip, ''), 'unknown'), 'sha256'), 'hex');
end $$;

create or replace function public.translate_ko(p_token text, p_text text, p_target text default 'ID') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v uuid := naskah_acct(p_token);
  g text := case when v is null then naskah_client_key() end;
  t text := trim(coalesce(p_text, ''));
  tgt text := upper(coalesce(p_target, 'ID'));
  k text; host text; st int; body text; out text;
  used_n int; used_c int; guests_c int;
begin
  if p_token is not null and p_token <> '' and v is null then return jsonb_build_object('error', 'auth'); end if;
  if t = '' or char_length(t) > 300 then return jsonb_build_object('error', 'bad_text'); end if;
  if tgt not in ('ID', 'EN-US', 'JA', 'ZH-HANS', 'ES', 'FR', 'DE', 'IT', 'PT-BR', 'RU', 'TR', 'AR') then
    return jsonb_build_object('error', 'bad_lang');
  end if;
  if v is not null then
    select count(*), coalesce(sum(chars), 0) into used_n, used_c from translate_uses where account_id = v and at > now() - interval '1 day';
    if used_n >= 200 or used_c + char_length(t) > 3000 then return jsonb_build_object('error', 'too_many'); end if;
  else
    select count(*), coalesce(sum(chars), 0) into used_n, used_c from translate_uses where guest = g and at > now() - interval '1 day';
    if used_n >= 50 or used_c + char_length(t) > 1000 then return jsonb_build_object('error', 'too_many'); end if;
    select coalesce(sum(chars), 0) into guests_c from translate_uses where account_id is null and at > now() - interval '1 day';
    if guests_c + char_length(t) > 8000 then return jsonb_build_object('error', 'busy'); end if;
  end if;
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
  insert into translate_uses (account_id, guest, chars) values (v, g, char_length(t));
  delete from translate_uses where at < now() - interval '2 days';
  return jsonb_build_object('ok', true, 'text', out);
end $$;

revoke all on function public.naskah_client_key() from public, anon, authenticated;
revoke all on function public.translate_ko(text, text, text) from public;
grant execute on function public.translate_ko(text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

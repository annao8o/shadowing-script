-- 세트 설정: 만든 뒤에도 대본, 나누기 기준, 음성(녹음 추가·교체 또는 기계 음성으로 바꾸기)을 고칠 수 있게 해요.
-- update_set 이 바꿀 수 있는 항목을 늘려요. 보내지 않은 항목은 그대로 둬요. 여러 번 실행해도 안전해요.
create or replace function public.update_set(p_id uuid, p_token text, p jsonb, p_admin text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not naskah_can(p_id, p_token, p_admin) then raise exception 'forbidden'; end if;
  if pg_column_size(p) > 600000 then raise exception 'too_big'; end if;
  if p ? 'script' and (length(coalesce(p->>'script', '')) = 0 or length(p->>'script') > 60000) then raise exception 'bad_script'; end if;
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
    segs = case when p ? 'segs' and jsonb_typeof(p->'segs') = 'array' then p->'segs' else segs end,
    spk = case when p ? 'spk' and jsonb_typeof(p->'spk') = 'array' then p->'spk' else spk end,
    pr = case when p ? 'pr' and jsonb_typeof(p->'pr') = 'array' then p->'pr' else pr end,
    deleted_at = case when p ? 'deleted' then (case when p->>'deleted' = 'true' then now() else null end) else deleted_at end,
    updated_at = case when p ? 'deleted' then updated_at else now() end
  where id = p_id;
end $$;

revoke all on function public.update_set(uuid, text, jsonb, text) from public;
grant execute on function public.update_set(uuid, text, jsonb, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- Shadowing Script — 관리자 키 정하기
-- ⚠️ 이 파일에 실제 키를 적어서 GitHub에 올리지 마세요. 저장소는 누구나 볼 수 있어요.
--    아래 내용을 복사해 Supabase SQL Editor에 붙여 넣고, 거기서 키를 바꾼 다음 Run 하세요.
-- 데이터베이스 설정(supabase/migrations)이 먼저 끝나 있어야 해요.
-- 나중에 키를 바꾸고 싶을 때도 이것만 다시 실행하면 돼요. 데이터는 지워지지 않아요.
-- 회원가입에는 참여 코드가 필요 없어요. 공간은 관리자 모드에서 사이트의 공간 관리로 만들어요.
-- ============================================================

-- ★ 여기를 바꾸세요 ★
--    관리자 키: 공간을 만들고, 모든 세트를 고치고 지우고, 비밀번호를 잊은 사람의 비밀번호를 새로 정해 줄 수 있는 키.
--    본인만 알고 있어야 해요.
insert into public.settings (id, admin_hash, join_code)
values (1, public.naskah_hash('여기에-관리자-키를-적으세요'), null)
on conflict (id) do update set admin_hash = excluded.admin_hash, join_code = null;

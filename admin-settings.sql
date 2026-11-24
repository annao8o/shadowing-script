-- ============================================================
-- Shadowing Script — 관리자 키와 참여 코드 정하기
-- ⚠️ 이 파일에 실제 키를 적어서 GitHub에 올리지 마세요. 저장소는 누구나 볼 수 있어요.
--    아래 내용을 복사해 Supabase SQL Editor에 붙여 넣고, 거기서 두 곳을 바꾼 다음 Run 하세요.
-- 데이터베이스 설정(supabase/migrations)이 먼저 끝나 있어야 해요.
-- 나중에 키나 코드를 바꾸고 싶을 때도 이것만 다시 실행하면 돼요. 데이터는 지워지지 않아요.
-- ============================================================

-- ★ 여기 두 곳을 바꾸세요 ★
--    관리자 키: 모든 세트를 고치고 지우고, 비밀번호를 잊은 사람의 비밀번호를 새로 정해 줄 수 있는 키. 본인만 알고 있어야 해요.
--    참여 코드: 회원가입할 때 필요한 코드. 아무나 가입해도 되면 따옴표까지 지우고 null 로 두세요.
insert into public.settings (id, admin_hash, join_code)
values (1, public.naskah_hash('여기에-관리자-키를-적으세요'), '여기에-참여코드')
on conflict (id) do update set admin_hash = excluded.admin_hash, join_code = excluded.join_code;

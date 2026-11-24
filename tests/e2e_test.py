"""End-to-end UI test for index.html against an in-browser mock of Supabase.

Runs without network or a real Supabase project:
  pip install playwright && python -m playwright install chromium
  python tests/e2e_test.py

The mock (tests/mock-supabase.js) replaces the supabase-js CDN script and keeps
its "server" state in localStorage, so several browser contexts can act as
different users by copying that state between pages (see `sync`).
"""
import asyncio
import json
import pathlib
import re
import sys

from playwright.async_api import async_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOCK = (ROOT / "tests" / "mock-supabase.js").read_text(encoding="utf-8")
WAV = str(ROOT / "tests" / "fixtures" / "sample.wav")
TMP = ROOT / "tests" / ".tmp"
TMP.mkdir(exist_ok=True)
page_html = (ROOT / "index.html").read_text(encoding="utf-8")
page_html = re.sub(r"url: '[^']*'", "url: 'https://test.supabase.co'", page_html, count=1)
page_html = re.sub(r"key: '[^']*'", "key: 'testkey'", page_html, count=1)
(TMP / "index_test.html").write_text(page_html, encoding="utf-8")
URL = (TMP / "index_test.html").as_uri()

failures = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        failures.append(label)


async def new_page(browser):
    ctx = await browser.new_context(viewport={"width": 390, "height": 844})
    pg = await ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    await pg.route("**/supabase.js", lambda r: r.fulfill(body=MOCK, content_type="application/javascript"))
    await pg.route("**/fonts.googleapis.com/**", lambda r: r.abort())
    return pg, errs


async def sync(src, dst):
    """Copy the mock server state from one user's page to another's."""
    if dst.url.startswith("about:"):
        await dst.goto(URL)
    state = await src.evaluate("localStorage.getItem('sbmock')")
    await dst.evaluate(f"localStorage.setItem('sbmock', {json.dumps(state)})")


async def sign_up(pg, name, login):
    await pg.goto(URL)
    await pg.wait_for_timeout(300)
    await pg.click("#meBtn")
    await pg.click("#tabUp")
    await pg.fill("#auName", name)
    await pg.fill("#auId", login)
    await pg.fill("#auPw", "secret1")
    await pg.fill("#auPw2", "secret1")
    await pg.fill("#auCode", "kode123")  # join code expected by the mock
    await pg.click("#auGo")
    await pg.wait_for_timeout(500)


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        A, ea = await new_page(browser)
        B, eb = await new_page(browser)
        G, eg = await new_page(browser)

        print("guest browsing")
        await A.goto(URL)
        await A.evaluate("localStorage.clear()")
        await A.reload()
        await A.wait_for_timeout(400)
        check(await A.is_visible("#lib") and not await A.is_visible("#auth"), "list is shown without login")
        await A.click("#addBtn")
        check(await A.is_visible("#auth"), "adding a set asks for login")

        print("sign up and create sets")
        await A.click("#tabUp")
        await A.fill("#auName", "조안나")
        await A.fill("#auId", "joanna")
        await A.fill("#auPw", "secret1")
        await A.fill("#auPw2", "secret1")
        await A.fill("#auCode", "kode123")
        await A.click("#auGo")
        await A.wait_for_timeout(500)
        check(await A.is_visible("#setup"), "after sign-up the add form opens")
        await A.fill("#title", "공개 세트")
        await A.fill("#script", "MC: Selamat pagi. | | 좋은 아침\nB: Terima kasih.")
        await A.set_input_files("#audIn", WAV)
        await A.click("#go")
        await A.wait_for_timeout(1500)
        check(await A.is_visible("#cv"), "recording set shows waveform")
        check((await A.inner_text(".ln:nth-child(1) .pr")).startswith("슬라맛"), "auto Hangul pronunciation for Indonesian")
        await A.click("#backBtn")
        await A.click("#addBtn")
        await A.select_option("#lang", "ja")
        await A.fill("#title", "일본어 일부 공개")
        await A.fill("#script", "A: おはようございます。")
        await A.click("#fVis input[value=private]")
        await A.click("#ttsGo")
        await A.wait_for_timeout(400)
        check("일본어" in await A.inner_text("#sumS"), "language shown on set")
        await A.click("#backBtn")

        print("second user and partial sharing")
        await sync(A, B)
        await sign_up(B, "Budi", "budi")
        await sync(B, A)
        await A.reload()
        await A.wait_for_timeout(500)
        if await A.is_visible("#practice"):
            await A.click("#backBtn")
        await A.click('.set:has-text("일본어")')
        await A.wait_for_timeout(300)
        await A.click("#shareBtn")
        await A.wait_for_timeout(300)
        await A.click("#sVis input[value=partial]")
        await A.fill("#sVis input.inp", "@bu")
        await A.wait_for_timeout(500)
        await A.click("#sVis .sugg button[data-u]")
        await A.click("#shareSave")
        await A.wait_for_timeout(500)
        check("1명" in await A.inner_text("#shareInfo"), "owner shared with one person")
        await sync(A, B)
        await B.reload()
        await B.wait_for_timeout(600)
        check("공유했어요" in await B.inner_text("#inbox"), "recipient sees invite")
        await B.click("#inbox .inv button.ok")
        await B.wait_for_timeout(400)
        check("공유받음" in await B.inner_text("#sets"), "accepted set appears in recipient list")
        await B.click('.set:has-text("일본어")')
        await B.wait_for_timeout(300)
        check(not await B.is_visible("#edit") and await B.is_visible("#leaveBox"), "recipient cannot edit, can leave")

        print("guest sees only public")
        await sync(B, G)
        await G.reload()
        await G.wait_for_timeout(500)
        sets = await G.inner_text("#sets")
        check("공개 세트" in sets and "일본어" not in sets, "guest list has public sets only")

        for name, errs in (("A", ea), ("B", eb), ("G", eg)):
            check(not errs, f"no page errors for {name}: {errs}")
        await browser.close()

    print("\nFAILED: " + ", ".join(failures) if failures else "\nall checks passed")
    sys.exit(1 if failures else 0)


asyncio.run(main())

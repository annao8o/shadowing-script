# Shadowing Script (쉐도잉 스크립트)

Foreign-language script practice site: a user uploads a script plus one full recording, the page
auto-splits the audio into one clip per line, and people tap lines to listen, repeat and shadow.
UI copy is Korean; the practised language is per set (Indonesian first, others supported).

Hosted as a static page (GitHub Pages). Data lives in Supabase (Postgres + Storage).
There is no build step and no backend code besides the SQL in `supabase/migrations/`.
The repo is connected to Supabase's GitHub integration ("Deploy to production" on `main`): every push to
`main` applies any migration file Supabase hasn't run yet. GitHub Pages serves `index.html` from `main`.
**The repo is public** — never commit the admin key, join code, DB password or any secret key.

## Files

- `index.html` — the whole app: markup, CSS and one script. Edit it directly.
- `supabase/migrations/<YYYYMMDDHHMMSS>_name.sql` — Supabase schema, RPC functions, grants, storage bucket.
  `..._init.sql` is the former `setup.sql`. Supabase runs each file **once**, in name order, so:
  - **Never edit a migration that is already on `main`.** Put every DB change in a new file with a later
    timestamp (e.g. `create or replace function ...` for a changed RPC, `alter table ... add column if not exists`).
  - Keep every migration **idempotent and upgrade-safe** too (projects set up by hand may re-run them).
  - No `create index concurrently` or anything else that can't run inside one transaction.
  - No `supabase/config.toml`: without it the integration only applies migrations and leaves project settings alone.
- `admin-settings.sql` — sets the admin key hash and join code; the owner runs it by hand in SQL Editor and
  never commits real values. Until it runs, the init migration's random placeholder locks sign-up and admin.
- `deepl-settings.sql` — puts the DeepL API key into `settings.deepl_key`; like `admin-settings.sql`, the owner runs it
  by hand and never commits a real key.
- `README.md` — setup guide for the (non-developer) site owner, in Korean.
- `sw.js`, `manifest.webmanifest`, `icon-*.png`, `apple-touch-icon.png` — home-screen app + offline. The service worker
  only keeps the page shell, supabase-js and fonts (`naskah-shell-vN`; bump N when `CORE` changes). It never caches
  scripts or recordings: the page saves only what the user picks ("오프라인 저장", see below).
- `tests/e2e_test.py` — Playwright UI test against `tests/mock-supabase.js` (no network needed).
- `tests/db_test.mjs` — runs all migrations (twice) and `admin-settings.sql` in PGlite (in-process Postgres)
  and checks permissions.
- `tests/mock-supabase.js` — in-browser fake of the supabase-js client and every RPC. Keep it in step
  with the migrations when RPCs change.

## Tests

```
npm install                      # PGlite for the DB test
pip install playwright && python -m playwright install chromium
npm test                         # db test, then UI test
```

Run both after any change. Add a check to the matching test for new behaviour.

## Script layout inside index.html

The `<script>` block at the end has these parts, in order (search for the `/* ---------- name` markers):

1. Supabase config `window.NASKAH_CONFIG` (separate small script near the top of `<body>`'s end).
   Placeholders `YOUR-...` mean "not configured" → the app falls back to a browser-only local mode (IndexedDB).
2. `parseScript` / `analyze` / `findGaps` / `segment` — script parsing and audio auto-segmentation
   (silence detection + dynamic programming that matches line lengths to speech segments).
3. `pronounce` — rule-based Indonesian/Malay → Hangul pronunciation, with an exceptions table `PRON_EX`.
4. UI: state objects `S` (current set / playback) and `B` (backend, session, library),
   language table `LANGS`, backend functions (`load`, `addSet`, `patchSet`, `purgeSet`, `getAudio`),
   library, practice view, speakers, playback (audio element or speechSynthesis), waveform canvas (no longer
   shown: `#wave` is now just a one-line loading/error status, the peaks still feed `playEnd`),
   trash, backup/import, sharing (`Picker`, share panel, inbox), account (login/sign-up, my info), start.

## Data model and security (supabase/migrations)

- Tables: `settings` (admin key hash, join code), `accounts` (bcrypt via pgcrypto), `sessions`
  (sha256 of random token), `sets`, `shares` (partial-visibility invites: pending/accepted/declined).
- Spaces (`spaces`, `space_members`; `sets.space_id`, `folders.space_id`): every set and folder lives in one space.
  **Spaces are open (no join codes).** `list_spaces` lists every space to everyone; a signed-in person becomes a member
  by picking one (`join_space(p_token, p_space)`; the client calls it whenever the current space isn't theirs yet).
  Everyone, signed in or not, sees public sets/folders of every space (`naskah_public_set`); members additionally see what
  `naskah_visible`/`naskah_folder_visible` allow and can add sets there. Only the admin key creates or renames spaces
  (`save_space`). The old `join_code` column, `space_code_fails` and the `p_codes` params remain but are unused. Partial sharing and `find_users` stay within members.
- Folders (`folders`, `folder_shares`; `sets.folder_id`): one level, owned by one account. **A set inside a
  folder follows the folder's visibility, not its own** (`naskah_folder_visible`); a set's own `visibility`/`shares`
  only apply when `folder_id` is null. Only the set owner's folders can hold a set (`update_set` checks).
  Deleting a folder moves its sets out and copies the folder's visibility and shares onto them.
  Folders exist only in server mode; the browser-only local mode has none.
- **All tables have RLS on and no grants to anon/authenticated.** Every read and write goes through
  `security definer` RPC functions; each public RPC gets an explicit `grant execute ... to anon, authenticated`
  (section 7 of the init migration). A new RPC needs its own `revoke all ... from public` +
  `grant execute ... to anon, authenticated` in the migration that adds it, or the site cannot call it (the project has
  "auto-expose new tables/functions" off).
- Custom auth (not Supabase Auth): `sign_up`, `sign_in`, `sign_out`, `me`, `set_name`, `change_password`,
  `admin_reset_password`. The client keeps the session token in localStorage (`naskah.session`).
- Visibility: `public` (every member of the space), `partial` (owner + accepted shares),
  `private` (owner), all within the set's space. `naskah_visible()` is the member rule; `list_sets` also returns every public set to anyone.
- Admin = whoever knows the admin key (stored as a hash in `settings`); it is passed as `p_admin`.
  `share_set`/`get_shares` take `p_admin` too, so an admin can change any unfiled set's visibility (shares still skip the owner
  and non-members of the space).
- Audio files: public Storage bucket `audio`, random UUID names. Uploads are open to the anon key
  (known gap: not tied to login).

## Conventions

- Escape every value from the server, a file or a user with `esc()` before it goes into HTML.
- The app script is wrapped in a block `{ … }`, so `S`, `B` and friends are **not** on `window`; UI tests must check the
  page (DOM), not `page.evaluate("S…")`.
- Clip playback stops via `armStop()` (a timer that re-arms closer to the end), not animation frames, which browsers
  throttle in the background; keep it that way or clips run into the next line.
- At play time `playEnd(i)` trims a clip to its voice: if the saved end sits on sound right before the next line it
  is pulled back to the quietest point, and trailing silence is cut to 0.12s. A segment whose end was set by hand in
  구간 수정 carries `m:1` and is played exactly. Editing never lets lines overlap: moving an end past the next line's
  start pushes that start along (and a start moved before the previous end pulls that end back).
  `playRange` (구간 수정 previews) plays the saved values exactly.
- Pause (`pausePlay`) keeps `S.paused` (line, rep count, audio position or the pending follow-along step); the play
  button resumes from there (`resume`). Tapping a line, prev/next or opening a set starts fresh.
- Keep user-facing text in plain, friendly Korean (해요체), matching the existing copy.
- Mobile first: 44px touch targets, layout checked at 390px wide.
- Don't put the Supabase `service_role`/secret key anywhere in this repo; only the anon/publishable key.
- Script lines starting with `#` are notes (`##` = bold section title, `#` = grey memo): `parseScript` keeps them out of
  the items (so `segs`/`spk`/`pr` indexes don't move) and returns them as `items.notes` (`{at, t, h}` = shown before
  line `at`; `h` = title). Editing only notes keeps `segs`.
- Two top tabs: 대본 (library and everything else) and 회화 (`#talk`, the 한국어로 물어보기 box). `show(view, true)` for
  any main view closes 회화; `openTalk()` opens it (route `#talk`). `setMainTab` marks the tab (the login form has its
  own `setTab`).
- Offline saves (`/* ---------- offline saves` in index.html): IndexedDB `naskah-off` holds `idx` (`OFF.sets[id]={row,own,via,size}`,
  `OFF.folders`, `OFF.spaces`) and `aud:<id>` recording blobs. Nothing is saved automatically on play. `offSync()` runs after
  every successful `load()` (refreshes rows/audio, adds sets newly put in a saved folder). When `load()` fails and something
  is saved, `enterOffline()` swaps `B.rawSets/rawFolders/spaces` for the saved copies and sets `B.offline` (read-only:
  `canModify` is false, `body.offline` hides network-only buttons). `getAudio` prefers the saved blob.
  The mock goes "offline" when localStorage `sbmock.down` is set.
- List order is per person (no sort menu): `list_orders` (`get_orders`/`save_order`) holds, per account and list
  (`top:<space id>` or `folder:<folder id>`), the keys `f:<id>`/`s:<id>` in order. The page mirrors it in localStorage
  (`naskah.orders.u.<account>`; signed-out people only have `naskah.orders`). `ordered()` puts items missing from the
  saved order (new ones) on top; with no saved order it is folders first, then latest edited. 순서 바꾸기 mode
  (`B.reorder`) drags by the ≡ handle with pointer events or moves with ↑↓; `renderLib` skips while a drag is on.
- Admin pins: `list_pins` (anyone reads) / `save_pins` (admin key, signed in) keep per list the keys shown on top for
  everyone, in the admin's order. `arrange()` = pinned first, then `ordered()`. In 순서 바꾸기 the two groups
  (`data-g="p"`/`"o"`) move separately; only an admin sees the pin buttons and can move pinned rows.
- 한국어로 물어보기: `translate_ko(p_token, p_text, p_target)` (not `translate`, which is a built-in Postgres function) calls
  DeepL from Postgres through Supabase's `http` extension with `settings.deepl_key` (free keys ending `:fx` go to
  api-free.deepl.com). 300 chars per call; signed in: 200 calls / 3000 chars a day per account; signed out: 50 calls /
  1000 chars a day per hashed client IP (`naskah_client_key()` from the request headers) and 8000 chars a day for all
  guests together (`translate_uses`). A mic button fills the box with browser speech recognition (ko-KR) and translates.
  The page adds Hangul pronunciation (`pronounce`, Indonesian/Malay only) and reads it aloud with speechSynthesis;
  the last 10 answers stay in `naskah.askHist`. The DB test stubs the `http` extension with a fake DeepL.
- Backups use `app: 'latihan-naskah'` in the JSON — keep that id so older backups still import.

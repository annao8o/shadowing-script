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
- `README.md` — setup guide for the (non-developer) site owner, in Korean.
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
   library, practice view, speakers, playback (audio element or speechSynthesis), waveform canvas,
   trash, backup/import, sharing (`Picker`, share panel, inbox), account (login/sign-up, my info), start.

## Data model and security (supabase/migrations)

- Tables: `settings` (admin key hash, join code), `accounts` (bcrypt via pgcrypto), `sessions`
  (sha256 of random token), `sets`, `shares` (partial-visibility invites: pending/accepted/declined).
- Spaces (`spaces`, `space_members`; `sets.space_id`, `folders.space_id`): every set and folder lives in one space.
  **Everyone enters a space with its join code.** Signed-in people become members (`join_space`) and see what
  `naskah_visible`/`naskah_folder_visible` allow; signed-out people keep the codes on the device (`naskah.codes`) and
  pass them as `p_codes` to `list_sets`/`list_folders`/`list_spaces`, which then add that space's public sets/folders
  (read-only). `check_code` validates a code for guests. Wrong codes are throttled per account and site-wide
  (`space_code_fails`). Only the admin key creates or edits spaces (`save_space`, new codes 6+ chars). Sign-up needs
  no code. On login the client joins every remembered code. Partial sharing and `find_users` stay within members.
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
  `private` (owner), all within the set's space. `naskah_visible()` is the member rule; `list_sets` also returns public sets of spaces whose codes are passed in `p_codes`.
- Admin = whoever knows the admin key (stored as a hash in `settings`); it is passed as `p_admin`.
- Audio files: public Storage bucket `audio`, random UUID names. Uploads are open to the anon key
  (known gap: not tied to login).

## Conventions

- Escape every value from the server, a file or a user with `esc()` before it goes into HTML.
- Keep user-facing text in plain, friendly Korean (해요체), matching the existing copy.
- Mobile first: 44px touch targets, layout checked at 390px wide.
- Don't put the Supabase `service_role`/secret key anywhere in this repo; only the anon/publishable key.
- Backups use `app: 'latihan-naskah'` in the JSON — keep that id so older backups still import.

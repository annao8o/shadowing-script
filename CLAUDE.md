# Shadowing Script (쉐도잉 스크립트)

Foreign-language script practice site: a user uploads a script plus one full recording, the page
auto-splits the audio into one clip per line, and people tap lines to listen, repeat and shadow.
UI copy is Korean; the practised language is per set (Indonesian first, others supported).

Hosted as a static page (GitHub Pages). Data lives in Supabase (Postgres + Storage).
There is no build step and no backend code besides `setup.sql`.

## Files

- `index.html` — the whole app: markup, CSS and one script. Edit it directly.
- `setup.sql` — Supabase schema, RPC functions, grants, storage bucket. Run in Supabase SQL Editor.
  Must stay **idempotent and upgrade-safe** (re-running it on an existing project keeps data).
- `README.md` — setup guide for the (non-developer) site owner, in Korean.
- `tests/e2e_test.py` — Playwright UI test against `tests/mock-supabase.js` (no network needed).
- `tests/db_test.mjs` — runs `setup.sql` in PGlite (in-process Postgres) and checks permissions.
- `tests/mock-supabase.js` — in-browser fake of the supabase-js client and every RPC. Keep it in step
  with `setup.sql` when RPCs change.

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

## Data model and security (setup.sql)

- Tables: `settings` (admin key hash, join code), `accounts` (bcrypt via pgcrypto), `sessions`
  (sha256 of random token), `sets`, `shares` (partial-visibility invites: pending/accepted/declined).
- **All tables have RLS on and no grants to anon/authenticated.** Every read and write goes through
  `security definer` RPC functions; each public RPC gets an explicit `grant execute ... to anon, authenticated`
  in section 7. A new RPC must be added to that list, or the site cannot call it (the project has
  "auto-expose new tables/functions" off).
- Custom auth (not Supabase Auth): `sign_up`, `sign_in`, `sign_out`, `me`, `set_name`, `change_password`,
  `admin_reset_password`. The client keeps the session token in localStorage (`naskah.session`).
- Visibility: `public` (everyone, including signed-out visitors), `partial` (owner + accepted shares),
  `private` (owner). `naskah_visible()` is the single rule; `list_sets(null)` returns public sets only.
- Admin = whoever knows the admin key (stored as a hash in `settings`); it is passed as `p_admin`.
- Audio files: public Storage bucket `audio`, random UUID names. Uploads are open to the anon key
  (known gap: not tied to login).

## Conventions

- Escape every value from the server, a file or a user with `esc()` before it goes into HTML.
- Keep user-facing text in plain, friendly Korean (해요체), matching the existing copy.
- Mobile first: 44px touch targets, layout checked at 390px wide.
- Don't put the Supabase `service_role`/secret key anywhere in this repo; only the anon/publishable key.
- Backups use `app: 'latihan-naskah'` in the JSON — keep that id so older backups still import.

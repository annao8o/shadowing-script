// Database test for supabase/migrations + admin-settings.sql, run against an in-process Postgres (PGlite).
//   npm install && npm run test:db
// Stubs the Supabase pieces the SQL touches (roles, storage schema, extensions schema),
// runs every migration in order twice (each must stay idempotent), checks that sign-up and admin
// stay locked until admin-settings.sql runs, then exercises the RPCs as the anon role.
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const db = new PGlite({ extensions: { pgcrypto } });
const failures = [];
const check = (cond, label) => { console.log((cond ? '  ok   ' : '  FAIL ') + label); if (!cond) failures.push(label); };
const q = async (s, p) => { try { return (await db.query(s, p)).rows; } catch (e) { return 'ERR ' + e.message; } };
const one = async (s, p) => { const r = await q(s, p); return typeof r === 'string' ? r : Object.values(r[0] || {})[0]; };

await db.exec(`create schema extensions; create role anon nologin; create role authenticated nologin;
create schema storage;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id serial, bucket_id text, name text); alter table storage.objects enable row level security;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;`);
const migDir = path.join(root, 'supabase', 'migrations');
const migrations = fs.readdirSync(migDir).filter((f) => /^\d{14}_.+\.sql$/.test(f)).sort();
check(migrations.length === fs.readdirSync(migDir).length, 'every migration file is named <14-digit timestamp>_name.sql');
for (let i = 0; i < 2; i++) for (const f of migrations) await db.exec(fs.readFileSync(path.join(migDir, f), 'utf8'));
console.log(`${migrations.length} migration(s) ran twice`);

const CODE = '여기에-참여코드', ADMIN = '여기에-관리자-키를-적으세요';
console.log('locked until admin-settings.sql');
await db.exec('set role anon');
check((await one('select needs_join_code()')) === true, 'sign-up needs a join code before admin settings');
check((await one(`select sign_up('early','E','secret1',$1)`, [CODE])).error === 'join_code', 'placeholder join code rejected before admin settings');
check((await one('select is_admin($1)', [ADMIN])) === false, 'admin key unknown before admin settings');
await db.exec('reset role');
await db.exec(fs.readFileSync(path.join(root, 'admin-settings.sql'), 'utf8'));
for (const f of migrations) await db.exec(fs.readFileSync(path.join(migDir, f), 'utf8'));
await db.exec('set role anon');
check((await one('select is_admin($1)', [ADMIN])) === true, 'admin settings survive re-running migrations');
const titles = async (t) => (await one('select list_sets($1)', [t ?? null])).map((s) => s.title).sort().join(',');

console.log('accounts');
check((await one(`select sign_up('a1','A','secret1',null)`)).error === 'join_code', 'join code required');
const ja = await one(`select sign_up('Joanna','조안나','secret1',$1)`, [CODE]);
check(ja.token && ja.login === 'joanna', 'sign up lowercases id and returns session');
check((await one(`select sign_up('joanna','x','secret1',$1)`, [CODE])).error === 'id_taken', 'duplicate id rejected');
const bu = await one(`select sign_up('budi','Budi','password',$1)`, [CODE]);
check((await one(`select sign_in('joanna','nope')`)).error === 'bad_login', 'wrong password rejected');
check(typeof (await q('select * from accounts')) === 'string', 'accounts table not readable directly');

console.log('visibility');
const mk = (t, v, extra = {}) => one('select create_set($1::jsonb,$2)', [JSON.stringify({ title: t, script: 'x', visibility: v, ...extra }), ja.token]);
await mk('pub', 'public', { lang: 'en' });
await mk('priv', 'private');
const part = await mk('part', 'partial', { share: [bu.id] });
check(await titles(null) === 'pub', 'guest sees public only');
check(await titles(ja.token) === 'part,priv,pub', 'owner sees all own sets');
check(await titles(bu.token) === 'pub', 'recipient sees nothing before accepting');
check((await one('select list_inbox($1)', [bu.token])).length === 1, 'recipient has an invite');
await one('select respond_share($1,$2,true)', [bu.token, part]);
check(await titles(bu.token) === 'part,pub', 'accepted set visible to recipient');
check(String(await q(`select update_set($1,$2,'{"pr":[]}'::jsonb)`, [part, bu.token])).startsWith('ERR'), 'recipient cannot edit');
check(!String(await q(`select update_set($1,$2,'{"pr":[]}'::jsonb,$3)`, [part, bu.token, ADMIN])).startsWith('ERR'), 'admin key can edit');
check(String(await q(`select create_set('{"script":"x"}'::jsonb,null)`)).startsWith('ERR'), 'guest cannot create');

console.log('set settings');
const ed = await mk('edit me', 'private', { tts: true });
await one('select update_set($1,$2,$3::jsonb)', [ed, ja.token, JSON.stringify({ script: 'a\nb', mode: 'line', tts: false, audio_path: 'x.m4a', audio_mime: 'audio/mp4', dur: 3.5, name: 'rec.m4a', segs: [{ s: 0, e: 1 }, { s: 1, e: 2 }] })]);
let row = (await one('select list_sets($1)', [ja.token])).find((r) => r.id === ed);
check(row.script === 'a\nb' && row.mode === 'line' && row.tts === false && row.audio_path === 'x.m4a' && row.dur === 3.5 && row.segs.length === 2, 'owner can add a recording and change the script');
await one('select update_set($1,$2,$3::jsonb)', [ed, ja.token, JSON.stringify({ tts: true, audio_path: null, audio_mime: null, dur: null, segs: [] })]);
row = (await one('select list_sets($1)', [ja.token])).find((r) => r.id === ed);
check(row.tts === true && row.audio_path === null && row.dur === null && row.script === 'a\nb', 'owner can switch back to machine voice; untouched fields stay');
check(String(await q(`select update_set($1,$2,'{"script":""}'::jsonb)`, [ed, ja.token])).startsWith('ERR'), 'empty script rejected');
check(String(await q(`select update_set($1,$2,'{"title":"x"}'::jsonb)`, [ed, bu.token])).startsWith('ERR'), 'other user cannot change settings');
check(!JSON.stringify(await one('select list_sets(null)')).includes('owner_hash'), 'owner_hash never returned');

console.log(failures.length ? `\nFAILED: ${failures.join(', ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);

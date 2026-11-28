// Database test for supabase/migrations + admin-settings.sql, run against an in-process Postgres (PGlite).
//   npm install && npm run test:db
// Stubs the Supabase pieces the SQL touches (roles, storage schema, extensions schema),
// runs every migration in order twice (each must stay idempotent), checks that admin mode stays
// locked until admin-settings.sql runs, then exercises the RPCs as the anon role.
// A second database checks the one-time move of existing data into the first space.
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];
const check = (cond, label) => { console.log((cond ? '  ok   ' : '  FAIL ') + label); if (!cond) failures.push(label); };
const STUB = `create schema extensions; create role anon nologin; create role authenticated nologin;
create schema storage;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id serial, bucket_id text, name text); alter table storage.objects enable row level security;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;`;
const migDir = path.join(root, 'supabase', 'migrations');
const migrations = fs.readdirSync(migDir).filter((f) => /^\d{14}_.+\.sql$/.test(f)).sort();
const sqlOf = (f) => fs.readFileSync(path.join(migDir, f), 'utf8');
const helpers = (db) => {
  const q = async (s, p) => { try { return (await db.query(s, p)).rows; } catch (e) { return 'ERR ' + e.message; } };
  const one = async (s, p) => { const r = await q(s, p); return typeof r === 'string' ? r : Object.values(r[0] || {})[0]; };
  return { q, one };
};

const db = new PGlite({ extensions: { pgcrypto } });
const { q, one } = helpers(db);
await db.exec(STUB);
check(migrations.length === fs.readdirSync(migDir).length, 'every migration file is named <14-digit timestamp>_name.sql');
for (let i = 0; i < 2; i++) for (const f of migrations) await db.exec(sqlOf(f));
console.log(`${migrations.length} migration(s) ran twice`);

const ADMIN = '여기에-관리자-키를-적으세요';
console.log('admin locked until admin-settings.sql');
await db.exec('set role anon');
check((await one('select needs_join_code()')) === false, 'sign-up needs no join code');
check((await one('select is_admin($1)', [ADMIN])) === false, 'admin key unknown before admin settings');
await db.exec('reset role');
await db.exec(fs.readFileSync(path.join(root, 'admin-settings.sql'), 'utf8'));
for (const f of migrations) await db.exec(sqlOf(f));
await db.exec('set role anon');
check((await one('select is_admin($1)', [ADMIN])) === true, 'admin settings survive re-running migrations');
check((await one('select needs_join_code()')) === false, 'admin settings keep sign-up open');
const titles = async (t) => (await one('select list_sets($1)', [t ?? null])).map((s) => s.title).sort().join(',');

console.log('accounts');
const ja = await one(`select sign_up('Joanna','조안나','secret1',null)`);
check(ja.token && ja.login === 'joanna', 'sign up without a code lowercases id and returns session');
check((await one(`select sign_up('joanna','x','secret1',null)`)).error === 'id_taken', 'duplicate id rejected');
const bu = await one(`select sign_up('budi','Budi','password',null)`);
const cy = await one(`select sign_up('cyril','Cyril','password',null)`);
check((await one(`select sign_in('joanna','nope')`)).error === 'bad_login', 'wrong password rejected');
check(typeof (await q('select * from accounts')) === 'string', 'accounts table not readable directly');

console.log('spaces');
check((await one('select save_space($1,$2,null,$3)', [bu.token, 'wrong', 'x'])).error === 'forbidden', 'only admin can create a space');
const S1 = (await one('select save_space($1,$2,null,$3)', [ja.token, ADMIN, '인도네시아어반'])).id;
check(!!S1, 'admin creates a space');
check((await one('select save_space($1,$2,null,$3)', [ja.token, ADMIN, '  '])).error === 'bad_name', 'a space needs a name');
const S2 = (await one('select save_space($1,$2,null,$3)', [ja.token, ADMIN, '다른 반'])).id;
check((await one('select join_space($1,$2)', [bu.token, '00000000-0000-4000-8000-000000000000'])).error === 'not_found', 'joining a missing space fails');
const jb = await one('select join_space($1,$2)', [bu.token, S1]);
check(jb.ok && jb.id === S1 && jb.name === '인도네시아어반', 'anyone signed in joins a space by picking it, no code');
check((await one('select join_space($1,$2)', [bu.token, S1])).ok, 'joining twice is fine');
check((await one('select join_space($1,$2)', [null, S1])).error === 'auth', 'guest cannot join');
const bs = await one('select list_spaces($1)', [bu.token]);
check(bs.length === 2 && bs.find((s) => s.id === S1).member && !bs.find((s) => s.id === S2).member && bs.find((s) => s.id === S1).members === 2, 'everyone sees every space, with whether they are a member');
check(bs.every((s) => !('join_code' in s)), 'no join codes are sent');
check((await one('select list_spaces($1)', [null])).length === 2, 'guests see every space too');
await one('select save_space($1,$2,$3,$4)', [ja.token, ADMIN, S2, '다른 반 B']);
check((await one('select list_spaces($1)', [ja.token])).some((s) => s.name === '다른 반 B'), 'admin renames a space');
check(typeof (await q("select check_code('x')")) === 'string' && typeof (await q("select join_space('x','kode')")) === 'string', 'the old join-code functions are gone');
check(typeof (await q('select * from spaces')) === 'string', 'spaces table not readable directly');

console.log('visibility inside a space');
const mk = (t, v, extra = {}, tok = ja.token, sp = S1) => one('select create_set($1::jsonb,$2)', [JSON.stringify({ title: t, script: 'x', visibility: v, space_id: sp, ...extra }), tok]);
check(String(await q('select create_set($1::jsonb,$2)', [JSON.stringify({ title: 'no space', script: 'x' }), ja.token])).includes('no_space'), 'a set needs a space');
check(String(await mk('not member', 'public', {}, bu.token, S2)).includes('no_space'), 'cannot add a set to a space you are not in');
await mk('pub', 'public', { lang: 'en' });
await mk('priv', 'private');
const part = await mk('part', 'partial', { share: [bu.id, cy.id] });
check(await titles(null) === 'pub', 'guests see public sets only');
check(await titles(cy.token) === 'pub', 'non-members see public sets only');
check(await titles(ja.token) === 'part,priv,pub', 'owner sees all own sets');
check(await titles(bu.token) === 'pub', 'member sees public sets of the space');
const inv = await one('select list_inbox($1)', [bu.token]);
check(inv.length === 1 && inv[0].space_name === '인도네시아어반', 'member has an invite with the space name');
check((await one('select list_inbox($1)', [cy.token])).length === 0, 'sharing with a non-member is ignored');
await one('select respond_share($1,$2,true)', [bu.token, part]);
check(await titles(bu.token) === 'part,pub', 'accepted set visible to recipient');
check(String(await q(`select update_set($1,$2,'{"pr":[]}'::jsonb)`, [part, bu.token])).startsWith('ERR'), 'recipient cannot edit');
check(!String(await q(`select update_set($1,$2,'{"pr":[]}'::jsonb,$3)`, [part, bu.token, ADMIN])).startsWith('ERR'), 'admin key can edit');
check(String(await q(`select create_set('{"script":"x"}'::jsonb,null)`)).startsWith('ERR'), 'guest cannot create');
const found = async (t, query, sp) => (await one('select find_users($1,$2,$3)', [t, query, sp])).map((u) => u.login).join();
check(await found(ja.token, 'bu', S1) === 'budi' && await found(ja.token, 'cy', S1) === '', 'finding people to share with: members of the space only');
check(await found(ja.token, 'bu', null) === '' && await found(cy.token, 'jo', S1) === '', 'no search without being a member of that space');
check((await one('select list_sets($1)', [ja.token])).every((r) => r.space_id === S1), 'sets carry their space_id');

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
check(!JSON.stringify(await one('select list_sets($1)', [ja.token])).includes('owner_hash'), 'owner_hash never returned');
const vis = async (id) => (await one('select list_sets($1)', [ja.token])).find((r) => r.id === id).visibility;
check((await one('select share_set($1,$2,$3)', [bu.token, ed, 'public'])).error === 'forbidden' && await vis(ed) === 'private', 'other user cannot change visibility');
check((await one('select share_set($1,$2,$3,null,$4)', [bu.token, ed, 'public', 'wrong'])).error === 'forbidden', 'wrong admin key cannot change visibility');
check((await one('select share_set($1,$2,$3,null,$4)', [null, ed, 'public', ADMIN])).error === 'auth', 'admin key alone (signed out) cannot change visibility');
check((await one('select share_set($1,$2,$3,null,$4)', [bu.token, ed, 'public', ADMIN])).ok && await vis(ed) === 'public', 'admin changes visibility of someone else\'s set');
await one('select share_set($1,$2,$3,$4,$5)', [bu.token, ed, 'partial', [ja.id, bu.id, cy.id], ADMIN]);
const esh = await one('select get_shares($1,$2,$3)', [bu.token, ed, ADMIN]);
check(esh.map((u) => u.login).join() === 'budi', 'admin partial share skips the owner and non-members');
check((await one('select get_shares($1,$2)', [bu.token, ed])).length === 0, 'shares list hidden from others without the admin key');
check((await one('select share_set($1,$2,$3)', [ja.token, ed, 'private'])).ok && await vis(ed) === 'private', 'owner still changes visibility');

console.log('folders');
const ids = async (t) => (await one('select list_sets($1)', [t ?? null])).map((r) => r.title);
const fnames = async (t) => (await one('select list_folders($1)', [t ?? null])).map((f) => f.title).sort().join(',');
const newFolder = (tok, title, vis, sp = S1) => one('select save_folder($1,null,$2,$3,null,$4)', [tok, title, vis, sp]);
const fo = (await newFolder(ja.token, '여행 회화', 'private')).id;
check(!!fo, 'owner can create a folder');
check((await newFolder(null, 'x', 'public')).error === 'auth', 'guest cannot create a folder');
check((await newFolder(ja.token, '  ', 'public')).error === 'bad_title', 'empty folder name rejected');
check((await newFolder(cy.token, 'x', 'public')).error === 'no_space', 'cannot create a folder in a space you are not in');
const inF = await mk('in folder', 'public');
await one('select update_set($1,$2,$3::jsonb)', [inF, ja.token, JSON.stringify({ folder_id: fo })]);
check(!(await ids(bu.token)).includes('in folder'), 'public set inside a private folder is hidden from other members');
check((await ids(ja.token)).includes('in folder'), 'owner still sees it');
check(await fnames(bu.token) === '' && await fnames(ja.token) === '여행 회화', 'private folder listed only for owner');
const buSet = await mk('budi set', 'public', {}, bu.token);
check(String(await q('select update_set($1,$2,$3::jsonb)', [buSet, bu.token, JSON.stringify({ folder_id: fo })])).includes('bad_folder'), "cannot put a set into someone else's folder");
const foOther = (await newFolder(ja.token, 'other space folder', 'public', S2)).id;
check(String(await q('select update_set($1,$2,$3::jsonb)', [inF, ja.token, JSON.stringify({ folder_id: foOther })])).includes('bad_folder'), 'cannot put a set into a folder of another space');
check((await one('select save_folder($1,$2,$3,$4)', [bu.token, fo, 'hack', 'public'])).error === 'forbidden', "cannot edit someone else's folder");

await one('select save_folder($1,$2,$3,$4)', [ja.token, fo, '여행 회화', 'public']);
check((await ids(bu.token)).includes('in folder') && (await fnames(bu.token)).split(',').includes('여행 회화'), 'public folder shows its sets to members');
check((await fnames(cy.token)).split(',').includes('여행 회화') && (await ids(cy.token)).includes('in folder'), 'and to everyone else (spaces are open)');
const privInPub = await mk('private set in public folder', 'private');
await one('select update_set($1,$2,$3::jsonb)', [privInPub, ja.token, JSON.stringify({ folder_id: fo })]);
check((await ids(bu.token)).includes('private set in public folder'), "a set in a folder follows the folder's visibility");

await one('select save_folder($1,$2,$3,$4,$5::uuid[])', [ja.token, fo, '여행 회화', 'partial', [bu.id, cy.id]]);
check(!(await ids(bu.token)).includes('in folder'), 'partial folder hidden before accepting');
const inbox = await one('select list_inbox($1)', [bu.token]);
check(inbox.some((x) => x.kind === 'folder' && x.folder_id === fo && x.count === 2 && x.space_id === S1), 'recipient gets a folder invite with the set count');
const fs1 = await one('select get_folder_shares($1,$2)', [ja.token, fo]);
check(fs1.length === 1 && fs1[0].status === 'pending', 'owner sees pending folder share; non-member was not added');
await one('select respond_folder_share($1,$2,true)', [bu.token, fo]);
const later = await mk('added later', 'private');
await one('select update_set($1,$2,$3::jsonb)', [later, ja.token, JSON.stringify({ folder_id: fo })]);
const bv = await one('select list_sets($1)', [bu.token]);
check(['in folder', 'added later'].every((t) => bv.some((r) => r.title === t && r.shared_with_me)), 'accepted folder shows all its sets, including ones added later');
check((await one('select list_folders($1)', [bu.token])).some((f) => f.id === fo && f.shared_with_me && f.space_id === S1), 'accepted folder listed as shared with me');
check(String(await q('select update_set($1,$2,$3::jsonb)', [later, bu.token, '{"title":"x"}'])).startsWith('ERR'), 'recipient cannot edit sets in a shared folder');

await one('select update_set($1,$2,$3::jsonb)', [later, ja.token, JSON.stringify({ folder_id: null })]);
check(!(await ids(bu.token)).includes('added later'), "moving a set out of the folder brings back the set's own visibility");

check((await one('select delete_folder($1,$2)', [bu.token, fo])).error === 'forbidden', "cannot delete someone else's folder");
await one('select delete_folder($1,$2)', [ja.token, fo]);
check(!(await fnames(ja.token)).includes('여행 회화'), 'folder deleted');
check((await ids(bu.token)).includes('in folder') && (await ids(ja.token)).includes('private set in public folder'), 'deleting a folder keeps its sets and who can see them');
check((await one('select list_sets($1)', [ja.token])).every((r) => r.folder_id === null), 'sets moved out of the deleted folder');

console.log('list order (per person)');
const fk = 'f:' + '11111111-1111-4111-8111-111111111111', sk1 = 's:' + '22222222-2222-4222-8222-222222222222';
check((await one('select get_orders($1)', [null])).error === 'auth' && (await one('select save_order($1,$2,$3)', [null, 'top:' + S1, [fk]])).error === 'auth', 'guests keep their order on the device only');
check((await one('select save_order($1,$2,$3)', [ja.token, 'top:' + S1, [sk1, fk]])).ok, 'saving an order');
check(JSON.stringify((await one('select get_orders($1)', [ja.token]))['top:' + S1]) === JSON.stringify([sk1, fk]), 'reading it back in order');
check(JSON.stringify(await one('select get_orders($1)', [bu.token])) === '{}', "nobody sees someone else's order");
await one('select save_order($1,$2,$3)', [ja.token, 'top:' + S1, [fk, sk1]]);
check(JSON.stringify((await one('select get_orders($1)', [ja.token]))['top:' + S1]) === JSON.stringify([fk, sk1]), 'saving again replaces it');
check((await one('select save_order($1,$2,$3)', [ja.token, 'nope', [fk]])).error === 'bad_scope' && (await one('select save_order($1,$2,$3)', [ja.token, 'top:' + S1, ['x:1']])).error === 'bad_items', 'bad lists and items are rejected');
await one('select save_order($1,$2,$3)', [ja.token, 'top:' + S1, []]);
check(!('top:' + S1 in (await one('select get_orders($1)', [ja.token]))), 'an empty order is removed');
check(typeof (await q('select * from list_orders')) === 'string', 'orders table not readable directly');

console.log('admin pins (top of everyone\'s list)');
check(JSON.stringify(await one('select list_pins()')) === '{}', 'no pins at first');
check((await one('select save_pins($1,$2,$3,$4)', [bu.token, 'wrong', 'top:' + S1, [sk1]])).error === 'forbidden', 'only the admin key can pin');
check((await one('select save_pins($1,$2,$3,$4)', [null, ADMIN, 'top:' + S1, [sk1]])).error === 'auth', 'the admin must be signed in to pin');
check((await one('select save_pins($1,$2,$3,$4)', [bu.token, ADMIN, 'top:' + S1, [sk1, fk]])).ok, 'admin pins items');
check(JSON.stringify((await one('select list_pins()'))['top:' + S1]) === JSON.stringify([sk1, fk]), 'everyone (even guests) reads pins in order');
check((await one('select save_pins($1,$2,$3,$4)', [bu.token, ADMIN, 'top:' + S1, ['bad']])).error === 'bad_items', 'bad pin items rejected');
await one('select save_pins($1,$2,$3,$4)', [bu.token, ADMIN, 'top:' + S1, []]);
check(JSON.stringify(await one('select list_pins()')) === '{}', 'unpinning everything removes the list');
check(typeof (await q('select * from list_pins')) === 'string', 'pins table not readable directly');

console.log('looking around without logging in');
const gIds = async (tok = null) => (await one('select list_sets($1)', [tok])).map((r) => r.title);
const gFolders = async () => (await one('select list_folders($1)', [null])).map((f) => f.title);
const g = await gIds();
check(g.includes('pub') && !g.includes('priv') && !g.includes('part') && !g.includes('edit me'), 'guests see only public sets');
check((await one('select list_sets($1)', [null])).every((r) => !r.shared_with_me), 'nothing marked shared for guests');
check((await gIds(cy.token)).includes('pub') && !(await gIds(cy.token)).includes('priv'), 'a signed-in non-member sees the same');
const gf = (await newFolder(ja.token, '공개 폴더', 'public')).id;
const inGf = await mk('private set in public folder (guest)', 'private');
await one('select update_set($1,$2,$3::jsonb)', [inGf, ja.token, JSON.stringify({ folder_id: gf })]);
check((await gIds()).includes('private set in public folder (guest)') && (await gFolders()).includes('공개 폴더'), 'public folders and their sets are visible to guests');
await one('select save_folder($1,$2,$3,$4)', [ja.token, gf, '공개 폴더', 'private']);
check(!(await gIds()).includes('private set in public folder (guest)') && !(await gFolders()).includes('공개 폴더'), 'a private folder hides its sets from guests');
const gdel = await mk('deleted public', 'public');
await one(`select update_set($1,$2,'{"deleted":true}'::jsonb)`, [gdel, ja.token]);
check(!(await gIds()).includes('deleted public'), 'sets in the trash are not shown to guests');
check(String(await one('select create_set($1::jsonb,$2)', [JSON.stringify({ title: 'x', script: 'x', space_id: S1 }), null])).startsWith('ERR'), 'guests cannot add sets');
check(String(await one('select create_set($1::jsonb,$2)', [JSON.stringify({ title: 'x', script: 'x', space_id: S2 }), cy.token])).includes('no_space'), 'adding a set needs joining the space first');

console.log('existing data moves into the first space (one time)');
const old = new PGlite({ extensions: { pgcrypto } });
const o = helpers(old);
await old.exec(STUB);
const before = migrations.filter((f) => f < '20261127000000');
for (const f of before) await old.exec(sqlOf(f));
await old.exec(`update settings set join_code = 'oldcode' where id = 1`);
const oa = await o.one(`select sign_up('anna','Anna','secret1','oldcode')`);
const oset = await o.one('select create_set($1::jsonb,$2)', [JSON.stringify({ title: 'old set', script: 'x', visibility: 'public' }), oa.token]);
const ofo = (await o.one('select save_folder($1,null,$2,$3)', [oa.token, 'old folder', 'public'])).id;
for (const f of migrations) await old.exec(sqlOf(f));
const sp = await o.one('select list_spaces($1,$2)', [oa.token, null]);
check(sp.length === 1 && sp[0].name === '기본 공간', 'existing members land in 기본 공간');
check((await o.one('select list_sets($1)', [oa.token])).some((r) => r.id === oset && r.space_id === sp[0].id), 'existing sets moved into it');
check((await o.one('select list_folders($1)', [oa.token])).some((f) => f.id === ofo && f.space_id === sp[0].id), 'existing folders moved into it');
check((await o.one(`select join_code from spaces`)) === 'oldcode' && (await o.one('select join_code from settings')) === null, 'old sign-up code becomes the space code; sign-up is open');
const late = await o.one(`select sign_up('late','Late','secret1',null)`);
for (const f of migrations) await old.exec(sqlOf(f));
const ls = await o.one('select list_spaces($1)', [late.token]);
check((await o.one('select count(*)::int from spaces')) === 1 && ls.length === 1 && !ls[0].member, 're-running does not add spaces or members');

console.log(failures.length ? `\nFAILED: ${failures.join(', ')}` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);

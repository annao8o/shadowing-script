// Service worker: keeps the page itself (and the scripts/fonts it needs) so the site opens without internet.
// Scripts and recordings are NOT cached here: the page saves only the sets/folders the user picks (IndexedDB).
const SHELL = 'naskah-shell-v2';
const CORE = ['./', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/dist/umd/supabase.js'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => Promise.all(CORE.map((u) => c.add(u).catch(() => {})))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k.startsWith('naskah-shell-') && k !== SHELL).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

const sameApp = (u) => u.origin === self.location.origin && u.pathname.startsWith(new URL('./', self.location).pathname);
const isAsset = (u) => u.hostname === 'cdn.jsdelivr.net' || u.hostname === 'fonts.googleapis.com' || u.hostname === 'fonts.gstatic.com';

// the page: try the network first (so updates show up), fall back to the saved copy
async function pageFirst(req) {
  const c = await caches.open(SHELL);
  try {
    const r = await Promise.race([fetch(req), new Promise((_, no) => setTimeout(() => no(new Error('slow')), 6000))]);
    if (r && r.ok) c.put('./', r.clone());
    return r;
  } catch (e) {
    return (await c.match('./')) || (await c.match(req, { ignoreSearch: true })) || Response.error();
  }
}

// libraries and fonts: saved copy first, refreshed in the background
async function assetFirst(req) {
  const c = await caches.open(SHELL);
  const hit = await c.match(req);
  const net = fetch(req).then((r) => { if (r && (r.ok || r.type === 'opaque')) c.put(req, r.clone()); return r; }).catch(() => null);
  return hit || (await net) || Response.error();
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (req.mode === 'navigate' && sameApp(u) && !u.pathname.includes('/tests/')) { e.respondWith(pageFirst(req)); return; }
  if (isAsset(u) || (sameApp(u) && /\/(manifest\.webmanifest|icon-\d+\.png|apple-touch-icon\.png)$/.test(u.pathname))) { e.respondWith(assetFirst(req)); }
});

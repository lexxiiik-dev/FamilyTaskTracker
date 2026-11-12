// Service Worker таск-трекера: все файлы приложения лежат в кэше, поэтому оно открывается
// и работает без связи с сервером. Данные хранятся в IndexedDB, запросы к API не кэшируются.
// Список файлов и версию подставляет tools/build-web.ps1 при сборке.
const VERSION = '__VERSION__';
const FILES = __FILES__;
const CACHE = 'todo-' + VERSION;

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    await Promise.all(FILES.map((u) => c.add(new Request(u, { cache: 'no-cache' })).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    // на том же адресе могут жить и другие сайты: удаляем только свои прежние кэши
    for (const k of await caches.keys()) if (k.startsWith('todo-') && k !== CACHE) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;
  const scope = new URL(self.registration.scope).pathname;
  if (!url.pathname.startsWith(scope)) return;
  const rel = url.pathname.slice(scope.length);
  if (rel.startsWith('api/') || rel === 'sw.js') return;
  e.respondWith((async () => {
    const c = await caches.open(CACHE);
    const key = (req.mode === 'navigate' || rel === '') ? './' : req;
    const hit = await c.match(key, { ignoreSearch: true });
    if (hit) return hit;
    try {
      const r = await fetch(req);
      if (r.ok) c.put(req, r.clone());
      return r;
    } catch (err) {
      return (await c.match('./')) || Response.error();
    }
  })());
});

// ─────────────────────────────────────────────────────────────────────────────
// Crew Logbook Service Worker
// Version bump here when you want clients to pick up a new shell.
// ─────────────────────────────────────────────────────────────────────────────
const CACHE = 'crew-logbook-v44';

// ── Critical shell: must all succeed for the app to work offline ──────────────
// These are fetched individually so a single failure does not block the rest.
const SHELL_ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './icon.svg',
];

// ── Third-party scripts: cached best-effort ───────────────────────────────────
// A failure here is tolerated during install so the shell still caches.
// On a live device they will already be in the cache from the first online visit.
const OPTIONAL_CDN = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js',
  'https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js',
  'https://cdn.jsdelivr.net/npm/lucide@0.447.0/dist/umd/lucide.min.js',
];

// ── Install ───────────────────────────────────────────────────────────────────
// Cache the shell atomically (all-or-nothing for the critical set).
// Cache optional CDN scripts best-effort — failures are swallowed so install
// succeeds even if jsDelivr is unreachable.
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(async cache => {
      // Critical shell — all must succeed
      await cache.addAll(SHELL_ASSETS);

      // Optional CDN — each is attempted independently
      await Promise.allSettled(
        OPTIONAL_CDN.map(url =>
          fetch(url, { cache: 'no-cache' })
            .then(res => {
              if (res.ok) cache.put(url, res);
            })
            .catch(() => { /* tolerate CDN failures during install */ })
        )
      );

      return self.skipWaiting();
    })
  );
});

// ── Activate ──────────────────────────────────────────────────────────────────
// Delete old caches, then take control of open pages.
// NOTE: IndexedDB is NOT touched here — only caches are cleaned up.
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// ── Fetch ─────────────────────────────────────────────────────────────────────
self.addEventListener('fetch', e => {
  const url = e.request.url;
  const method = e.request.method;

  // Pass through: non-GET, Supabase API, Anthropic API, data URIs
  if (method !== 'GET') return;
  if (url.includes('supabase.co') || url.includes('anthropic.com')) return;
  if (url.startsWith('data:') || url.startsWith('blob:')) return;

  // CDN scripts: cache-first, update in background
  // These are pinned versions — they never change — so cache-first is safe.
  if (url.includes('cdn.jsdelivr.net') || url.includes('unpkg.com') || url.includes('cdnjs.cloudflare.com')) {
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached;
        return fetch(e.request).then(res => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then(c => c.put(e.request, copy)).catch(() => {});
          }
          return res;
        });
      })
    );
    return;
  }

  // App shell and local assets: network-first with cache fallback.
  // On success, update the cache for the next offline visit.
  e.respondWith(
    fetch(e.request)
      .then(res => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(e.request).then(cached => {
        if (cached) return cached;
        // Offline navigation fallback: return the cached shell for same-origin navigates
        if (e.request.mode === 'navigate') {
          return caches.match('./index.html');
        }
        return new Response('Offline', { status: 503, statusText: 'Service Unavailable' });
      }))
  );
});

// ── Messages from the page ────────────────────────────────────────────────────
self.addEventListener('message', e => {
  if (e.data === 'skipWaiting') self.skipWaiting();
});

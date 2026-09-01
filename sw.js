const CACHE   = 'crew-logbook-v23';
const ASSETS  = [
  './',
  './index.html',
  './manifest.json',
  './icon.svg',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js',
  'https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js'
];

// Install — cache app shell, activate immediately
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(ASSETS))
      .then(() => self.skipWaiting())  // don't wait for old SW to finish
  );
});

// Activate — delete ALL old caches, take control immediately
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())  // take control of all open tabs now
  );
});

// Fetch strategy:
// - App shell (index.html): network-first, always check for update
// - CDN scripts: cache-first (they don't change)
// - Supabase API: bypass SW entirely
self.addEventListener('fetch', e => {
  const url = e.request.url;

  // Never intercept Supabase or Anthropic API calls
  if(url.includes('supabase.co') || url.includes('anthropic.com')) return;

  // CDN resources: cache-first (fast, stable)
  if(url.includes('cdn.jsdelivr.net')){
    e.respondWith(
      caches.match(e.request).then(cached => {
        return cached || fetch(e.request).then(res => {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
          return res;
        });
      })
    );
    return;
  }

  // App shell: network-first so updates apply on next load
  e.respondWith(
    fetch(e.request)
      .then(res => {
        if(e.request.method === 'GET' && res.status === 200){
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});

// When a new SW activates, tell all clients to reload
// so the latest app shell is served immediately
self.addEventListener('message', e => {
  if(e.data === 'skipWaiting') self.skipWaiting();
});

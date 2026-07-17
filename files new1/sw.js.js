const CACHE = 'crew-logbook-v1';
const ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './icon.svg',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js'
];

// Install: cache app shell
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
  );
});

// Activate: clean up old caches
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Fetch: network first, fall back to cache
self.addEventListener('fetch', e => {
  // Don't intercept Supabase API calls — always needs real network
  if(e.request.url.includes('supabase.co')) return;

  e.respondWith(
    fetch(e.request)
      .then(res => {
        // Cache successful GET responses
        if(e.request.method === 'GET' && res.status === 200){
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});

/* Ride Book service worker: keeps the app usable offline and fetches fresh pages when online. */
const VERSION = 'ridebook-v5';
const SHELL = [
  './app.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './bosch_dashboard.html',
  './bosch_ride_map.html',
  './bosch_status.json',
  'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css'
];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(VERSION).then(cache => Promise.allSettled(SHELL.map(u => cache.add(u)))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

function stripQuery(request) {
  const url = new URL(request.url);
  if (url.origin === self.location.origin) { url.search = ''; return new Request(url.toString(), { headers: request.headers, mode: 'same-origin' }); }
  return request;
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  const isTile = /tile\.openstreetmap\.org|opentopomap\.org/.test(url.host);
  if (isTile) return; // map tiles always come from the network; they are too many to cache
  const key = stripQuery(req);
  if (url.origin === self.location.origin || /cdnjs\.cloudflare\.com|fonts\.(googleapis|gstatic)\.com/.test(url.host)) {
    // network first, fall back to the saved copy
    event.respondWith(
      fetch(req, { cache: 'no-cache' }).then(res => { if (res && res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(key, copy)); } return res; })
        .catch(() => caches.match(key).then(hit => hit || (url.pathname.endsWith('app.html') ? caches.match('./app.html') : undefined)))
    );
  }
});

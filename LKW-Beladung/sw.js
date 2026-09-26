// Offline-Cache für den Ladeplan. Bei Änderungen an den Dateien VERSION hochzählen.
const VERSION = 'ladeplan-v4';
const FILES = [
  './', './index.html', './manifest.webmanifest', './icon.svg', './icon-192.png', './icon-512.png',
  './vendor/three.min.js', './vendor/OrbitControls.js', './fonts/fonts.css',
  './fonts/barlow-condensed-latin-500-normal.woff2', './fonts/barlow-condensed-latin-600-normal.woff2',
  './fonts/barlow-condensed-latin-700-normal.woff2', './fonts/barlow-condensed-latin-800-normal.woff2',
  './fonts/barlow-latin-400-normal.woff2', './fonts/barlow-latin-500-normal.woff2',
  './fonts/barlow-latin-600-normal.woff2', './fonts/barlow-latin-700-normal.woff2',
  './fonts/jetbrains-mono-latin-400-normal.woff2', './fonts/jetbrains-mono-latin-500-normal.woff2',
  './fonts/jetbrains-mono-latin-600-normal.woff2',
];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
// Erst das Netz fragen (damit Updates ankommen), ohne Netz aus dem Cache
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(req).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match('./index.html')))
  );
});

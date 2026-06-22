// Service worker mínimo — torna o app instalável (PWA) e funcional offline.
// Estratégia: network-first p/ GET same-origin, com fallback no cache.
const CACHE = "mindmap-v1";
const ASSETS = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;                 // não intercepta POST/PUT (API)
  const sameOrigin = new URL(req.url).origin === location.origin;
  if (!sameOrigin) return;                            // deixa chamadas à API/S3 passarem direto
  e.respondWith(
    fetch(req).then((r) => {
      if (r && r.ok) { const cp = r.clone(); caches.open(CACHE).then((c) => c.put(req, cp)); }
      return r;
    }).catch(() => caches.match(req).then((c) => c || caches.match("./index.html")))
  );
});

/// <reference lib="webworker" />
// Service worker: offline shell, push notifications, notification clicks.
// Scaffold only; the web foundation worker completes it (docs/remote-pwa-implementation.md 4).
export {};
declare const self: ServiceWorkerGlobalScope;

const CACHE = `picky-shell-${__SW_VERSION__}`;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(__PRECACHE__)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((key) => key.startsWith("picky-shell-") && key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

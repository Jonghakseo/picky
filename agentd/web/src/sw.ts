/// <reference lib="webworker" />
/**
 * Service worker: offline shell, push notifications, notification clicks.
 *
 * `/api/*` is never cached: a stale session would be worse than no session.
 * The shell is precached so the app opens from the Home Screen even when the
 * Mac is unreachable, and shows its own "can't reach your Mac" state.
 */
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

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  // A navigation always tries the network first (the shell may have been
  // rebuilt) and falls back to the cached shell when offline.
  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(async () => (await caches.match("/")) ?? Response.error()),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then((cached) => cached ?? fetch(request)),
  );
});

interface PushPayload {
  title: string;
  body: string;
  roomId: string;
  kind: string;
  badge: number;
}

self.addEventListener("push", (event) => {
  const payload = readPayload(event.data);
  if (!payload) return;
  event.waitUntil(
    (async () => {
      await self.registration.showNotification(payload.title, {
        body: payload.body,
        // One notification per room: a new one replaces the room's previous.
        tag: payload.roomId,
        renotify: true,
        data: { roomId: payload.roomId },
        icon: "/icons/icon-192.png",
        badge: "/icons/badge-72.png",
      } as NotificationOptions);
      await setBadge(payload.badge);
    })(),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const roomId = (event.notification.data as { roomId?: string } | undefined)?.roomId;
  if (!roomId) return;
  event.waitUntil(openRoom(roomId));
});

async function openRoom(roomId: string): Promise<void> {
  const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  const existing = clients[0];
  if (existing) {
    existing.postMessage({ type: "open-room", roomId });
    await existing.focus();
    return;
  }
  await self.clients.openWindow(`/room/${encodeURIComponent(roomId)}`);
}

function readPayload(data: PushMessageData | null): PushPayload | undefined {
  if (!data) return undefined;
  try {
    const parsed = data.json() as Partial<PushPayload>;
    if (typeof parsed.title !== "string" || typeof parsed.roomId !== "string") return undefined;
    return {
      title: parsed.title,
      body: typeof parsed.body === "string" ? parsed.body : "",
      roomId: parsed.roomId,
      kind: typeof parsed.kind === "string" ? parsed.kind : "reply",
      badge: typeof parsed.badge === "number" ? parsed.badge : 0,
    };
  } catch {
    return undefined;
  }
}

async function setBadge(count: number): Promise<void> {
  // Badging lives on WorkerNavigator here, and the lib types do not declare it yet.
  const navigatorWithBadge = self.navigator as WorkerNavigator & {
    setAppBadge?(count?: number): Promise<void>;
    clearAppBadge?(): Promise<void>;
  };
  try {
    if (count > 0) await navigatorWithBadge.setAppBadge?.(count);
    else await navigatorWithBadge.clearAppBadge?.();
  } catch {
    // Badging is unavailable outside an installed app; nothing to recover.
  }
}

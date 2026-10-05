/**
 * Whether this browser can receive Web Push, and why not when it cannot.
 *
 * Three real cases on a phone (docs/remote-pwa-plan.md "보안", pi-pocket's
 * notes): iOS grants push only to a Home Screen app, service workers and push
 * need a secure context, and the user may have denied the permission.
 */
export interface PushEnvironment {
  ios: boolean;
  standalone: boolean;
  secureContext: boolean;
  serviceWorker: boolean;
  pushManager: boolean;
  notificationPermission: "default" | "granted" | "denied";
  /** The gateway only has a VAPID key once push is configured. */
  vapidKey: boolean;
}

export type PushBlockedReason = "iosNeedsHomeScreen" | "insecure" | "unsupported" | "denied" | "serverDisabled";

export type PushAvailability =
  | { available: true; permission: "default" | "granted" }
  | { available: false; reason: PushBlockedReason };

export function pushAvailability(environment: PushEnvironment): PushAvailability {
  if (environment.ios && !environment.standalone) return { available: false, reason: "iosNeedsHomeScreen" };
  if (!environment.secureContext) return { available: false, reason: "insecure" };
  if (!environment.serviceWorker || !environment.pushManager) return { available: false, reason: "unsupported" };
  if (environment.notificationPermission === "denied") return { available: false, reason: "denied" };
  if (!environment.vapidKey) return { available: false, reason: "serverDisabled" };
  return { available: true, permission: environment.notificationPermission };
}

/** Copy key for a blocked reason; the strings live in `web/i18n/remote-strings.json`. */
export function pushBlockedKey(reason: PushBlockedReason): string {
  switch (reason) {
    case "iosNeedsHomeScreen":
      return "remote.settings.notifications.unavailable.homeScreen";
    case "insecure":
      return "remote.settings.notifications.unavailable.insecure";
    case "denied":
      return "remote.settings.notifications.unavailable.denied";
    case "serverDisabled":
      return "remote.settings.notifications.unavailable.server";
    case "unsupported":
      return "remote.settings.notifications.unavailable.unsupported";
  }
}

/** base64url VAPID key to the `Uint8Array` `PushManager.subscribe` wants. */
export function decodeVapidKey(base64url: string): Uint8Array {
  const padded = base64url.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(base64url.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

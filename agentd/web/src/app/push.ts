/**
 * Web Push subscription from the app side. The permission prompt only ever
 * follows a tap (iOS requires it, and asking unprompted is how people turn
 * notifications off for good).
 */
import type { RemotePushSubscription } from "../../../src/remote/protocol";
import { decodeVapidKey, pushAvailability, type PushAvailability, type PushEnvironment } from "./push-policy";
import type { PlatformFacts } from "./platform";
import type { Transport } from "./transport";

export function readPushEnvironment(platform: PlatformFacts, vapidKey: string | undefined): PushEnvironment {
  return {
    ios: platform.ios,
    standalone: platform.standalone,
    secureContext: platform.secureContext,
    serviceWorker: "serviceWorker" in navigator,
    pushManager: typeof globalThis.PushManager !== "undefined",
    notificationPermission: typeof Notification === "undefined" ? "default" : Notification.permission,
    vapidKey: Boolean(vapidKey),
  };
}

export function readPushAvailability(platform: PlatformFacts, vapidKey: string | undefined): PushAvailability {
  return pushAvailability(readPushEnvironment(platform, vapidKey));
}

export async function isSubscribed(): Promise<boolean> {
  const registration = await navigator.serviceWorker?.getRegistration();
  if (!registration) return false;
  return (await registration.pushManager.getSubscription()) !== null;
}

export type EnablePushResult = "enabled" | "denied" | "failed";

export async function enablePush(transport: Transport, vapidKey: string): Promise<EnablePushResult> {
  try {
    const permission = await Notification.requestPermission();
    if (permission !== "granted") return "denied";
    const registration = await navigator.serviceWorker.ready;
    const existing = await registration.pushManager.getSubscription();
    const subscription =
      existing ??
      (await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: decodeVapidKey(vapidKey) as BufferSource,
      }));
    await transport.pushSubscribe(subscription.toJSON() as RemotePushSubscription);
    return "enabled";
  } catch {
    return "failed";
  }
}

export async function disablePush(transport: Transport): Promise<void> {
  const registration = await navigator.serviceWorker?.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();
  const endpoint = subscription?.endpoint;
  await subscription?.unsubscribe();
  await transport.pushUnsubscribe(endpoint);
}

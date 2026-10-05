/**
 * Push fan-out for the gateway: keys, per-device subscriptions, and pruning.
 *
 * Push is off until the hub reports a `publicUrl`, because the VAPID subject
 * has to be a URL the push service can attribute to this Mac.
 */
import type { DeviceRecord, DeviceStore } from "../device-store.js";
import { errorMessage, logGateway } from "../log.js";
import { buildPushPayload, pushLocaleOf, type PushKind } from "./push-copy.js";
import { PushSender, type PushFetch } from "./sender.js";
import { loadOrCreateVapidKeys, type VapidKeyPair } from "./vapid.js";

export interface PushServiceOptions {
  dataDir: string;
  devices: DeviceStore;
  fetchImpl?: PushFetch;
}

export interface PushNotification {
  roomId: string;
  roomTitle: string;
  kind: PushKind;
  badge: number;
}

export class PushService {
  private keys?: VapidKeyPair;
  private subject?: string;

  constructor(private readonly options: PushServiceOptions) {}

  async init(): Promise<void> {
    this.keys = await loadOrCreateVapidKeys(this.options.dataDir);
  }

  get publicKey(): string | undefined {
    return this.keys?.publicKey;
  }

  get enabled(): boolean {
    return this.keys !== undefined && this.subject !== undefined;
  }

  setSubject(publicUrl: string | undefined): void {
    this.subject = publicUrl?.trim() || undefined;
  }

  /** Delivers to every subscription of these devices, pruning dead endpoints. */
  async notify(deviceIds: readonly string[], notification: PushNotification): Promise<number> {
    if (!this.keys || !this.subject) return 0;
    const sender = new PushSender({
      keys: this.keys,
      subject: this.subject,
      ...(this.options.fetchImpl ? { fetchImpl: this.options.fetchImpl } : {}),
    });

    let delivered = 0;
    for (const deviceId of deviceIds) {
      const device = this.options.devices.get(deviceId);
      if (!device) continue;
      delivered += await this.notifyDevice(sender, device, notification);
    }
    return delivered;
  }

  private async notifyDevice(sender: PushSender, device: DeviceRecord, notification: PushNotification): Promise<number> {
    const payload = buildPushPayload({
      roomId: notification.roomId,
      roomTitle: notification.roomTitle,
      kind: notification.kind,
      locale: pushLocaleOf(device.locale),
      badge: notification.badge,
    });

    let delivered = 0;
    for (const subscription of [...device.pushSubscriptions]) {
      try {
        const result = await sender.send(subscription, payload);
        if (result.ok) {
          delivered += 1;
          continue;
        }
        logGateway("push failed", { deviceId: device.id, status: result.status, reason: result.reason });
        if (result.gone) await this.options.devices.removeSubscription(device.id, subscription.endpoint);
      } catch (error) {
        logGateway("push error", { deviceId: device.id, error: errorMessage(error) });
      }
    }
    return delivered;
  }
}

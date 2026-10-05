/**
 * Paired phones (`<dataDir>/devices.json`).
 *
 * Only `sha256(token)` is stored, so a stolen devices file cannot be replayed
 * as a cookie. Lookups are constant-time over the hash to keep the comparison
 * out of timing reach.
 */
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { HubDevice } from "../remote/hub-protocol.js";
import type { RemotePushSubscription } from "../remote/protocol.js";
import { dataPath, ensureDirectory, randomId, readJsonFile, writeJsonFileAtomic } from "./storage.js";

/** At most this many push subscriptions per device (docs 2.8). */
export const MAX_SUBSCRIPTIONS_PER_DEVICE = 5;

export interface StoredPushSubscription extends RemotePushSubscription {
  createdAt: string;
}

export interface DeviceRecord {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: string;
  lastSeenAt?: string;
  locale?: string;
  /** Paired from a browser on this Mac. Shown as "This Mac" on the Mac's device list. */
  local?: boolean;
  pushSubscriptions: StoredPushSubscription[];
}

interface DevicesFile {
  version: 1;
  devices: DeviceRecord[];
}

export function hashDeviceToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function createDeviceToken(): string {
  return randomBytes(32).toString("base64url");
}

export class DeviceStore {
  private devices: DeviceRecord[] = [];
  private readonly path: string;
  private writing: Promise<void> = Promise.resolve();

  constructor(private readonly dataDir: string) {
    this.path = dataPath(dataDir, "devices.json");
  }

  async load(): Promise<void> {
    await ensureDirectory(this.dataDir);
    const file = await readJsonFile<DevicesFile>(this.path);
    this.devices = (file?.devices ?? []).map((device) => ({ ...device, pushSubscriptions: device.pushSubscriptions ?? [] }));
  }

  list(): readonly DeviceRecord[] {
    return this.devices;
  }

  get(deviceId: string): DeviceRecord | undefined {
    return this.devices.find((device) => device.id === deviceId);
  }

  findByToken(token: string): DeviceRecord | undefined {
    const candidate = Buffer.from(hashDeviceToken(token), "hex");
    return this.devices.find((device) => {
      const stored = Buffer.from(device.tokenHash, "hex");
      return stored.length === candidate.length && timingSafeEqual(stored, candidate);
    });
  }

  async add(name: string, options: { local?: boolean } = {}): Promise<{ device: DeviceRecord; token: string }> {
    const token = createDeviceToken();
    const device: DeviceRecord = {
      id: `dev_${randomId(6)}`,
      name,
      tokenHash: hashDeviceToken(token),
      createdAt: new Date().toISOString(),
      ...(options.local ? { local: true } : {}),
      pushSubscriptions: [],
    };
    this.devices = [...this.devices, device];
    await this.persist();
    return { device, token };
  }

  async remove(deviceId: string): Promise<boolean> {
    const next = this.devices.filter((device) => device.id !== deviceId);
    if (next.length === this.devices.length) return false;
    this.devices = next;
    await this.persist();
    return true;
  }

  async rename(deviceId: string, name: string): Promise<boolean> {
    return this.update(deviceId, (device) => ({ ...device, name }));
  }

  async touch(deviceId: string, locale?: string): Promise<void> {
    await this.update(deviceId, (device) => ({
      ...device,
      lastSeenAt: new Date().toISOString(),
      ...(locale ? { locale } : {}),
    }));
  }

  async addSubscription(deviceId: string, subscription: RemotePushSubscription): Promise<boolean> {
    return this.update(deviceId, (device) => {
      const kept = device.pushSubscriptions.filter((existing) => existing.endpoint !== subscription.endpoint);
      const next = [...kept, { ...subscription, createdAt: new Date().toISOString() }];
      // Oldest first, so trimming drops the stale ones.
      return { ...device, pushSubscriptions: next.slice(-MAX_SUBSCRIPTIONS_PER_DEVICE) };
    });
  }

  async removeSubscription(deviceId: string, endpoint: string): Promise<boolean> {
    return this.update(deviceId, (device) => ({
      ...device,
      pushSubscriptions: device.pushSubscriptions.filter((existing) => existing.endpoint !== endpoint),
    }));
  }

  hubDevices(onlineDeviceIds: ReadonlySet<string>): HubDevice[] {
    return this.devices.map((device) => ({
      id: device.id,
      name: device.name,
      createdAt: device.createdAt,
      ...(device.lastSeenAt ? { lastSeenAt: device.lastSeenAt } : {}),
      online: onlineDeviceIds.has(device.id),
      pushEnabled: device.pushSubscriptions.length > 0,
      ...(device.local ? { local: true } : {}),
    }));
  }

  private async update(deviceId: string, change: (device: DeviceRecord) => DeviceRecord): Promise<boolean> {
    const index = this.devices.findIndex((device) => device.id === deviceId);
    if (index < 0) return false;
    const next = [...this.devices];
    next[index] = change(next[index]);
    this.devices = next;
    await this.persist();
    return true;
  }

  private async persist(): Promise<void> {
    const file: DevicesFile = { version: 1, devices: this.devices };
    this.writing = this.writing.then(async () => {
      await ensureDirectory(this.dataDir);
      await writeJsonFileAtomic(this.path, file);
    });
    await this.writing;
  }
}

/**
 * Fan-out across a device's subscriptions, and the pruning that keeps a phone
 * that uninstalled the PWA from costing a request on every notification.
 */
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DeviceStore } from "../device-store.js";
import { PushService } from "./push-service.js";
import type { PushFetch } from "./sender.js";

let root: string;
let devices: DeviceStore;
let deviceId: string;

const APPLE = "https://web.push.apple.com/one";
const FCM = "https://fcm.googleapis.com/fcm/send/two";

const subscription = (endpoint: string) => ({
  endpoint,
  keys: {
    p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    auth: "BTBZMqHH6r4Tts7J_aSIgg",
  },
});

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "picky-push-"));
  devices = new DeviceStore(root);
  await devices.load();
  const added = await devices.add("iPhone");
  deviceId = added.device.id;
  await devices.addSubscription(deviceId, subscription(APPLE));
  await devices.addSubscription(deviceId, subscription(FCM));
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

function service(fetchImpl: PushFetch): PushService {
  return new PushService({ dataDir: root, devices, fetchImpl });
}

const notification = { roomId: "s1", roomTitle: "Pickle", kind: "completed" as const, badge: 2 };

describe("push service", () => {
  it("stays off until the Mac reports a public URL", async () => {
    const calls: string[] = [];
    const push = service(async (url) => { calls.push(url); return { status: 201 }; });
    await push.init();
    expect(push.enabled).toBe(false);
    expect(await push.notify([deviceId], notification)).toBe(0);
    expect(calls).toHaveLength(0);

    push.setSubject("https://mac.tail1234.ts.net");
    expect(push.enabled).toBe(true);
    expect(await push.notify([deviceId], notification)).toBe(2);
    expect(calls.sort()).toEqual([FCM, APPLE].sort());
  });

  it("turns back off when remote access loses its public URL", async () => {
    const push = service(async () => ({ status: 201 }));
    await push.init();
    push.setSubject("https://mac.tail1234.ts.net");
    push.setSubject("   ");
    expect(push.enabled).toBe(false);
  });

  it("drops a subscription the push service reports as gone, and keeps the others", async () => {
    const push = service(async (url) => ({ status: url === APPLE ? 410 : 201 }));
    await push.init();
    push.setSubject("https://mac.tail1234.ts.net");

    expect(await push.notify([deviceId], notification)).toBe(1);
    expect(devices.get(deviceId)?.pushSubscriptions.map((item) => item.endpoint)).toEqual([FCM]);
  });

  it("keeps a subscription that failed temporarily", async () => {
    const push = service(async () => ({ status: 500 }));
    await push.init();
    push.setSubject("https://mac.tail1234.ts.net");

    expect(await push.notify([deviceId], notification)).toBe(0);
    expect(devices.get(deviceId)?.pushSubscriptions).toHaveLength(2);
  });

  it("ignores a device that is no longer paired", async () => {
    const push = service(async () => ({ status: 201 }));
    await push.init();
    push.setSubject("https://mac.tail1234.ts.net");
    expect(await push.notify(["gone"], notification)).toBe(0);
  });

  it("writes the room title and the localized body into the payload", async () => {
    await devices.touch(deviceId, "ko-KR");
    let seen: Buffer | undefined;
    const push = service(async (_url, init) => { seen = init.body; return { status: 201 }; });
    await push.init();
    push.setSubject("https://mac.tail1234.ts.net");
    await push.notify([deviceId], notification);
    // The body is encrypted end to end, so the relay cannot read the title.
    expect(seen?.toString("utf8")).not.toContain("Pickle");
    expect(seen?.byteLength).toBeGreaterThan(86);
  });
});

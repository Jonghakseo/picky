/**
 * The gateway can run for weeks, so expired uploads and orphaned dictation
 * recordings must be swept while it runs, not only when it starts.
 */
import { mkdir, mkdtemp, readdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { parseGatewayConfig } from "./config.js";
import { GatewayCore, MAINTENANCE_INTERVAL_MS, TEMPORARY_FILE_MAX_AGE_MS } from "./core.js";
import { UPLOAD_RETENTION_MS } from "./uploads.js";

let supportDir: string;
let core: GatewayCore;

beforeEach(async () => {
  supportDir = await mkdtemp(join(tmpdir(), "picky-core-maintenance-"));
  core = new GatewayCore({
    config: parseGatewayConfig({
      env: { PICKY_GATEWAY_HUB_TOKEN: "hub-token", PICKY_APP_SUPPORT_DIR: supportDir },
      entryDir: join(supportDir, "dist", "gateway"),
    }),
  });
});

afterEach(async () => {
  vi.useRealTimers();
  core.stop();
  await rm(supportDir, { recursive: true, force: true });
});

async function seed(relativePath: string, ageMs: number): Promise<string> {
  const path = join(supportDir, "Remote", relativePath);
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, "x");
  const when = new Date(Date.now() - ageMs);
  await utimes(path, when, when);
  return path;
}

async function ageDirectory(relativePath: string, ageMs: number): Promise<void> {
  const when = new Date(Date.now() - ageMs);
  await utimes(join(supportDir, "Remote", relativePath), when, when);
}

describe("gateway housekeeping", () => {
  it("removes stale tmp files and expired uploads but keeps fresh ones", async () => {
    await seed("tmp/old.m4a", TEMPORARY_FILE_MAX_AGE_MS + 60_000);
    await seed("tmp/fresh.m4a", 1_000);
    await seed("uploads/expiredupload/a.png", 0);
    await ageDirectory("uploads/expiredupload", UPLOAD_RETENTION_MS + 60_000);
    await seed("uploads/liveupload/a.png", 0);

    await core.runMaintenance();

    expect(await readdir(join(supportDir, "Remote", "tmp"))).toEqual(["fresh.m4a"]);
    expect(await readdir(join(supportDir, "Remote", "uploads"))).toEqual(["liveupload"]);
  });

  it("sweeps again on a timer while running, and stops sweeping after stop()", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
    const staleAge = TEMPORARY_FILE_MAX_AGE_MS + 60_000;
    const exists = async () => (await readdir(join(supportDir, "Remote", "tmp"))).includes("orphan.m4a");
    await seed("tmp/orphan.m4a", staleAge);
    await core.start();
    // start() sweeps once up front.
    expect(await exists()).toBe(false);

    await seed("tmp/orphan.m4a", staleAge);
    await vi.advanceTimersByTimeAsync(MAINTENANCE_INTERVAL_MS);
    await vi.waitFor(async () => expect(await exists()).toBe(false));

    core.stop();
    await seed("tmp/orphan.m4a", staleAge);
    await vi.advanceTimersByTimeAsync(MAINTENANCE_INTERVAL_MS * 2);
    expect(await exists()).toBe(true);
  });
});

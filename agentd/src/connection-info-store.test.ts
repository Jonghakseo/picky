import { mkdtemp, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PROTOCOL_VERSION } from "./protocol.js";
import { connectionInfoPath, readConnectionInfo, removeConnectionInfo, writeConnectionInfo } from "./connection-info-store.js";

describe("connection info store", () => {
  it("writes a 0600 Picky daemon connection file for Pi extensions", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-connection-info-"));
    const info = {
      protocolVersion: PROTOCOL_VERSION,
      url: "ws://127.0.0.1:17631",
      token: "secret-token",
      port: 17631,
      pid: process.pid,
      appSupportDir: root,
      defaultCwd: "/tmp/project",
      startedAt: "2026-05-02T00:00:00.000Z",
    } as const;

    const path = await writeConnectionInfo(root, info);

    expect(path).toBe(connectionInfoPath(root));
    await expect(readConnectionInfo(root)).resolves.toEqual(info);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
  });

  it("removes stale connection info without failing if it is already gone", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-connection-info-"));
    await writeConnectionInfo(root, {
      protocolVersion: PROTOCOL_VERSION,
      url: "ws://127.0.0.1:17631",
      token: "secret-token",
      port: 17631,
      pid: process.pid,
      appSupportDir: root,
      defaultCwd: "/tmp/project",
      startedAt: "2026-05-02T00:00:00.000Z",
    });

    await expect(removeConnectionInfo(root)).resolves.toBeUndefined();
    await expect(removeConnectionInfo(root)).resolves.toBeUndefined();
  });
});

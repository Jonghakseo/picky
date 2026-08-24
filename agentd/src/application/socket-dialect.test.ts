import { describe, expect, it } from "vitest";
import { SocketDialectRegistry } from "./socket-dialect.js";

describe("SocketDialectRegistry", () => {
  it("starts negotiating, locks from capabilities, and never changes dialect", () => {
    const registry = new SocketDialectRegistry();
    const legacySocket = {};
    const v2Socket = {};

    expect(registry.get(legacySocket)).toBe("negotiating");
    expect(registry.lockFromCapabilities(legacySocket, ["pickleBridge"])).toBe("v1");
    expect(registry.get(legacySocket)).toBe("v1");
    expect(() => registry.lockFromCapabilities(legacySocket, ["sessionProjectionV2"])).toThrow("Socket dialect is locked to v1");

    expect(registry.lockFromCapabilities(v2Socket, ["sessionProjectionV2"])).toBe("v2");
    expect(() => registry.lockLegacyProjection(v2Socket)).toThrow("Socket dialect is locked to v2");
  });

  it("keeps repeat locks in the same dialect idempotent", () => {
    const registry = new SocketDialectRegistry();
    const socket = {};

    expect(registry.lockLegacyProjection(socket)).toBe("v1");
    expect(registry.lockLegacyProjection(socket)).toBe("v1");
  });
});

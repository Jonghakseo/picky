import { describe, expect, it } from "vitest";
import { isLegacySessionProjectionEvent, isLegacySessionProjectionEventType, SocketDialectRegistry } from "./socket-dialect.js";

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

  it("keeps side-effect events available to both socket dialects", () => {
    expect(isLegacySessionProjectionEventType("sessionRewound")).toBe(false);
    expect(isLegacySessionProjectionEventType("sessionResourcesReloaded")).toBe(false);
    expect(isLegacySessionProjectionEventType("terminalSessionSyncOutcome")).toBe(false);
  });

  it("keeps only non-blocking editor text requests outside the legacy projection", () => {
    expect(isLegacySessionProjectionEvent({
      type: "extensionUiRequest",
      request: { method: "set_editor_text" },
    })).toBe(false);
    expect(isLegacySessionProjectionEvent({
      type: "extensionUiRequest",
      request: { method: "askUserQuestion" },
    })).toBe(true);
    expect(isLegacySessionProjectionEvent({ type: "sessionUpdated" })).toBe(true);
  });
});

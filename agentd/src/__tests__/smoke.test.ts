import { describe, expect, it } from "vitest";
import { PROTOCOL_VERSION } from "../protocol.js";

describe("agentd smoke", () => {
  it("exposes a protocol version", () => {
    expect(PROTOCOL_VERSION).toBe("2026-07-19");
  });
});

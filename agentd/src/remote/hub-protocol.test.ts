import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { HubRequestSchema, HubToGatewayMessageSchema } from "./hub-protocol.js";
import { RemoteClientMessageSchema } from "./protocol.js";
import { hudStatusPriority, hudStatusTone, isTerminalStatus } from "./status-presentation.js";

const fixtureRoot = fileURLToPath(new URL("../../../contracts/remote/hub/", import.meta.url));

function fixtures(direction: "hub-to-gateway" | "gateway-to-hub"): Array<[string, unknown]> {
  const directory = join(fixtureRoot, direction);
  return readdirSync(directory)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => [name, JSON.parse(readFileSync(join(directory, name), "utf8")) as unknown]);
}

describe("hub wire examples", () => {
  it.each(fixtures("hub-to-gateway"))("gateway accepts hub message %s", (_name, message) => {
    expect(HubToGatewayMessageSchema.safeParse(message).success).toBe(true);
  });

  it.each(fixtures("gateway-to-hub").filter(([name]) => name.startsWith("request-")))("hub request %s matches the request schema", (_name, message) => {
    const request = (message as { request?: unknown }).request;
    expect(HubRequestSchema.safeParse(request).success).toBe(true);
  });

  it("rejects a daemon url that is not loopback", () => {
    const parsed = HubToGatewayMessageSchema.safeParse({ type: "hub.daemons", token: "t", primary: { url: "ws://10.0.0.5:17631" }, children: [] });
    expect(parsed.success).toBe(false);
  });
});

describe("client messages", () => {
  it("accepts a steer send and rejects an unknown command", () => {
    expect(RemoteClientMessageSchema.safeParse({ type: "command", commandId: "cmd-00000001", command: { type: "session.send", sessionId: "s1", text: "hi", kind: "steer" } }).success).toBe(true);
    expect(RemoteClientMessageSchema.safeParse({ type: "command", commandId: "cmd-00000002", command: { type: "session.rm", sessionId: "s1" } }).success).toBe(false);
  });

  it("rejects upload ids that could escape the uploads directory", () => {
    const message = { type: "command", commandId: "cmd-00000003", command: { type: "main.send", text: "see", uploadIds: ["../../etc/passwd"] } };
    expect(RemoteClientMessageSchema.safeParse(message).success).toBe(false);
  });
});

describe("status presentation matches PickySessionStatusPresentation.swift", () => {
  const table = [
    ["queued", "other", false, 2],
    ["running", "inProgress", false, 1],
    ["waiting_for_input", "other", false, 0],
    ["blocked", "error", false, 3],
    ["completed", "completed", true, 5],
    ["failed", "error", true, 4],
    ["cancelled", "other", true, 6],
  ] as const;

  it.each(table)("%s", (status, tone, terminal, priority) => {
    expect(hudStatusTone(status)).toBe(tone);
    expect(isTerminalStatus(status)).toBe(terminal);
    expect(hudStatusPriority(status)).toBe(priority);
  });
});

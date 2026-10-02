import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION, type EventEnvelope } from "../protocol.js";
import { AgentdServer } from "../server.js";
import { SessionStore } from "../session-store.js";
import { SessionSupervisor } from "../session-supervisor.js";
import { MockRuntime } from "./mock-runtime.js";
import { PiOAuthService } from "./pi-oauth-service.js";

const DEVICE_USER_CODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const DEVICE_TOKEN_URL = "https://auth.openai.com/api/accounts/deviceauth/token";
const DEVICE_VERIFICATION_URI = "https://auth.openai.com/codex/device";

let server: AgentdServer;
let port: number;
let agentDir: string;

/**
 * Drives the real Pi SDK OpenAI Codex OAuth flow (no network) so Picky stays
 * pinned to the option ids the SDK actually offers and to the device code
 * payload the app relies on.
 */
describe("OpenAI Codex device code login", () => {
  beforeEach(async () => {
    agentDir = await mkdtemp(join(tmpdir(), "picky-codex-device-code-"));
    const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(agentDir));
    await supervisor.load();
    const piOAuth = new PiOAuthService({
      createRuntime: () => ModelRuntime.create({
        authPath: join(agentDir, "auth.json"),
        modelsPath: join(agentDir, "models.json"),
        allowModelNetwork: false,
      }),
    });
    server = new AgentdServer({ port: 0, token: "test-token", supervisor, piOAuth });
    port = await server.start();
  });

  afterEach(async () => {
    vi.unstubAllGlobals();
    await server.stop();
    await rm(agentDir, { recursive: true, force: true });
  });

  it("offers browser and device_code, then reports the user code to the app", async () => {
    const requestedUrls: string[] = [];
    vi.stubGlobal("fetch", async (input: unknown) => {
      const url = String(input);
      requestedUrls.push(url);
      if (url === DEVICE_USER_CODE_URL) {
        return new Response(
          JSON.stringify({ device_auth_id: "device-auth-1", user_code: "ABCD-1234", interval: 1 }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      if (url === DEVICE_TOKEN_URL) {
        // 403 is the SDK's "authorization pending" signal; the user has not
        // approved the code yet, so the flow keeps polling until cancelled.
        return new Response("", { status: 403 });
      }
      throw new Error(`Unexpected fetch during device code login: ${url}`);
    });

    const ws = new WebSocket(`ws://127.0.0.1:${port}?token=test-token`);
    const events: EventEnvelope[] = [];
    ws.on("message", (data) => events.push(JSON.parse(data.toString()) as EventEnvelope));
    await once(ws, "open");

    ws.send(JSON.stringify({
      id: "cmd-codex-device-login",
      protocolVersion: PROTOCOL_VERSION,
      type: "signInPiOAuth",
      providerId: "openai-codex",
    }));

    const prompt = await waitForEvent(events, "piOAuthPromptRequested");
    expect(prompt).toMatchObject({ requestId: "cmd-codex-device-login", promptType: "select" });
    const options = (prompt as { options?: Array<{ id: string }> }).options ?? [];
    expect(options.map((option) => option.id)).toEqual(["browser", "device_code"]);

    ws.send(JSON.stringify({
      id: "cmd-codex-device-answer",
      protocolVersion: PROTOCOL_VERSION,
      type: "answerPiOAuthPrompt",
      requestId: "cmd-codex-device-login",
      promptId: (prompt as { promptId: string }).promptId,
      value: "device_code",
    }));

    await expect(waitForEvent(events, "piOAuthUrlRequested")).resolves.toMatchObject({
      type: "piOAuthUrlRequested",
      requestId: "cmd-codex-device-login",
      providerId: "openai-codex",
      url: DEVICE_VERIFICATION_URI,
      userCode: "ABCD-1234",
    });
    expect(requestedUrls).toContain(DEVICE_USER_CODE_URL);

    ws.send(JSON.stringify({
      id: "cmd-codex-device-cancel",
      protocolVersion: PROTOCOL_VERSION,
      type: "cancelPiOAuth",
      requestId: "cmd-codex-device-login",
    }));
    await waitForEvent(events, "error", 5_000);
    ws.close();
    await once(ws, "close");
  }, 30_000);
});

async function waitForEvent(
  events: EventEnvelope[],
  type: EventEnvelope["type"],
  timeoutMs = 10_000,
): Promise<EventEnvelope> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const index = events.findIndex((event) => event.type === type);
    if (index >= 0) return events.splice(index, 1)[0]!;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for ${type}; received=${events.map((event) => event.type).join(",")}`);
}

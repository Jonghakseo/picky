//
// pi-contract.test.ts
//
// Smoke test that asserts every pi-coding-agent surface picky-agentd depends on
// is still present in the installed pi package. Runs on `pnpm test`, so a pi
// version bump that silently drops a symbol fails CI immediately instead of
// degrading the daemon at runtime.
//
// Two stability tiers (matches agentd/docs/pi-coupling.md):
//
//   - Hard contract (test fails on absence): the daemon literally cannot run
//     without these. Examples: `createAgentSessionServices`, `AgentSession.prompt`.
//   - Soft contract (console.warn on absence, test still passes): optional pi
//     capabilities the runtime sniffs for and falls back when missing. Soft
//     misses must remain non-fatal so a pi version that temporarily drops an
//     optional surface does not block the host build; pi-capabilities.ts logs
//     the absence per session as well.
//
// Adding a new pi-coupling? Add the symbol to the right list here and to
// docs/pi-coupling.md.
//

import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import * as pi from "@earendil-works/pi-coding-agent";

const HARD_PACKAGE_EXPORTS = [
  // Session factories that PiSdkRuntime calls in every path.
  "createAgentSessionServices",
  "createAgentSessionFromServices",
  "createAgentSessionRuntime",
  "getAgentDir",
  "SessionManager",
  "ModelRuntime",
  // Tool definition helper used by every application/*-tool.ts.
  "defineTool",
] as const;

// Reachable on `runtime.session` after createAgentSessionFromServices resolves.
// Listed in the order they appear in pi-sdk-runtime.ts so a future audit can grep one file.
const HARD_SESSION_MEMBERS = [
  "prompt",
  "abort",
  "subscribe",
  "bindExtensions",
  "isStreaming",
  "sessionFile",
  "setSessionName",
  "clearQueue",
  "getSteeringMessages",
  "getFollowUpMessages",
  "steeringMode",
  "followUpMode",
  "state",
  "sessionManager",
  "extensionRunner",
  "resourceLoader",
  "promptTemplates",
] as const;

// Optional pi surfaces accessed via pi-capabilities.ts. Each must remain safe to be
// missing — the runtime has a fallback path. The test only console.warns when they
// are missing so a pi bump that temporarily drops an optional surface does not
// block the host build.
const SOFT_SESSION_MEMBERS = [
  "setThinkingLevel",
  "cycleThinkingLevel",
  "cycleModel",
  "getContextUsage",
  "compact",
  "reload",
  "executeBash",
  "recordBashResult",
  "isBashRunning",
  "isCompacting",
] as const;

describe("pi-coding-agent contract", () => {
  it("exports every symbol picky-agentd depends on", () => {
    const missing: string[] = [];
    for (const name of HARD_PACKAGE_EXPORTS) {
      if (!(name in pi)) missing.push(name);
    }
    expect(missing, `Missing pi exports: ${missing.join(", ")}`).toEqual([]);
  });

  it("AgentSession exposes every hard-contract member after createAgentSessionFromServices", async () => {
    const session = await createTestSession();
    const missing = HARD_SESSION_MEMBERS.filter((name) => !memberPresent(session as unknown, name));
    expect(missing, `Missing AgentSession members: ${missing.join(", ")}`).toEqual([]);
  });

  it("AgentSession soft-contract surfaces are present (warn-only)", async () => {
    const session = await createTestSession();
    const missing = SOFT_SESSION_MEMBERS.filter((name) => !memberPresent(session as unknown, name));
    if (missing.length > 0) {
      // Backward-compat: do not fail. Log once so the next test run captures it and
      // the operator can decide whether to bump pi-coupling.md, pin pi, or push.
      console.warn(`[pi-contract] optional AgentSession surfaces missing in installed pi: ${missing.join(", ")}. Picky will fall back via pi-capabilities.ts; review agentd/docs/pi-coupling.md before relying on these.`);
    }
  });

  it("extensionRunner exposes emitUserBash (soft, warn-only)", async () => {
    const session = await createTestSession();
    const runner = (session as unknown as { extensionRunner?: { emitUserBash?: unknown } }).extensionRunner;
    if (!runner || typeof runner.emitUserBash !== "function") {
      console.warn("[pi-contract] extensionRunner.emitUserBash missing in installed pi; user-bash hooks fall back to direct executeBash.");
    }
  });

  it("ModelRuntime keeps the reloadable credential-store bridge required for live OAuth updates", async () => {
    const agentDir = await mkdtemp(join(tmpdir(), "picky-pi-contract-auth-"));
    const modelRuntime = await pi.ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
      allowModelNetwork: false,
    });
    const credentialStore = (modelRuntime as unknown as { credentials?: { store?: { reload?: unknown } } }).credentials?.store;
    expect(typeof credentialStore?.reload, "ModelRuntime.credentials.store.reload must stay available until Pi exposes a public live credential reload API").toBe("function");
  });

  it("AgentSession.state exposes the message array shape pi-sdk-runtime mutates", async () => {
    // Picky's transcript repair and bootstrap injector read/write session.state.messages
    // directly. If pi reshapes the state container, those code paths break silently.
    const session = await createTestSession();
    const state = (session as unknown as { state?: { messages?: unknown } }).state;
    expect(state, "AgentSession.state must exist").toBeDefined();
    expect(Array.isArray(state?.messages) || state?.messages === undefined, "AgentSession.state.messages must be an array (or initially undefined)").toBe(true);
  });
});

async function createTestSession(): Promise<unknown> {
  const cwd = await mkdtemp(join(tmpdir(), "picky-pi-contract-cwd-"));
  const agentDir = await mkdtemp(join(tmpdir(), "picky-pi-contract-agent-"));
  // Use the high-level createAgentSession entry point with isolated cwd and agentDir
  // values so the contract test never loads the user's installed Pi extensions.
  // Pi auto-resolves SessionManager/SettingsManager/ResourceLoader from these paths,
  // keeping the test focused on the surface Picky touches without duplicating the
  // runtime wiring.
  const result = await (pi as unknown as { createAgentSession: (options: { cwd: string; agentDir: string }) => Promise<{ session: unknown }> }).createAgentSession({ cwd, agentDir });
  return result.session;
}

function memberPresent(value: unknown, name: string): boolean {
  if (!value || typeof value !== "object") return false;
  return name in (value as Record<string, unknown>);
}

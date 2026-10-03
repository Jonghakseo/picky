import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { createAgentSessionFromServices, createAgentSessionServices, SettingsManager, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { PiSdkRuntime } from "./pi-sdk-runtime.js";
import type { RuntimeEvent, RuntimeSessionHandle } from "./types.js";

// Real Pi SDK sessions: Pi drains queued follow-ups inside the running turn and expands
// `/skill:` when a message is queued, so these contracts cannot be proven with a fake session.

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  vi.unstubAllEnvs();
});

interface Fixture {
  agentDir: string;
  handle: RuntimeSessionHandle;
  events: RuntimeEvent[];
  requests: string[];
  /** Holds the next model response open until released, so the turn keeps streaming. */
  holdNextResponse(): () => void;
  installSkill(name: string, body: string): Promise<void>;
}

async function fixture(options: { extraExtension?: (pi: ExtensionAPI) => void } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), "picky-plugin-reload-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "home/.pi/agent");
  await mkdir(join(agentDir, "skills"), { recursive: true });
  vi.stubEnv("HOME", join(root, "home"));
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  vi.stubEnv("PI_OFFLINE", "1");
  const requests: string[] = [];
  let gate: Promise<void> | undefined;
  const runtime = new PiSdkRuntime({
    agentDir,
    modelPattern: "reload-offline/finite",
    createServices: (options) => createAgentSessionServices({ ...options, settingsManager: SettingsManager.inMemory({ packages: [], retry: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 100 } }) }),
    createSessionFromServices: async (options) => createAgentSessionFromServices({ ...options, noTools: "builtin" }),
    resourceLoaderOptions: { noExtensions: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi) => {
      pi.registerProvider("reload-offline", { baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "reload-offline", models: [{ id: "finite", name: "Finite", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }], streamSimple(model, context) {
        const last = context.messages.at(-1);
        const content = last && "content" in last ? last.content : "";
        requests.push(typeof content === "string" ? content : content.map((part) => ("text" in part ? part.text : "")).join("\n"));
        const stream = createAssistantMessageEventStream();
        const message: AssistantMessage = { role: "assistant", content: [{ type: "text", text: "Finite reply" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() };
        const held = gate;
        gate = undefined;
        void (async () => {
          stream.push({ type: "start", partial: message });
          await held;
          stream.push({ type: "done", reason: "stop", message });
          stream.end();
        })();
        return stream;
      } });
    }, ...(options.extraExtension ? [options.extraExtension] : [])] },
  });
  const handle = await runtime.prewarm({ cwd: root, sessionId: "picky" });
  cleanups.push(async () => { await handle.dispose?.(); });
  const events: RuntimeEvent[] = [];
  handle.subscribe((event) => events.push(event));
  return {
    agentDir,
    handle,
    events,
    requests,
    holdNextResponse() {
      let release!: () => void;
      gate = new Promise<void>((resolve) => { release = resolve; });
      return release;
    },
    async installSkill(name, body) {
      await mkdir(join(agentDir, "skills", name), { recursive: true });
      await writeFile(join(agentDir, "skills", name, "SKILL.md"), `---\nname: ${name}\ndescription: Fixture skill installed while Picky runs\n---\n\n${body}\n`);
    },
  };
}

const terminalStatuses = (events: RuntimeEvent[]) => events.filter((event) => event.type === "status" && ["completed", "failed", "cancelled"].includes(event.status) && !event.noTurnRan);

it("delivers a follow-up queued during a response after the plugin reload, so a new skill expands", async () => {
  const f = await fixture();
  const release = f.holdNextResponse();
  await f.handle.followUp({ text: "first task", imagePaths: [] });
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
  expect(f.handle.isStreaming).toBe(true);

  await f.installSkill("fresh-skill", "FRESH SKILL BODY");
  await expect(f.handle.requestResourceReload!()).resolves.toBe("deferred");
  await f.handle.followUp({ text: "/skill:fresh-skill do the thing", imagePaths: [] });

  // The held follow-up stays visible as queued input while the first response continues.
  expect(f.handle.getFollowUpMessages()).toEqual(["/skill:fresh-skill do the thing"]);
  release();

  await vi.waitFor(() => expect(f.requests).toHaveLength(2));
  expect(f.requests[1]).toContain("FRESH SKILL BODY");
  expect(f.requests[1]).not.toContain("/skill:fresh-skill");
  await vi.waitFor(() => expect(f.handle.isStreaming).toBe(false));
  expect(f.handle.hasPendingResourceReload).toBe(false);
  // Nothing was aborted, and the first response did not end the run while input was held.
  expect(f.events.some((event) => event.type === "status" && event.status === "cancelled")).toBe(false);
  const reloadedAt = f.events.findIndex((event) => event.type === "resources_reloaded");
  expect(reloadedAt).toBeGreaterThan(0);
  expect(terminalStatuses(f.events.slice(0, reloadedAt))).toEqual([]);
  expect(f.events.slice(0, reloadedAt)).toContainEqual(expect.objectContaining({ type: "status", status: "running", summary: "Queued input pending" }));
});

it("reloads an idle session silently so the next message sees a new skill", async () => {
  const f = await fixture();
  await f.installSkill("idle-skill", "IDLE SKILL BODY");

  await expect(f.handle.requestResourceReload!()).resolves.toBe("reloaded");
  // No visible turn: the card must not flash running/completed for a background reload.
  expect(f.events.filter((event) => event.type === "status")).toEqual([]);

  await f.handle.followUp({ text: "/skill:idle-skill go", imagePaths: [] });
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
  expect(f.requests[0]).toContain("IDLE SKILL BODY");
});

it("keeps steering in the current turn while a plugin reload is pending", async () => {
  const f = await fixture();
  const release = f.holdNextResponse();
  await f.handle.followUp({ text: "first task", imagePaths: [] });
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));

  await f.installSkill("late-skill", "LATE SKILL BODY");
  await f.handle.requestResourceReload!();
  await f.handle.steer({ text: "focus on the tests", imagePaths: [] });

  // Steering went to Pi right away, not to the held follow-up queue.
  expect(f.handle.getSteeringMessages()).toEqual(["focus on the tests"]);
  expect(f.handle.getFollowUpMessages()).toEqual([]);
  release();
  await vi.waitFor(() => expect(f.requests).toHaveLength(2));
  expect(f.requests[1]).toContain("focus on the tests");
  await vi.waitFor(() => expect(f.handle.hasPendingResourceReload).toBe(false));
});

it("drops held follow-ups on a full abort, as the main agent's push-to-talk abort does", async () => {
  const f = await fixture();
  const release = f.holdNextResponse();
  await f.handle.followUp({ text: "first task", imagePaths: [] });
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
  await f.installSkill("cancel-skill", "CANCEL SKILL BODY");
  await f.handle.requestResourceReload!();
  await f.handle.followUp({ text: "/skill:cancel-skill never", imagePaths: [] });
  expect(f.handle.getFollowUpMessages()).toEqual(["/skill:cancel-skill never"]);

  // Pi's abort waits for the in-flight stream to end, so release the held response after it starts.
  const aborted = f.handle.abort();
  release();
  await aborted;

  await vi.waitFor(() => expect(f.handle.hasPendingResourceReload).toBe(false));
  expect(f.handle.getFollowUpMessages()).toEqual([]);
  expect(f.requests).toHaveLength(1);
});

it("keeps extension greetings out of the transcript during a background plugin reload", async () => {
  const f = await fixture({ extraExtension: (pi) => {
    pi.on("session_start", async (_event, ctx) => {
      ctx.ui.notify("[greeter] loaded 5 hook(s)", "info");
      ctx.ui.notify("[greeter] settings could not be parsed", "warning");
    });
  } });
  const notifications = () => f.events.flatMap((event) => (
    event.type === "extension_ui" && event.request.method === "notify" ? [event.request.prompt] : []
  ));
  f.events.length = 0;

  await expect(f.handle.requestResourceReload!()).resolves.toBe("reloaded");
  // The background reload drops the greeting but still reports the problem.
  expect(notifications()).toEqual(["[greeter] settings could not be parsed"]);

  f.events.length = 0;
  await f.handle.followUp({ text: "/reload", imagePaths: [] });
  // A reload the user typed shows everything the extension says.
  await vi.waitFor(() => expect(notifications()).toEqual([
    "[greeter] loaded 5 hook(s)",
    "[greeter] settings could not be parsed",
  ]));
});

it("shows an extension message whose text matches a queued follow-up the user removed", async () => {
  let extensionApi: ExtensionAPI | undefined;
  const f = await fixture({ extraExtension: (pi) => { extensionApi = pi; } });
  const release = f.holdNextResponse();
  await f.handle.followUp({ text: "first task", imagePaths: [] });
  await vi.waitFor(() => expect(f.requests).toHaveLength(1));
  await f.handle.followUp({ text: "check the deploy logs", imagePaths: [] });
  expect(f.handle.getFollowUpMessages()).toEqual(["check the deploy logs"]);

  // The user deletes the queued follow-up, then schedules the same words for later.
  expect(f.handle.removeQueuedMessage!("followUp", 0)).toBe(true);
  release();
  await vi.waitFor(() => expect(f.handle.isStreaming).toBe(false));
  f.events.length = 0;

  // delayed-action fires and submits the text as an extension user message.
  await extensionApi!.sendUserMessage("check the deploy logs");
  await vi.waitFor(() => expect(f.events).toContainEqual(expect.objectContaining({
    type: "input_message", role: "user", text: "check the deploy logs", originatedBy: "pi_extension",
  })));
  expect(f.events).not.toContainEqual(expect.objectContaining({ type: "input_delivery", text: "check the deploy logs" }));
});

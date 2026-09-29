/**
 * vcc-ko compaction contract against Picky's bundled Pi SDK and PiSdkRuntime.
 *
 * Installing the curated vcc-ko package replaces Pi's compaction for Picky's
 * main agent (idle `compact()`) and for Pickles (threshold compaction). Run it
 * explicitly with the package directory that users would install:
 *
 * PICKY_TEST_VCC_KO_ROOT=$HOME/.pi/agent/npm/node_modules/@ryan_nookpi/pi-extension-vcc-ko \
 *   pnpm --dir agentd exec vitest run src/runtime/vcc-ko-compaction.integration.test.ts
 *
 * The package is copied below an isolated HOME and resolves peers through
 * `agentd/node_modules`, so no user Pi settings, sessions, or configs are read.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const vccRoot = process.env.PICKY_TEST_VCC_KO_ROOT?.trim();
const piAiEntry = resolve(repositoryRoot, "agentd/node_modules/@earendil-works/pi-ai/dist/index.js");
const require = createRequire(import.meta.url);
const tsxLoader = join(dirname(require.resolve("tsx/package.json")), "dist/loader.mjs");
const temporaryRoots: string[] = [];
const HARNESS_TIMEOUT_MS = 60_000;

async function run(command: string, args: string[], options: { cwd: string; env: NodeJS.ProcessEnv }): Promise<string> {
  return await new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => child.kill("SIGKILL"), HARNESS_TIMEOUT_MS);
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => { stdout += chunk; });
    child.stderr?.on("data", (chunk: string) => { stderr += chunk; });
    child.once("error", (error) => {
      if (child.pid === undefined) {
        clearTimeout(timeout);
        rejectRun(error);
      }
    });
    child.once("close", (code, signal) => {
      clearTimeout(timeout);
      if (code === 0) resolveRun(stdout);
      else rejectRun(new Error(`vcc-ko harness exited code=${code} signal=${signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    });
  });
}

const harnessSource = String.raw`
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { VERSION } from "@earendil-works/pi-coding-agent";
import { PiSdkRuntime } from ${JSON.stringify(resolve(repositoryRoot, "agentd/src/runtime/pi-sdk-runtime.ts"))};

const root = process.env.PICKY_VCC_ROOT;
const home = join(root, "home");
const agentDir = join(home, ".pi", "agent");
const cwd = join(root, "workspace");
const callsPath = join(root, "provider-calls.jsonl");
mkdirSync(cwd, { recursive: true });
writeFileSync(join(agentDir, "settings.json"), JSON.stringify({
  packages: [],
  extensions: [join(root, "vcc-ko", "index.ts"), join(root, "offline-provider.mjs")],
  defaultProvider: "picky-vcc-offline",
  defaultModel: "offline",
  compaction: { enabled: true },
}));

const calls = () => existsSync(callsPath) ? readFileSync(callsPath, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)) : [];
const prompt = (text) => ({ text, imagePaths: [] });
const sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));

function collect(handle) {
  const events = [];
  const unsubscribe = handle.subscribe((event) => events.push(event));
  return { events, unsubscribe };
}

async function waitFor(events, predicate, label) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const found = events.find(predicate);
    if (found) return found;
    await sleep(25);
  }
  throw new Error("timed out waiting for " + label + ": " + JSON.stringify(events.filter((event) => event.type === "status" || event.type === "log").slice(-6)));
}

const completedTurn = (marker) => (event) => event.type === "status" && event.status === "completed" && String(event.finalAnswer ?? "").includes(marker + "_DONE");

const runtime = new PiSdkRuntime({ agentDir, disableBlockingDialogs: true });
const handle = await runtime.prewarm({ cwd, sessionId: "picky-vcc" });
const observed = collect(handle);

// Each request carries ~10k tokens so the kept tail cannot swallow the whole session.
const padding = " log line about the rollout".repeat(1500);
for (const marker of ["TURN_ONE", "TURN_TWO", "TURN_THREE", "TURN_FOUR", "TURN_FIVE"]) {
  await handle.followUp(prompt(marker + " please remember the deploy target is staging-eu." + padding));
  await waitFor(observed.events, completedTurn(marker), marker);
}

const commands = (await handle.listSlashCommands()).map((command) => command.name);
if (!commands.includes("pi-vcc-ko")) {
  const loaded = handle.runtime?.session?.resourceLoader?.getExtensions?.();
  throw new Error("vcc-ko did not load: " + JSON.stringify({ commands, extensions: loaded?.extensions?.map((extension) => extension.path), errors: loaded?.errors }));
}

// Main agent idle compaction path: MainAgentCoordinator calls handle.compact().
const callsBeforeManual = calls().length;
await handle.compact();
const manual = await waitFor(observed.events, (event) => event.type === "status" && event.compactionCompleted, "manual compaction");
const summary = manual.compaction?.summary ?? "";
if (!summary.trim()) throw new Error("manual compaction produced no summary: " + JSON.stringify(manual));
if (calls().length !== callsBeforeManual) throw new Error("vcc-ko compaction called the model: " + JSON.stringify(calls().slice(callsBeforeManual)));

// Pickle threshold compaction: a turn that reports a nearly full context.
observed.events.length = 0;
for (const marker of ["TURN_ONE", "TURN_TWO", "TURN_THREE"]) {
  await handle.followUp(prompt(marker + " more rollout notes." + padding));
  await waitFor(observed.events, completedTurn(marker), marker + " after manual compaction");
}
observed.events.length = 0;
await handle.followUp(prompt("THRESHOLD_TURN fill the context"));
await waitFor(observed.events, completedTurn("THRESHOLD_TURN"), "threshold turn");
const threshold = await waitFor(observed.events, (event) => event.type === "status" && event.compactionCompleted, "threshold compaction");
const callsAfterThreshold = calls().length;
await sleep(1_500);
const extraCalls = calls().slice(callsAfterThreshold);
if (extraCalls.length > 0) throw new Error("vcc-ko continued after threshold compaction: " + JSON.stringify(extraCalls));
const sessionText = readFileSync(handle.getSessionFilePath(), "utf8");
if (!sessionText.includes('"type":"compaction"')) throw new Error("compaction was not persisted to the Pi session");

// The session must still accept and answer the next request after compaction.
await handle.followUp(prompt("AFTER_COMPACTION what is the deploy target"));
await waitFor(observed.events, completedTurn("AFTER_COMPACTION"), "turn after compaction");

const configPath = join(agentDir, "pi-vcc-ko-config.json");
observed.unsubscribe();
await handle.dispose?.();
console.log("PICKY_VCC_KO_OK " + JSON.stringify({
  piVersion: VERSION,
  manualSummaryChars: summary.length,
  thresholdReason: threshold.compactionReason ?? null,
  isolatedConfig: existsSync(configPath),
}));
process.exit(0);
`;

const providerSource = String.raw`
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { createAssistantMessageEventStream } from ${JSON.stringify(piAiEntry)};
export default function (pi) {
  pi.registerProvider("picky-vcc-offline", {
    baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "picky-vcc-offline-api",
    models: [{ id: "offline", name: "Offline", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const user = [...context.messages].reverse().find((message) => message.role === "user");
      const text = JSON.stringify(user?.content ?? "");
      const marker = text.match(/(TURN_ONE|TURN_TWO|TURN_THREE|TURN_FOUR|TURN_FIVE|THRESHOLD_TURN|AFTER_COMPACTION)/)?.[1] ?? "UNKNOWN";
      appendFileSync(join(process.env.PICKY_VCC_ROOT, "provider-calls.jsonl"), JSON.stringify({ marker, messages: context.messages.length }) + "\n");
      const input = marker === "THRESHOLD_TURN" ? 95000 : 1200;
      const message = { role: "assistant", content: [{ type: "text", text: marker + "_DONE" }], api: model.api, provider: model.provider, model: model.id,
        usage: { input, output: 20, cacheRead: 0, cacheWrite: 0, totalTokens: input + 20,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() };
      stream.push({ type: "start", partial: message });
      queueMicrotask(() => { stream.push({ type: "done", reason: "stop", message }); stream.end(); });
      return stream;
    },
  });
}
`;

describe("vcc-ko compaction integration", () => {
  afterEach(async () => {
    await Promise.all(temporaryRoots.splice(0).map((path) => rm(path, { recursive: true, force: true })));
  });

  (vccRoot ? it : it.skip)("replaces Picky compaction without model calls, auto-continue, or user config access", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-vcc-ko-"));
    temporaryRoots.push(root);
    // The installed package itself lives under node_modules; only skip nested dependency trees.
    await cp(vccRoot!, join(root, "vcc-ko"), { recursive: true, filter: (path) => !relative(vccRoot!, path).split(sep).includes("node_modules") });
    await symlink(resolve(repositoryRoot, "agentd/node_modules"), join(root, "node_modules"));
    await mkdir(join(root, "home", ".pi", "agent"), { recursive: true });
    await Promise.all([
      writeFile(join(root, "package.json"), JSON.stringify({ type: "module" })),
      writeFile(join(root, "offline-provider.mjs"), providerSource),
      writeFile(join(root, "harness.ts"), harnessSource),
    ]);

    const stdout = await run(process.execPath, ["--import", tsxLoader, join(root, "harness.ts")], {
      cwd: repositoryRoot,
      env: { ...process.env, HOME: join(root, "home"), PI_CODING_AGENT_DIR: join(root, "home", ".pi", "agent"), PI_OFFLINE: "1", PICKY_VCC_ROOT: root },
    });
    expect(stdout).toContain("PICKY_VCC_KO_OK");
    expect(stdout).toContain('"isolatedConfig":true');
    expect(stdout).toContain('"thresholdReason":"threshold"');
  }, 75_000);

  it("points at a real vcc-ko package when PICKY_TEST_VCC_KO_ROOT is supplied", () => {
    if (!vccRoot) return;
    expect(existsSync(join(vccRoot, "index.ts"))).toBe(true);
  });
});

/**
 * Real extension safety contract against Picky's bundled Pi SDK.
 *
 * Run explicitly with the extension checkout to exercise this test:
 * PICKY_TEST_EXTENSION_ROOT=/Users/creatrip/Documents/pi-extension \
 *   pnpm --dir agentd exec vitest run src/runtime/extension-safety.integration.test.ts
 *
 * The ordinary suite skips this optional checkout-dependent smoke test. It copies
 * the checked-out extensions below an isolated temporary root and resolves all
 * peer dependencies through `agentd/node_modules`, so the runtime under test is
 * Picky's pinned Pi SDK rather than the extension checkout's dependencies.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const extensionRoot = process.env.PICKY_TEST_EXTENSION_ROOT?.trim();
const piAiEntry = resolve(repositoryRoot, "agentd/node_modules/@earendil-works/pi-ai/dist/index.js");
const require = createRequire(import.meta.url);
const tsxLoader = join(dirname(require.resolve("tsx/package.json")), "dist/loader.mjs");
const temporaryRoots: string[] = [];

const HARNESS_TIMEOUT_MS = 60_000;
const HARNESS_FORCE_KILL_GRACE_MS = 1_000;

async function run(command: string, args: string[], options: { cwd: string; env: NodeJS.ProcessEnv }): Promise<{ stdout: string; stderr: string }> {
  return await new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let forceKill: NodeJS.Timeout | undefined;
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      forceKill = setTimeout(() => child.kill("SIGKILL"), HARNESS_FORCE_KILL_GRACE_MS);
    }, HARNESS_TIMEOUT_MS);
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => { stdout += chunk; });
    child.stderr?.on("data", (chunk: string) => { stderr += chunk; });
    child.once("error", (error) => {
      // A failed spawn has no child to wait for. A running child still settles only
      // from close, so afterEach never removes its temporary extension root early.
      if (child.pid === undefined) {
        clearTimeout(timeout);
        rejectRun(error);
      }
    });
    child.once("close", (code, signal) => {
      clearTimeout(timeout);
      if (forceKill) clearTimeout(forceKill);
      if (timedOut) {
        rejectRun(new Error(`integration harness timed out after ${HARNESS_TIMEOUT_MS}ms and exited code=${code} signal=${signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      } else if (code === 0) {
        resolveRun({ stdout, stderr });
      } else {
        rejectRun(new Error(`integration harness exited code=${code} signal=${signal}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }
    });
  });
}

const harnessSource = String.raw`
import { createConnection } from "node:net";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { VERSION } from "@earendil-works/pi-coding-agent";
import { PiSdkRuntime } from ${JSON.stringify(resolve(repositoryRoot, "agentd/src/runtime/pi-sdk-runtime.ts"))};
import { PiExtensionCommandRunner } from ${JSON.stringify(resolve(repositoryRoot, "agentd/src/runtime/pi-extension-command-runner.ts"))};
import { snapshotPiSessionFile } from ${JSON.stringify(resolve(repositoryRoot, "agentd/src/application/pinned-session-source.ts"))};

async function main() {
const root = process.env.PICKY_EXTENSION_SAFETY_ROOT;
if (!root) throw new Error("missing isolated root");
if (VERSION !== "0.84.4") throw new Error("expected Picky Pi 0.84.4, received " + VERSION);
const agentDir = join(root, "home", ".pi", "agent");
const cwd = join(root, "workspace");
mkdirSync(cwd, { recursive: true });
const settings = {
  packages: [],
  extensions: [
    join(root, "extensions", "memory-layer", "index.ts"),
    join(root, "extensions", "cron", "index.ts"),
    join(root, "offline-provider.mjs"),
  ],
  defaultProvider: "picky-extension-safety",
  defaultModel: "offline",
  autoCompaction: { enabled: false },
};
writeFileSync(join(agentDir, "settings.json"), JSON.stringify(settings));

const launchctlLog = join(root, "launchctl.log");
const fakeLaunchctl = join(root, "fake-launchctl.mjs");
writeFileSync(fakeLaunchctl, "#!/bin/sh\\nprintf '%s\\n' \\\"$*\\\" >> \\\"$PICKY_FAKE_LAUNCHCTL_LOG\\\"\\nexit 1\\n", { mode: 0o755 });
const update = await new PiExtensionCommandRunner().run({
  agentDir,
  extensionPath: join(root, "extensions", "cron", "index.ts"),
  command: "update",
  environment: {
    ...process.env,
    HOME: join(root, "home"),
    PI_CODING_AGENT_DIR: agentDir,
    PI_CRON_SUPPRESS_AUTO_UPGRADE: "1",
    PI_CRON_LAUNCHD_PLIST_PATH: join(root, "LaunchAgents", "dev.pi.cron.plist"),
    PI_CRON_LAUNCHCTL_BIN: fakeLaunchctl,
    PICKY_FAKE_LAUNCHCTL_LOG: launchctlLog,
  },
});
if (!update.ok || !update.notifications.includes("cron daemon is stopped; leaving it stopped")) {
  throw new Error("PiExtensionCommandRunner did not receive cron update-runtime completion: " + JSON.stringify(update));
}
if (existsSync(launchctlLog)) {
  throw new Error("stopped update-runtime invoked launchctl: " + readFileSync(launchctlLog, "utf8"));
}
const daemonPidPath = join(agentDir, "cron", "daemon.pid");
const daemonOwnerPath = join(agentDir, "cron", "daemon-owner.json");
if (existsSync(daemonPidPath) || existsSync(daemonOwnerPath)) {
  const daemonRecord = existsSync(daemonOwnerPath) ? daemonOwnerPath : daemonPidPath;
  throw new Error("stopped update-runtime started a cron daemon: " + readFileSync(daemonRecord, "utf8"));
}

const runtime = new PiSdkRuntime({ agentDir, disableBlockingDialogs: true });
const prompt = (text) => ({ text, imagePaths: [] });
const sessionFile = (handle) => handle.getSessionFilePath?.();

function turn(handle, text, submit = true) {
  return new Promise(async (resolveTurn, rejectTurn) => {
    let output = "";
    const timeout = setTimeout(() => {
      unsubscribe();
      rejectTurn(new Error("timed out waiting for Pi turn " + text + "; output=" + output));
    }, 15_000);
    const unsubscribe = handle.subscribe((event) => {
      if (event.type === "assistant_delta") output += event.delta;
      if (event.type === "status" && event.status === "failed") {
        clearTimeout(timeout);
        unsubscribe();
        rejectTurn(new Error("Pi failed " + text + ": " + (event.summary ?? "unknown") + "; output=" + output));
      }
      if (event.type === "status" && event.status === "completed") {
        clearTimeout(timeout);
        unsubscribe();
        resolveTurn(output + (event.finalAnswer ?? ""));
      }
    });
    try {
      if (submit) await handle.followUp(prompt(text));
    } catch (error) {
      clearTimeout(timeout);
      unsubscribe();
      rejectTurn(error);
    }
  });
}

function ownerFor(sessionId) {
  const key = createHash("sha256").update(sessionId).digest("hex").slice(0, 24);
  const path = join(agentDir, "cron", "sessions", key + ".json");
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : undefined;
}

async function waitForOwner(sessionId, previousGeneration) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const owner = ownerFor(sessionId);
    if (owner && (!previousGeneration || owner.generation !== previousGeneration)) return owner;
    await new Promise((resolveWait) => setTimeout(resolveWait, 25));
  }
  const sessionsDir = join(agentDir, "cron", "sessions");
  throw new Error("cron owner missing or unchanged for " + sessionId + ": " + (existsSync(sessionsDir) ? JSON.stringify(readdirSync(sessionsDir)) : "registry directory absent"));
}

function deliver(owner, id, message) {
  return new Promise((resolveDelivery, rejectDelivery) => {
    const socket = createConnection(owner.endpoint);
    let response = "";
    socket.setEncoding("utf8");
    socket.once("error", rejectDelivery);
    socket.on("data", (chunk) => { response += chunk; });
    socket.once("close", () => {
      try {
        resolveDelivery(JSON.parse(response));
      } catch (error) {
        rejectDelivery(new Error("invalid cron bridge response " + response + ": " + error));
      }
    });
    socket.once("connect", () => socket.end(JSON.stringify({
      id,
      generation: owner.generation,
      sessionId: owner.sessionId,
      sessionFile: owner.sessionFile,
      prompt: message,
    }) + "\n"));
  });
}

const first = await runtime.prewarm({ cwd, sessionId: "picky-first" });
const seeded = await turn(first, "MEMORY_SEED");
if (!seeded.includes("SEED_DONE")) throw new Error("memory seed did not complete: " + seeded);
const firstFile = sessionFile(first);
if (!firstFile || !existsSync(firstFile)) throw new Error("Picky did not persist the first Pi session");
const firstHeader = JSON.parse(readFileSync(firstFile, "utf8").split("\n", 1)[0]);
if (typeof firstHeader.id !== "string") throw new Error("missing first session UUID");
const transcript = readFileSync(firstFile, "utf8");
if (!transcript.includes("memory-layer-agent") || !transcript.includes("AGENT_SENTINEL")) {
  throw new Error("remember tool was not persisted to the real Pi transcript");
}

const ownerBeforeReload = await waitForOwner(firstHeader.id);
if (ownerBeforeReload.state !== "active") throw new Error("cron owner was not active: " + JSON.stringify(ownerBeforeReload));
first.setExternalDeliveryPaused(true);
const paused = await deliver(ownerBeforeReload, "paused-before-reload", "CRON_PAUSED_MUST_NOT_RUN");
if (!paused.deferred || paused.ok) throw new Error("PTT pause accepted cron input: " + JSON.stringify(paused));
await first.followUp(prompt("/reload"));
const liveOwner = await waitForOwner(firstHeader.id, ownerBeforeReload.generation);
if (liveOwner.state !== "active") throw new Error("cron owner did not transfer after Pi reload: " + JSON.stringify(liveOwner));
const pausedAfterReload = await deliver(liveOwner, "paused-after-reload", "CRON_PAUSED_MUST_NOT_RUN");
if (!pausedAfterReload.deferred || pausedAfterReload.ok) throw new Error("reload lost PTT pause: " + JSON.stringify(pausedAfterReload));
if (readFileSync(firstFile, "utf8").includes("CRON_PAUSED_MUST_NOT_RUN")) throw new Error("paused cron input reached persisted session");
first.setExternalDeliveryPaused(false);
// Observe only. The bridge is the sole input producer for this turn.
const liveTurn = turn(first, "CRON_LIVE", false);
const delivered = await deliver(liveOwner, "live-delivery", "CRON_LIVE");
if (delivered.outcome !== "queued") throw new Error("cron did not queue into the live Picky session: " + JSON.stringify(delivered));
const liveOutput = await liveTurn;
if (!liveOutput.includes("CRON_LIVE_DONE")) throw new Error("live cron prompt was not executed: " + liveOutput);

const copied = await snapshotPiSessionFile(firstFile, "picky-fork-file");
const copiedHeader = JSON.parse(readFileSync(copied, "utf8").split("\n", 1)[0]);
if (copiedHeader.id === firstHeader.id || typeof copiedHeader.id !== "string") {
  throw new Error("Picky snapshot retained its source Pi session UUID");
}
const fork = await runtime.resume(copied, { cwd, sessionId: "picky-fork" });
const forkOutput = await turn(fork, "FORK_CHECK");
if (!forkOutput.includes("FORK_MEMORY=false")) throw new Error("fork inherited source agent memory: " + forkOutput);
await fork.dispose?.();

await first.dispose?.();
let staleAccepted = false;
try {
  await deliver(liveOwner, "must-not-deliver", "CRON_MUST_NOT_DELIVER");
  staleAccepted = true;
} catch {}
if (staleAccepted) throw new Error("disposed runtime still accepted cron bridge delivery");

const successor = await runtime.resume(firstFile, { cwd, sessionId: "picky-successor" });
const successorOwner = await waitForOwner(firstHeader.id);
if (successorOwner.state !== "active" || successorOwner.generation === liveOwner.generation) {
  throw new Error("same-session successor did not replace the draining cron bridge: " + JSON.stringify(successorOwner));
}
const successorTurn = turn(successor, "CRON_SUCCESSOR", false);
const successorDelivery = await deliver(successorOwner, "successor-delivery", "CRON_SUCCESSOR");
if (successorDelivery.outcome !== "queued") throw new Error("successor cron delivery was not queued: " + JSON.stringify(successorDelivery));
const successorOutput = await successorTurn;
if (!successorOutput.includes("CRON_SUCCESSOR_DONE")) throw new Error("same-session successor did not receive cron input: " + successorOutput);
const restoredOutput = await turn(successor, "SOURCE_CHECK");
if (!restoredOutput.includes("SOURCE_MEMORY=true")) throw new Error("same session did not restore persisted agent memory: " + restoredOutput);
await successor.dispose?.();
console.log("PICKY_EXTENSION_SAFETY_OK " + JSON.stringify({ piVersion: VERSION, sourceSessionId: firstHeader.id, forkSessionId: copiedHeader.id }));
process.exit(0);
}
void main().catch((error) => {
  console.error(error instanceof Error ? error.stack : error);
  process.exit(1);
});
`;

const providerSource = String.raw`
import { createAssistantMessageEventStream } from ${JSON.stringify(piAiEntry)};
export default function (pi) {
  pi.registerProvider("picky-extension-safety", {
    baseUrl: "http://127.0.0.1:1", apiKey: "offline", api: "picky-extension-safety-api",
    models: [{ id: "offline", name: "Offline", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const user = [...context.messages].reverse().find((message) => message.role === "user");
      const text = JSON.stringify(user?.content ?? "");
      const marker = text.match(/(MEMORY_SEED|FORK_CHECK|SOURCE_CHECK|CRON_LIVE|CRON_SUCCESSOR)/)?.[1] ?? "UNKNOWN";
      const remembered = String(context.systemPrompt ?? "").includes("[Memory Layer]");
      const alreadyCalledRemember = JSON.stringify(context.messages).includes('"name":"remember"');
      const content = marker === "MEMORY_SEED" && !alreadyCalledRemember
        ? [{ type: "toolCall", id: "remember-sentinel", name: "remember", arguments: {
          scope: "agent", tier: "log", topic: "general", title: "sentinel", content: "AGENT_SENTINEL",
        } }]
        : [{ type: "text", text: marker === "MEMORY_SEED" ? "SEED_DONE"
          : marker === "FORK_CHECK" ? "FORK_MEMORY=" + remembered
          : marker === "SOURCE_CHECK" ? "SOURCE_MEMORY=" + remembered
          : marker + "_DONE" }];
      const stopReason = content[0].type === "toolCall" ? "toolUse" : "stop";
      const message = { role: "assistant", content, api: model.api, provider: model.provider, model: model.id,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason, timestamp: Date.now() };
      stream.push({ type: "start", partial: message });
      queueMicrotask(() => { stream.push({ type: "done", reason: stopReason, message }); stream.end(); });
      return stream;
    },
  });
}
`;

describe("extension safety integration", () => {
  afterEach(async () => {
    await Promise.all(temporaryRoots.splice(0).map((path) => rm(path, { recursive: true, force: true })));
  });

  (extensionRoot ? it : it.skip)("loads memory-layer and cron through Pi 0.84.4 without cross-session memory or stale bridge delivery", async () => {
    const packagesRoot = join(extensionRoot!, "packages");
    const sourceMemory = join(packagesRoot, "memory-layer");
    const sourceCron = join(packagesRoot, "cron");
    const root = await mkdtemp(join(tmpdir(), "picky-extension-safety-"));
    temporaryRoots.push(root);

    await cp(sourceMemory, join(root, "extensions", "memory-layer"), { recursive: true, filter: (path) => !path.includes("/node_modules/") });
    await cp(sourceCron, join(root, "extensions", "cron"), { recursive: true, filter: (path) => !path.includes("/node_modules/") });
    await symlink(resolve(repositoryRoot, "agentd/node_modules"), join(root, "node_modules"));
    await mkdir(join(root, "home", ".pi", "agent"), { recursive: true });
    await Promise.all([
      writeFile(join(root, "package.json"), JSON.stringify({ type: "module" })),
      writeFile(join(root, "offline-provider.mjs"), providerSource),
      writeFile(join(root, "harness.ts"), harnessSource),
    ]);

    const result = await run(process.execPath, ["--import", tsxLoader, join(root, "harness.ts")], {
      cwd: repositoryRoot,
      env: {
        ...process.env,
        HOME: join(root, "home"),
        PI_CODING_AGENT_DIR: join(root, "home", ".pi", "agent"),
        PI_OFFLINE: "1",
        PI_CRON_SUPPRESS_AUTO_UPGRADE: "1",
        PICKY_EXTENSION_SAFETY_ROOT: root,
      },
    });
    expect(result.stdout).toContain("PICKY_EXTENSION_SAFETY_OK");
    expect(result.stdout).toContain('"piVersion":"0.84.4"');
  }, 75_000);

  it("requires a real checkout when PICKY_TEST_EXTENSION_ROOT is supplied", () => {
    if (!extensionRoot) return;
    expect(existsSync(join(extensionRoot, "packages", "memory-layer", "index.ts"))).toBe(true);
    expect(existsSync(join(extensionRoot, "packages", "cron", "index.ts"))).toBe(true);
  });
});

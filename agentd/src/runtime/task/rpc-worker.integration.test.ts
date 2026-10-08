/**
 * Proof against a real Pi RPC child process started from agentd's bundled Pi CLI, the vendored
 * bash-async extension, and a fake provider. No network, no user configuration: the child runs with
 * an exact environment and a throwaway HOME. Ported from the Task extension's runtime PoC.
 */
import { existsSync, watch } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, expect, it, vi } from "vitest";
import { createRpcWorker, resolveCliPath } from "./rpc-worker.js";
import type { TaskReport, TaskWorker } from "./types.js";

const here = dirname(fileURLToPath(import.meta.url));
const fakeProvider = join(here, "fixtures", "fake-provider.mjs");
const fakeDelegation = join(here, "fixtures", "fake-delegation-tool.mjs");
const bashAsync = fileURLToPath(new URL("../../../vendor/async-task-providers/packages/bash-async/index.ts", import.meta.url));

const selection = (model: string, thinking: "off" | "low" = "off") => ({ provider: "task-fake", model, thinking } as const);

interface Marker {
  kind?: string;
  verb?: string;
  model?: string;
  text?: string;
  toolResult?: { name?: string; isError?: boolean; text?: string };
}

async function waitForFile(file: string, matches: (text: string) => boolean, timeoutMs = 30_000): Promise<string> {
  const read = async () => readFile(file, "utf8").catch(() => "");
  const current = await read();
  if (matches(current)) return current;
  return new Promise<string>((resolve, reject) => {
    let done = false;
    const finish = (error: Error | undefined, value = "") => {
      if (done) return;
      done = true;
      clearInterval(recheck);
      clearTimeout(timer);
      watcher?.close();
      if (error) reject(error);
      else resolve(value);
    };
    const check = () => void read().then((text) => { if (matches(text)) finish(undefined, text); });
    // fs.watch can coalesce or miss an append on macOS, so a slow re-read backs it up.
    const recheck = setInterval(check, 150);
    const timer = setTimeout(() => finish(new Error(`Timed out waiting for ${file}`)), timeoutMs);
    let watcher: ReturnType<typeof watch> | undefined;
    try { watcher = watch(file, check); } catch { /* The interval still picks the file up. */ }
    check();
  });
}

const parseMarkers = (text: string): Marker[] => text.split("\n").filter((line) => line.trim()).map((line) => {
  try { return JSON.parse(line) as Marker; } catch { return {}; }
});

async function waitForMarker(file: string, matches: (marker: Marker) => boolean): Promise<Marker> {
  const text = await waitForFile(file, (content) => parseMarkers(content).some(matches));
  return parseMarkers(text).find(matches)!;
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

interface Harness {
  worker: TaskWorker;
  root: string;
  markers: string;
  jobLog(name: string): string;
  delegationMarker: string;
  reports: TaskReport[];
  activity: string[];
  exits: Array<string | undefined>;
  errors: string[];
}

let active: Harness | undefined;

afterEach(async () => {
  const harness = active;
  active = undefined;
  if (!harness) return;
  await harness.worker.stop().catch(() => false);
  await rm(harness.root, { recursive: true, force: true });
});

function isolatedEnv(root: string, extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    HOME: join(root, "home"),
    PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    TMPDIR: join(root, "tmp"),
    PI_CODING_AGENT_DIR: join(root, "agent"),
    PI_OFFLINE: "1",
    NO_COLOR: "1",
    ...extra,
  };
}

async function createHarness(): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "picky-task-poc-"));
  const markers = join(root, "markers.jsonl");
  const contextFile = join(root, "context.json");
  const delegationMarker = join(root, "delegated.txt");
  await Promise.all(["home", "work", "agent", "sessions", "tmp"].map((dir) => mkdir(join(root, dir), { recursive: true })));
  await writeFile(markers, "");
  await writeFile(contextFile, JSON.stringify({ brief: "poc brief", entries: [] }));
  const harness: Omit<Harness, "worker"> = {
    root, markers, delegationMarker, reports: [], activity: [], exits: [], errors: [],
    jobLog: (name: string) => join(root, `${name}.log`),
  };
  const worker = createRpcWorker(
    {
      taskId: "task-poc",
      cwd: join(root, "work"),
      sessionFile: join(root, "sessions", "poc.jsonl"),
      contextFile,
      readonly: false,
      requestTimeoutMs: 45_000,
      env: isolatedEnv(root, {
        PI_BASH_ASYNC_SYNC_WINDOW_MS: "0",
        PICKY_TASK_TEST_MARKERS: markers,
        PICKY_TASK_TEST_DELEGATION: delegationMarker,
      }),
      extraArgs: [
        "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-mcp", "--no-context-files",
        "--extension", fakeProvider, "--extension", fakeDelegation, "--extension", bashAsync,
        "--tools", "+bash_async",
      ],
    },
    {
      onReport: (report) => harness.reports.push(report),
      onActivity: (state) => harness.activity.push(state),
      onExit: (error) => harness.exits.push(error),
      onError: (error) => harness.errors.push(error),
    },
  );
  active = { ...harness, worker };
  return active;
}

function pidFrom(text: string): number {
  const match = /PID=(\d+)/.exec(text);
  if (!match) throw new Error(`No PID in job log: ${text}`);
  return Number(match[1]);
}

const isReportResult = (marker: Marker, failed: boolean): boolean =>
  marker.toolResult?.name === "task_report" && marker.toolResult.isError === failed;

it("resolves the Pi CLI bundled with agentd, not one from the user's PATH", () => {
  const cli = resolveCliPath();
  expect(cli.startsWith(fileURLToPath(new URL("../../../node_modules/", import.meta.url)))).toBe(true);
  expect(existsSync(cli)).toBe(true);
});

it("keeps one RPC process across edits, background jobs, and a validated report", async () => {
  const harness = await createHarness();
  const jobA = harness.jobLog("job-a");

  // 1. A turn that leaves a background job running settles without finishing the Task.
  await harness.worker.start({ revision: 1, prompt: `Task poc revision 1. CMD:START_JOB ${jobA} 3`, selection: selection("mock-a") });
  await waitForMarker(harness.markers, (marker) => marker.verb === "START_JOB" && marker.model === "mock-a");
  const jobPid = pidFrom(await waitForFile(jobA, (text) => text.includes("PID=")));
  await waitForFile(harness.markers, (text) => text.includes("DONE:START_JOB"));
  expect(harness.activity).toContain("waiting");
  expect(harness.reports).toEqual([]);
  expect(isAlive(jobPid)).toBe(true);

  // 2. Delegation is blocked, and the blocked call never reaches the tool.
  await harness.worker.update({ revision: 1, prompt: "CMD:DELEGATE now", selection: selection("mock-a") });
  const blocked = await waitForMarker(harness.markers, (marker) => marker.toolResult?.name === "subagent");
  expect(blocked.toolResult?.isError).toBe(true);
  expect(existsSync(harness.delegationMarker)).toBe(false);

  // 3. An edit switches model and revision; a report for the old revision is refused.
  await harness.worker.update({ revision: 2, prompt: "Revised instructions. CMD:REPORT 1 success", selection: selection("mock-b", "low") });
  const stale = await waitForMarker(harness.markers, (marker) => isReportResult(marker, true));
  expect(stale.model).toBe("mock-b");
  expect(stale.toolResult?.text ?? "").toMatch(/revision/i);
  expect(harness.reports).toEqual([]);

  // 4. The detached job completes on its own and wakes the child.
  await waitForFile(jobA, (text) => text.includes("JOB_DONE"));
  await waitForMarker(harness.markers, (marker) => marker.kind === "completion");

  // 5. Only an explicit task_report for the active revision finishes it, exactly once.
  await harness.worker.update({ revision: 3, prompt: "CMD:REPORT 3 success", selection: selection("mock-b", "low") });
  await waitForMarker(harness.markers, (marker) => isReportResult(marker, false));
  expect(harness.reports).toHaveLength(1);
  expect(harness.reports[0]).toMatchObject({ taskId: "task-poc", revision: 3, status: "success" });
  await harness.worker.update({ revision: 3, prompt: "CMD:REPORT 3 success", selection: selection("mock-b", "low") });
  await waitForFile(harness.markers, (text) => parseMarkers(text).filter((marker) => isReportResult(marker, false)).length >= 2);
  expect(harness.reports).toHaveLength(1);
  expect(harness.errors).toEqual([]);
}, 120_000);

it("a user stop confirms the worker exit and takes its background job down with it", async () => {
  const harness = await createHarness();
  const job = harness.jobLog("job-stop");
  await harness.worker.start({ revision: 1, prompt: `CMD:START_JOB ${job} 120`, selection: selection("mock-a") });
  const pid = pidFrom(await waitForFile(job, (text) => text.includes("PID=")));
  expect(isAlive(pid)).toBe(true);
  expect(await harness.worker.stop()).toBe(true);
  // A planned stop is not an exit error, and the child cleans up its own jobs.
  expect(harness.exits).toEqual([]);
  await vi.waitFor(() => expect(isAlive(pid)).toBe(false), { timeout: 10_000 });
  await expect(harness.worker.update({ revision: 2, prompt: "CMD:ECHO x", selection: selection("mock-a") })).rejects.toThrow();
}, 90_000);

it("surfaces a terminal provider failure instead of waiting for task_report forever", async () => {
  const harness = await createHarness();
  await harness.worker.start({ revision: 1, prompt: "CMD:FAIL", selection: selection("mock-a") });
  await vi.waitFor(() => expect(harness.errors).toContain("Deliberate non-retryable provider failure"), { timeout: 20_000 });
  expect(harness.reports).toEqual([]);
}, 60_000);

it("refuses to run a Task on a model the child does not have", async () => {
  const harness = await createHarness();
  await expect(harness.worker.start({ revision: 1, prompt: "CMD:ECHO x", selection: selection("mock-zzz") })).rejects.toThrow(/Model not found/);
  expect(harness.reports).toEqual([]);
}, 60_000);

it("fails visibly when the pi CLI cannot be used", async () => {
  const worker = createRpcWorker(
    {
      taskId: "task-missing-cli",
      cwd: tmpdir(),
      sessionFile: join(tmpdir(), "task-missing-cli.jsonl"),
      contextFile: join(tmpdir(), "task-missing-cli.json"),
      readonly: false,
      cliPath: join(tmpdir(), "definitely-not-a-pi-cli.js"),
    },
    { onReport: () => {}, onActivity: () => {}, onExit: () => {}, onError: () => {} },
  );
  await expect(worker.start({ revision: 1, prompt: "x", selection: selection("mock-a") })).rejects.toThrow(/CLI not found/);
  await worker.stop();
});

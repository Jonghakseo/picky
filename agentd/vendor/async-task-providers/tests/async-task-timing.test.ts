import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import {
	ASYNC_TASK_CHANNEL,
	AsyncTaskProvider,
	type TrackedTask,
} from "../packages/bash-async/async-task-provider.js";
import { JobManager, type JobManagerOptions } from "../packages/bash-async/job-manager.js";
import {
	completeAsyncInvocation,
	SubagentAsyncTasks,
	trackSubagentRunner,
} from "../packages/subagent/async-task-lifecycle.js";
import type { SingleResult } from "../packages/subagent/types.js";

// These providers run inside Picky's packaged runtime, so the host fixture speaks the
// frozen wire contract instead of reaching into provider internals.
type Frame = Record<string, unknown>;

const cleanups: Array<() => Promise<void> | void> = [];
afterEach(async () => {
	for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
	vi.useRealTimers();
});

function createHost(providerId: string) {
	const listeners = new Set<(message: unknown) => void>();
	const frames: Frame[] = [];
	const deliver = (message: Frame) => {
		for (const listener of [...listeners]) listener(message);
	};
	const bus = {
		on(_channel: string, listener: (message: unknown) => void) {
			listeners.add(listener);
			return () => {
				listeners.delete(listener);
			};
		},
		emit(_channel: string, message: unknown) {
			const frame = message as Frame;
			frames.push(frame);
			const envelope = {
				contract: ASYNC_TASK_CHANNEL,
				sessionId: "session-timing",
				piSessionId: frame.piSessionId,
				runtimeInstanceId: "runtime-timing",
				providerId,
				providerInstanceId: frame.providerInstanceId,
				requestId: frame.requestId,
				providerRevision: frame.providerRevision,
				controlGeneration: 0,
			};
			if (frame.type === "host-query") {
				deliver({
					...envelope,
					type: "host-state",
					supported: true,
					admissionState: "open",
					capabilities: {
						registration: true,
						snapshot: true,
						cancel: true,
						detail: true,
						closeAdmission: true,
						suppressDelivery: true,
					},
				});
			}
			if (frame.type === "task-register") {
				const task = frame.task as TrackedTask;
				deliver({
					...envelope,
					type: "task-register-result",
					taskId: task.taskId,
					outcome: "accepted",
					registration: "approved",
					grantId: `grant-${task.taskId}`,
					controlGeneration: task.controlGeneration,
				});
			}
		},
	};
	/** Latest published task snapshot, i.e. exactly what the Picky host would project. */
	const tasks = (): TrackedTask[] => {
		for (let index = frames.length - 1; index >= 0; index--) {
			const frame = frames[index];
			if (frame?.type !== "task-update") continue;
			return (frame.detail as { tasks: TrackedTask[] }).tasks;
		}
		return [];
	};
	const task = (taskId: string) => tasks().find((candidate) => candidate.taskId === taskId);
	return { bus, frames, tasks, task };
}

function createProvider(providerId: string) {
	const host = createHost(providerId);
	const provider = new AsyncTaskProvider(host.bus, providerId, "timing-test", {
		cancel: () => {},
		detail: () => undefined,
		close: () => {},
	});
	cleanups.push(() => provider.shutdown());
	return { host, provider };
}

type JobManagerExecute = NonNullable<JobManagerOptions["execute"]>;

async function createJobManager(options: { now: () => number; execute: JobManagerExecute; maxConcurrency?: number }) {
	const { host, provider } = createProvider("bash-async");
	const root = await mkdtemp(join(tmpdir(), "picky-async-timing-"));
	const manager = new JobManager({
		provider,
		logsDirectory: join(root, "logs"),
		maxConcurrency: options.maxConcurrency ?? 4,
		now: options.now,
		execute: options.execute,
	});
	cleanups.push(async () => {
		await manager.abortAndSettleAll({ graceMs: 200 });
		await rm(root, { recursive: true, force: true });
	});
	const context = {
		cwd: root,
		sessionManager: { getSessionId: () => "pi-session-timing", getSessionFile: () => undefined },
	} as unknown as ExtensionContext;
	return { host, manager, context };
}

const STARTED_AT = Date.parse("2026-02-01T00:00:00.000Z");

it("reports the bash job's own start, finish and elapsed time to the host", async () => {
	let clock = STARTED_AT;
	const fixture = await createJobManager({
		now: () => clock,
		execute: async () => {
			clock += 4_500;
			return { exitCode: 0 };
		},
	});
	const started = await fixture.manager.start({ command: "echo hi", timeoutSeconds: 10, context: fixture.context });
	expect(started.ok).toBe(true);
	const jobId = started.ok ? started.details.jobId : "";

	await vi.waitFor(() => expect(fixture.manager.get(jobId)?.status).toBe("succeeded"));
	expect(fixture.host.task(jobId)?.details).toEqual({
		startedAt: "2026-02-01T00:00:00.000Z",
		finishedAt: "2026-02-01T00:00:04.500Z",
		elapsedMs: 4_500,
	});
});

it("keeps the settled bash timing fixed while later lifecycle traffic updates the task", async () => {
	let clock = STARTED_AT;
	const fixture = await createJobManager({
		now: () => clock,
		execute: async () => {
			clock += 1_250;
			return { exitCode: 0 };
		},
	});
	const started = await fixture.manager.start({ command: "echo hi", timeoutSeconds: 10, context: fixture.context });
	const jobId = started.ok ? started.details.jobId : "";
	await vi.waitFor(() => expect(fixture.host.task(jobId)?.execution).toBe("succeeded"));
	const settled = fixture.host.task(jobId)?.details;

	// Unrelated later traffic moves updatedAt; a host must still render the real duration.
	clock += 60_000;
	const revisions = fixture.host.frames.length;
	await fixture.manager.start({ command: "echo later", timeoutSeconds: 10, context: fixture.context });
	await vi.waitFor(() => expect(fixture.host.frames.length).toBeGreaterThan(revisions));

	expect(fixture.host.task(jobId)?.details).toEqual(settled);
	expect(settled).toEqual({
		startedAt: "2026-02-01T00:00:00.000Z",
		finishedAt: "2026-02-01T00:00:01.250Z",
		elapsedMs: 1_250,
	});
});

it("omits the start and duration for a bash job killed before it ever ran", async () => {
	let clock = STARTED_AT;
	const fixture = await createJobManager({
		maxConcurrency: 1,
		now: () => clock,
		execute: ({ job }) =>
			new Promise((resolve) => {
				job.abortController.signal.addEventListener("abort", () => resolve({ exitCode: null }), { once: true });
			}),
	});
	const blocking = await fixture.manager.start({ command: "sleep 1", timeoutSeconds: 10, context: fixture.context });
	const queued = await fixture.manager.start({ command: "echo hi", timeoutSeconds: 10, context: fixture.context });
	expect(blocking.ok).toBe(true);
	expect(queued.ok).toBe(true);
	const queuedId = queued.ok ? queued.details.jobId : "";
	expect(fixture.manager.get(queuedId)?.status).toBe("queued");

	clock += 2_000;
	await fixture.manager.kill(queuedId, 200);

	expect(fixture.host.task(queuedId)?.execution).toBe("cancelled");
	expect(fixture.host.task(queuedId)?.details).toEqual({ finishedAt: "2026-02-01T00:00:02.000Z" });
});

function singleResult(exitCode: number): SingleResult {
	return {
		agent: "verifier",
		agentSource: "project",
		task: "verify the fix",
		exitCode,
		messages: [],
		stderr: "",
		usage: {},
		stopReason: "stop",
	} as unknown as SingleResult;
}

function createSubagentLifecycle() {
	const host = createHost("subagent");
	const pi = { events: host.bus } as unknown as ExtensionAPI;
	const tasks = new SubagentAsyncTasks(pi);
	cleanups.push(() => tasks.shutdown());
	tasks.bind("pi-session-timing");
	return { host, tasks };
}

it("times the subagent group and each agent separately from its own execution window", async () => {
	vi.useFakeTimers();
	vi.setSystemTime(STARTED_AT);
	const fixture = createSubagentLifecycle();
	let verifierTaskId = "";

	await fixture.tasks.invoke("batch", "invocation-timing", async () => {
		await trackSubagentRunner(
			"verifier",
			undefined,
			async () => {
				verifierTaskId = fixture.host.tasks().find((task) => task.parentTaskId)?.taskId ?? "";
				vi.setSystemTime(STARTED_AT + 3_000);
				return singleResult(0);
			},
			7,
		);
		vi.setSystemTime(STARTED_AT + 5_000);
		completeAsyncInvocation("completed");
		return { isError: false };
	});

	const verifier = fixture.host.task(verifierTaskId);
	const group = fixture.host.tasks().find((task) => task.taskId === task.rootTaskId);
	expect(verifier?.details).toEqual({
		runId: 7,
		startedAt: "2026-02-01T00:00:00.000Z",
		finishedAt: "2026-02-01T00:00:03.000Z",
		elapsedMs: 3_000,
	});
	expect(group?.details).toEqual({
		startedAt: "2026-02-01T00:00:00.000Z",
		finishedAt: "2026-02-01T00:00:05.000Z",
		elapsedMs: 5_000,
	});
});

it("keeps settled subagent timing fixed when shutdown republishes the group", async () => {
	vi.useFakeTimers();
	vi.setSystemTime(STARTED_AT);
	const fixture = createSubagentLifecycle();

	await fixture.tasks.invoke("batch", "invocation-timing", async () => {
		await trackSubagentRunner("verifier", undefined, async () => singleResult(0), 7);
		vi.setSystemTime(STARTED_AT + 2_000);
		completeAsyncInvocation("completed");
		return { isError: false };
	});
	const settled = fixture.host.tasks().map((task) => [task.taskId, task.details] as const);

	vi.setSystemTime(STARTED_AT + 90_000);
	fixture.tasks.shutdown();

	expect(fixture.host.tasks().map((task) => [task.taskId, task.details] as const)).toEqual(settled);
	expect(settled.map(([, details]) => details?.elapsedMs)).toEqual([2_000, 0]);
});

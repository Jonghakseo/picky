import { readFileSync, readdirSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { AsyncTaskHostMessageSchema, AsyncTaskDetailSchema, AsyncTaskCommandSchema, AsyncTaskCommandResultSchema } from "./async-task-contract.js";
import { buildSessionProjectionMutations } from "./terminal-session-finalization.js";
import { EventEnvelopeSchema, PickyAgentSessionSchema, PROTOCOL_VERSION, parseCommand } from "../protocol.js";
import { SessionStore } from "../session-store.js";
import { boundedSessionForProjectionSnapshot, minimalSessionForAppSnapshot } from "../application/app-session-snapshot-policy.js";

const root = new URL("../../../contracts/extensions/async-tasks-v1/", import.meta.url);
const fixture = JSON.parse(readFileSync(new URL("../../../contracts/protocol/session-async-tasks-snapshot.event.json", import.meta.url), "utf8"));
const session = () => PickyAgentSessionSchema.parse(fixture.projection);
const detail = () => ({ tasks: session().asyncTasks!, tickets: session().completionTickets! });

describe("async task shared contract", () => {
  for (const name of readdirSync(root).filter((name) => name.endsWith(".json"))) {
    it(`accepts provider fixture ${name}`, () => {
      const input = JSON.parse(readFileSync(new URL(name, root), "utf8"));
      expect(AsyncTaskHostMessageSchema.parse(input)).toEqual(input);
    });
  }

  for (const name of readdirSync(new URL("commands/", root))) {
    it(`round trips command fixture ${name}`, () => {
      const input = JSON.parse(readFileSync(new URL(`commands/${name}`, root), "utf8"));
      const schema = name === "result.json" ? AsyncTaskCommandResultSchema : AsyncTaskCommandSchema;
      expect(schema.parse(input)).toEqual(input);
    });
  }

  it("rejects duplicate attempts, wrong owner roots, invalid cycles and oversized details", () => {
    const value = detail();
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tasks: [...value.tasks, ...value.tasks] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tickets: [...value.tickets, ...value.tickets] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tasks: [{ ...value.tasks[0], rootTaskId: "missing" }] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tickets: [{ ...value.tickets[0], providerInstanceId: "stale" }] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tickets: [{ ...value.tickets[0], state: "handled" }] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tasks: [{ ...value.tasks[0], title: "x".repeat(501) }] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tasks: [{ ...value.tasks[0], details: { output: "x".repeat(16_384) } }] }).success).toBe(false);
    expect(AsyncTaskDetailSchema.safeParse({ ...value, tasks: [{ ...value.tasks[0], presence: "probablyDone" }] }).success).toBe(false);
  });

  it("rejects settled episodes without response identity and outcome", () => {
    const original = session();
    for (const episode of [{ id: "cycle", settled: true }, { id: "", settled: false }, { id: "cycle", settled: false, finalizedCycleId: "" }]) {
      expect(PickyAgentSessionSchema.safeParse({ ...original, asyncWorkSummary: { ...original.asyncWorkSummary, episode } }).success).toBe(false);
    }
  });

  it("keeps new attempts distinct when their display run ID is reused", () => {
    const value = detail();
    value.tasks.push({ ...value.tasks[0]!, taskId: "task-2", rootTaskId: "task-2" });
    expect(AsyncTaskDetailSchema.parse(value).tasks.map((task) => task.taskId)).toEqual(["task-1", "task-2"]);
  });

  it("persists unknown task kinds, tickets and controls and emits one revision's explicit mutations", async () => {
    const directory = await mkdtemp(join(tmpdir(), "picky-w1-"));
    try {
      const store = new SessionStore(directory);
      const after = session();
      after.asyncWorkSummary!.episode = { id: "first-cycle", settled: false, finalizedCycleId: after.agentCycle!.cycleId, outcome: "completed" };
      await store.save(after);
      const loaded = await store.loadReadOnly(after.id);
      expect(loaded).toEqual(after);
      expect(loaded?.asyncWorkSummary?.episode).toEqual(after.asyncWorkSummary?.episode);
      const before = { ...after, agentCycle: undefined, asyncWorkSummary: undefined, asyncTasks: undefined, completionTickets: undefined, asyncControl: undefined };
      const mutations = buildSessionProjectionMutations(before, after);
      expect(mutations.map((mutation) => mutation.type)).toEqual(["metaPatch", "asyncTaskDetailSet", "asyncControlSet"]);
      const event = EventEnvelopeSchema.parse({ id: "event", protocolVersion: PROTOCOL_VERSION, timestamp: after.updatedAt,
        type: "sessionProjectionTransaction", sessionId: after.id, epoch: "epoch", baseRevision: 1, revision: 2, mutations });
      expect(event.type).toBe("sessionProjectionTransaction");
      expect(loaded?.asyncTasks?.[0]?.details).toEqual({ runId: 1, future: { preserved: true } });
    } finally { await rm(directory, { recursive: true, force: true }); }
  });

  it("retains safety metadata but explicitly omits task detail under snapshot pressure", () => {
    const original = session();
    const minimal = minimalSessionForAppSnapshot(original);
    expect(minimal.agentCycle).toEqual(original.agentCycle);
    expect(minimal.asyncWorkSummary).toEqual(original.asyncWorkSummary);
    expect(minimal.asyncTasks).toBeUndefined();
    const bounded = boundedSessionForProjectionSnapshot({ ...original, logs: ["x".repeat(9 * 1024 * 1024)] }, { epoch: "epoch" });
    expect(bounded.session?.asyncWorkSummary?.uncertainExecutionCount).toBe(1);
    expect(bounded.omittedFields).toEqual(expect.arrayContaining(["asyncTasks", "completionTickets", "asyncControl"]));
    expect(bounded.session?.asyncTasks).toBeUndefined();
  });

  it("rejects missing safety metadata declarations and cross-session transactions", () => {
    expect(EventEnvelopeSchema.safeParse({ ...fixture, complete: false, omittedFields: ["asyncWorkSummary"] }).success).toBe(false);
    const transaction = JSON.parse(readFileSync(new URL("../../../contracts/protocol/session-async-tasks-transaction.event.json", import.meta.url), "utf8"));
    expect(EventEnvelopeSchema.safeParse({ ...transaction, sessionId: "another-session" }).success).toBe(false);
  });

  it("keeps command DTOs dormant and rejects arbitrary paths", () => {
    const command = { type: "cancelAsyncTask", requestId: "request", sessionId: "session-async", daemonInstanceId: "daemon", runtimeInstanceId: "runtime-async", workRevision: 2, controlGeneration: 1,
      owner: { sessionId: "session-async", piSessionId: "pi-async", runtimeInstanceId: "runtime-async", providerId: "subagent", providerInstanceId: "provider-async" }, taskId: "task-1" };
    expect(AsyncTaskCommandSchema.parse(command)).toEqual(command);
    expect(AsyncTaskCommandSchema.safeParse({ ...command, path: "/tmp/arbitrary" }).success).toBe(false);
    expect(() => parseCommand({ ...command, id: "command", protocolVersion: PROTOCOL_VERSION })).toThrow();
  });
});

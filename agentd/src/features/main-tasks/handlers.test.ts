import type { WebSocket } from "ws";
import { describe, expect, it, vi } from "vitest";
import { PROTOCOL_VERSION } from "../../protocol-base.js";
import type { EventPayload } from "../slice-contract.js";
import { mainTasksCommandHandlers, type MainTaskModelsPort, type MainTasksPort } from "./handlers.js";
import type { MainTaskModelPresets } from "./schema.js";

function port(): MainTasksPort & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    snapshot: () => ({ tasks: [], decisions: [] }),
    onChange: () => () => undefined,
    stopTask: vi.fn(async (taskId: string) => { calls.push(`stop:${taskId}`); }),
    resumeTask: vi.fn(async (taskId: string) => { calls.push(`resume:${taskId}`); }),
    resolveDecision: vi.fn(async (decisionId: string, choice: string, actor: string) => { calls.push(`${actor}:${decisionId}:${choice}`); }),
  };
}

function models(automatic?: ReturnType<MainTaskModelsPort["automaticPresets"]>): MainTaskModelsPort & { applied: MainTaskModelPresets[] } {
  const applied: MainTaskModelPresets[] = [];
  return { applied, setPresetOverrides: (presets) => { applied.push(presets); }, automaticPresets: () => automatic };
}

const base = { id: "cmd-1", protocolVersion: PROTOCOL_VERSION } as const;
const socket = {} as WebSocket;

function context(options: { mainTasks?: MainTasksPort; mainTaskModels?: MainTaskModelsPort } = {}) {
  const sent: EventPayload[] = [];
  return { sent, ctx: { socket, ...options, send: (_socket: WebSocket, event: EventPayload) => { sent.push(event); } } };
}

describe("main task commands", () => {
  it("routes the user's stop, resume, and decision answers to the service as user actions", async () => {
    const mainTasks = port();
    const handlers = mainTasksCommandHandlers(context({ mainTasks }).ctx);
    await handlers.controlMainTask({ ...base, type: "controlMainTask", taskId: "task-1", action: "stop" });
    await handlers.controlMainTask({ ...base, type: "controlMainTask", taskId: "task-1", action: "resume" });
    await handlers.resolveMainDelegation({ ...base, type: "resolveMainDelegation", decisionId: "delegation-1", choice: "pickle" });
    expect(mainTasks.calls).toEqual(["stop:task-1", "resume:task-1", "app:delegation-1:pickle"]);
  });

  it("fails visibly on a daemon without main Tasks", async () => {
    const handlers = mainTasksCommandHandlers(context().ctx);
    await expect(handlers.controlMainTask({ ...base, type: "controlMainTask", taskId: "task-1", action: "stop" })).rejects.toThrow(/not available/);
  });
});

describe("Task model settings", () => {
  const sol = { provider: "openai-codex", model: "gpt-6-sol", thinking: "medium" } as const;
  const automatic = { fast: { ...sol, model: "gpt-6-luna", thinking: "low" }, balanced: sol, powerful: { ...sol, model: "gpt-6-astra", thinking: "high" } } as const;

  it("hands the saved choices to the Task models and answers what automatic means", async () => {
    const mainTaskModels = models(automatic);
    const { ctx, sent } = context({ mainTaskModels });
    const handlers = mainTasksCommandHandlers(ctx);
    const presets = { fast: { model: { provider: "anthropic", id: "claude-haiku-5-5" } }, powerful: { thinking: "xhigh" } } as const;
    await handlers.setMainTaskModelPresets({ ...base, type: "setMainTaskModelPresets", taskModelPresets: presets });
    expect(mainTaskModels.applied).toEqual([presets]);

    await handlers.getMainTaskModelPresets({ ...base, id: "cmd-2", type: "getMainTaskModelPresets" });
    expect(sent).toEqual([{ type: "mainTaskModelPresets", commandId: "cmd-2", automatic }]);
  });

  // The app sends its settings to every daemon it connects to, including ones that run no Tasks.
  it("ignores the settings and answers without automatic models where Tasks do not run", async () => {
    const { ctx, sent } = context();
    const handlers = mainTasksCommandHandlers(ctx);
    expect(() => handlers.setMainTaskModelPresets({ ...base, type: "setMainTaskModelPresets", taskModelPresets: {} })).not.toThrow();
    await handlers.getMainTaskModelPresets({ ...base, type: "getMainTaskModelPresets" });
    expect(sent).toEqual([{ type: "mainTaskModelPresets", commandId: "cmd-1" }]);
  });
});

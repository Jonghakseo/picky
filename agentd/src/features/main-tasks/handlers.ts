import type { WebSocket } from "ws";
import { logAgentd } from "../../local-log.js";
import type { CommandHandlersFor, EventPayload } from "../slice-contract.js";
import type { MainTaskAutomaticModels, MainTaskModelPresets, MainTasksSnapshot } from "./schema.js";

export type MainTasksCommandType = "controlMainTask" | "resolveMainDelegation" | "setMainTaskModelPresets" | "getMainTaskModelPresets";

/** The main-task service surface the wire needs. Implemented by `application/main-task-service.ts`. */
export interface MainTasksPort {
  snapshot(): MainTasksSnapshot;
  onChange(listener: (snapshot: MainTasksSnapshot) => void): () => void;
  stopTask(taskId: string): Promise<unknown>;
  resumeTask(taskId: string): Promise<unknown>;
  resolveDecision(decisionId: string, choice: "pickle" | "task" | "cancel", actor: "app"): Promise<unknown>;
}

/** Which model each tier uses. Implemented by the Task evaluation context in `runtime/task/`. */
export interface MainTaskModelsPort {
  setPresetOverrides(presets: MainTaskModelPresets): void;
  automaticPresets(): MainTaskAutomaticModels | undefined;
}

export interface MainTasksFeatureContext {
  socket: WebSocket;
  mainTasks?: MainTasksPort;
  mainTaskModels?: MainTaskModelsPort;
  send: (socket: WebSocket, event: EventPayload) => void;
}

const UNAVAILABLE = "Main Picky Tasks are not available in this daemon";

/**
 * User controls from the app or a paired device. Both are explicit user actions, so a decision
 * answer here executes like a form answer. Failures surface as the command's `error` event.
 * The model settings are sent to every daemon the app connects to; one that runs no Tasks (a
 * child daemon or the mock runtime) ignores them instead of answering with an error.
 */
export function mainTasksCommandHandlers(ctx: MainTasksFeatureContext): CommandHandlersFor<MainTasksCommandType> {
  const require = (): MainTasksPort => {
    if (!ctx.mainTasks) throw new Error(UNAVAILABLE);
    return ctx.mainTasks;
  };
  return {
    controlMainTask: async (command) => {
      const port = require();
      logAgentd("main task control", { taskId: command.taskId, action: command.action });
      if (command.action === "stop") await port.stopTask(command.taskId);
      else await port.resumeTask(command.taskId);
    },
    resolveMainDelegation: async (command) => {
      await require().resolveDecision(command.decisionId, command.choice, "app");
    },
    setMainTaskModelPresets: (command) => {
      if (!ctx.mainTaskModels) return;
      ctx.mainTaskModels.setPresetOverrides(command.taskModelPresets);
      const custom = Object.entries(command.taskModelPresets)
        .filter(([, preset]) => preset?.model || preset?.thinking)
        .map(([tier]) => tier);
      logAgentd("main task model presets configured", { custom: custom.join(",") || "none" });
    },
    getMainTaskModelPresets: (command) => {
      const automatic = ctx.mainTaskModels?.automaticPresets();
      ctx.send(ctx.socket, { type: "mainTaskModelPresets", commandId: command.id, ...(automatic ? { automatic } : {}) });
    },
  };
}

import { logAgentd } from "../../local-log.js";
import type { CommandHandlersFor } from "../slice-contract.js";
import type { MainTasksSnapshot } from "./schema.js";

export type MainTasksCommandType = "controlMainTask" | "resolveMainDelegation";

/** The main-task service surface the wire needs. Implemented by `application/main-task-service.ts`. */
export interface MainTasksPort {
  snapshot(): MainTasksSnapshot;
  onChange(listener: (snapshot: MainTasksSnapshot) => void): () => void;
  stopTask(taskId: string): Promise<unknown>;
  resumeTask(taskId: string): Promise<unknown>;
  resolveDecision(decisionId: string, choice: "pickle" | "task" | "cancel", actor: "app"): Promise<unknown>;
}

const UNAVAILABLE = "Main Picky Tasks are not available in this daemon";

/**
 * User controls from the app or a paired device. Both are explicit user actions, so a decision
 * answer here executes like a form answer. Failures surface as the command's `error` event.
 */
export function mainTasksCommandHandlers(ctx: { mainTasks?: MainTasksPort }): CommandHandlersFor<MainTasksCommandType> {
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
  };
}

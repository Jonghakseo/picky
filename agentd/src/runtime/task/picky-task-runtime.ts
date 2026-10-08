import path from "node:path";
import type { InlineExtension } from "@earendil-works/pi-coding-agent";
import { createRpcWorker } from "./rpc-worker.js";
import { buildTaskConfig } from "./routing/config.js";
import { evaluateTask } from "./routing/evaluate.js";
import type { EvaluationContext, EvaluationResult, TaskContextSnapshot, TaskRecord, WorkerFactory } from "./types.js";

/**
 * Interactive tools that cannot work in an unattended worker. A worker that asks the user directly
 * would only be cancelled; it reports a blocked status instead and Picky asks.
 */
export const WORKER_UNATTENDED_EXCLUDED_TOOLS = ["ask_user_question"] as const;

/**
 * The worker's environment: the daemon's own, minus every `PICKY_*` variable (the daemon token,
 * app-support pointers, launcher flags) and the internal `picky` CLI folder on PATH. Provider
 * credentials the user configured through the environment stay available to the worker's Pi.
 */
export function taskWorkerEnvironment(env: NodeJS.ProcessEnv, internalBinDir: string): NodeJS.ProcessEnv {
  const result: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined || key.startsWith("PICKY_")) continue;
    result[key] = value;
  }
  const blocked = path.resolve(internalBinDir);
  if (result.PATH) result.PATH = result.PATH.split(path.delimiter).filter((entry) => entry && path.resolve(entry) !== blocked).join(path.delimiter);
  return result;
}

export interface PickyTaskWorkerOptions {
  /** `<app support>/bin`, where agentd installs the internal `picky` wrapper. */
  internalBinDir: string;
  env?: NodeJS.ProcessEnv;
  nodePath?: string;
}

/**
 * Workers run agentd's bundled Pi CLI with the same agent directory, credentials, and resources as
 * the main Picky agent. MCP stays off until per-server Picky scopes apply to workers: the CLI's
 * built-in MCP would otherwise connect every server regardless of the user's Picky scope.
 */
export function createPickyTaskWorkerFactory(options: PickyTaskWorkerOptions): WorkerFactory {
  return (workerOptions, events) => createRpcWorker({
    ...workerOptions,
    env: taskWorkerEnvironment(options.env ?? process.env, options.internalBinDir),
    ...(options.nodePath ? { nodePath: options.nodePath } : {}),
    excludeTools: [...WORKER_UNATTENDED_EXCLUDED_TOOLS],
    extraArgs: ["--no-mcp"],
  }, events);
}

/**
 * Holds the main agent's latest extension context so Task routing uses the same model registry,
 * credentials, and current model the main agent runs with.
 */
export class MainTaskEvaluationContext {
  private current?: EvaluationContext;

  update(context: EvaluationContext | undefined): void {
    if (context?.modelRegistry) this.current = context;
  }

  /** Captures the context on every main session start and turn. */
  extension(): InlineExtension {
    return {
      name: "picky-main-task-context",
      hidden: true,
      factory: (pi) => {
        pi.on("session_start", (_event, ctx) => this.update(ctx));
        pi.on("before_agent_start", (_event, ctx) => {
          this.update(ctx);
          return undefined;
        });
      },
    };
  }

  /**
   * Chooses the worker model for a revision. Without a live main context (right after a restart),
   * a resumed Task keeps its previous model rather than guessing a new one.
   */
  async evaluate(record: Readonly<TaskRecord>, snapshot: TaskContextSnapshot, signal: AbortSignal): Promise<EvaluationResult> {
    const context = this.current;
    let model: EvaluationContext["model"];
    try {
      model = context?.model;
    } catch {
      model = undefined;
    }
    if (!context || !model) {
      if (record.selection && record.tier) return { tier: record.tier, selection: record.selection, evaluator: "previous selection" };
      throw new Error("Picky's main model is not ready yet, so this Task could not choose a model. Ask Picky to resume it.");
    }
    return evaluateTask(record.instructions, snapshot, buildTaskConfig({ provider: model.provider, id: model.id }), context, signal);
  }
}

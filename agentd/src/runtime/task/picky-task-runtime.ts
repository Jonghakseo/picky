import path from "node:path";
import type { InlineExtension } from "@earendil-works/pi-coding-agent";
import { createRpcWorker } from "./rpc-worker.js";
import { buildTaskConfig, resolveDefaultPresets, type TaskPresetOverrides } from "./routing/config.js";
import { evaluateTask } from "./routing/evaluate.js";
import type { EvaluationContext, EvaluationResult, ModelSelection, TaskContextSnapshot, TaskRecord, TaskTier, WorkerFactory } from "./types.js";

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
 * credentials, and current model the main agent runs with, plus the user's per-tier model choices
 * from Picky's settings.
 */
export class MainTaskEvaluationContext {
  private current?: EvaluationContext;
  private presetOverrides: TaskPresetOverrides = {};

  update(context: EvaluationContext | undefined): void {
    if (context?.modelRegistry) this.current = context;
  }

  /** Replaces the user's choices. Applies to the next evaluation; a running revision keeps its model. */
  setPresetOverrides(overrides: TaskPresetOverrides): void {
    this.presetOverrides = structuredClone(overrides);
  }

  /**
   * What each tier uses when the user leaves it on automatic, for the current main model. Undefined
   * until the main agent has started, because the defaults follow the main model's provider.
   */
  automaticPresets(): Record<TaskTier, ModelSelection> | undefined {
    const model = this.currentModel();
    return model ? resolveDefaultPresets({ provider: model.provider, id: model.id }).presets : undefined;
  }

  private currentModel(): EvaluationContext["model"] {
    try {
      return this.current?.model;
    } catch {
      return undefined;
    }
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
    const model = this.currentModel();
    if (!context || !model) {
      if (record.selection && record.tier) return { tier: record.tier, selection: record.selection, evaluator: "previous selection" };
      throw new Error("Picky's main model is not ready yet, so this Task could not choose a model. Ask Picky to resume it.");
    }
    const config = buildTaskConfig({ provider: model.provider, id: model.id }, this.presetOverrides);
    return evaluateTask(record.instructions, snapshot, config, context, signal);
  }
}

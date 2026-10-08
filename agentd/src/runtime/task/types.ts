/**
 * Picky-owned Task engine types.
 *
 * Ported from `@ryan_nookpi/pi-extension-task@0.0.1` (MIT, Copyright (c) 2026 Jonghak Seo); see
 * `PROVENANCE.md` next to this file for the source revision and the contracts that changed.
 */
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

import type { EvaluationResult, ModelSelection, TaskConfig, TaskContextSnapshot, TaskReport } from "../../domain/task-record.js";
export type { TaskTier, ThinkingLevel, ModelSelection, TaskConfig, ContextEntry, TaskContextSnapshot, TaskEscalation, TaskReport, TaskStatus, TaskOrigin, TaskHandoff, TaskRecord, EvaluationResult } from "../../domain/task-record.js";

export type EvaluationContext = Pick<ExtensionContext, "modelRegistry" | "model">;
export type EvaluateTask = (
  instructions: readonly string[],
  context: TaskContextSnapshot,
  config: TaskConfig,
  ctx: EvaluationContext,
  signal?: AbortSignal,
) => Promise<EvaluationResult>;
export interface WorkerInput {
  revision: number;
  prompt: string;
  selection: ModelSelection;
}
export interface WorkerOptions {
  taskId: string;
  cwd: string;
  sessionFile: string;
  contextFile: string;
  readonly: boolean;
  /** The user approved this scope as a Task, so production-code escalation does not apply. */
  scopeApproved?: boolean;
  cliPath?: string;
  nodePath?: string;
  /** Tools to disable in addition to the recursive delegation tools. */
  excludeTools?: string[];
  extraArgs?: string[];
  env?: NodeJS.ProcessEnv;
  requestTimeoutMs?: number;
}
export interface WorkerEvents {
  onReport(report: TaskReport): void;
  onActivity(state: "running" | "waiting"): void;
  onExit(error?: string): void;
  onError(error: string): void;
}
export interface TaskWorker {
  start(input: WorkerInput): Promise<void>;
  update(input: WorkerInput): Promise<void>;
  abort(): Promise<void>;
  /** Resolves `false` when the process could not be confirmed to have exited. */
  stop(): Promise<boolean>;
}
export type WorkerFactory = (options: WorkerOptions, events: WorkerEvents) => TaskWorker;

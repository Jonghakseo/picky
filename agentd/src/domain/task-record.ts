/**
 * SDK-free Task record types shared by the Task engine (`runtime/task`) and pure policy code.
 * See `runtime/task/PROVENANCE.md` for where the engine came from.
 */
export type TaskTier = "fast" | "balanced" | "powerful";
export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export interface ModelSelection {
  provider: string;
  model: string;
  thinking: ThinkingLevel;
}
export interface TaskConfig {
  preferClassifier: boolean;
  classifier?: { provider: string; model: string };
  evaluator?: ModelSelection;
  evaluatorFallbacks: Record<string, ModelSelection>;
  presets: Record<TaskTier, ModelSelection>;
}
export interface ContextEntry {
  ref: string;
  role: string;
  text: string;
}
export interface TaskContextSnapshot {
  brief: string;
  entries: ContextEntry[];
}
/** Raised by a worker when the work grew into something the user has not approved for a Task. */
export type TaskEscalation = "production_code";
export interface TaskReport {
  taskId: string;
  revision: number;
  status: "success" | "failed" | "blocked";
  summary: string;
  artifacts: string[];
  verification: string[];
  blockers: string[];
  escalation?: TaskEscalation;
}
/**
 * `stopping`/`cancelled` are Picky additions: a user stop shuts the worker and its background jobs
 * down, unlike the original model-only `abort`.
 */
export type TaskStatus =
  | "queued"
  | "evaluating"
  | "running"
  | "waiting"
  | "stopping"
  | "completed"
  | "failed"
  | "blocked"
  | "cancelled"
  | "interrupted";
/** Where the request that created a Task came from. Reference data only, never an instruction source. */
export interface TaskOrigin {
  contextId?: string;
  source?: string;
  text?: string;
  /** Sent from a paired phone. Saved with the Task because the app forgets it when it restarts. */
  remote?: true;
}
export interface TaskHandoff {
  decisionId: string;
  pickleSessionId?: string;
}
export interface TaskRecord {
  id: string;
  revision: number;
  title: string;
  cwd: string;
  instructions: string[];
  readonly: boolean;
  status: TaskStatus;
  createdAt: string;
  updatedAt: string;
  /** When the current revision reached its worker; drives elapsed-time display only. */
  revisionStartedAt?: string;
  sessionFile: string;
  contextFile: string;
  origin?: TaskOrigin;
  /** Set when the user declined Pickle delegation and chose to run this scope as a Task. */
  decisionId?: string;
  tier?: TaskTier;
  selection?: ModelSelection;
  report?: TaskReport;
  error?: string;
  /** Whether a user stop could confirm that the worker process exited. */
  cleanup?: "confirmed" | "uncertain";
  handoff?: TaskHandoff;
  interruptionNotified?: boolean;
  completionDelivered?: boolean;
}
export interface EvaluationResult {
  tier: TaskTier;
  selection: ModelSelection;
  evaluator: string;
}

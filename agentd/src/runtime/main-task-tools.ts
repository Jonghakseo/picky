import { defineTool, type ExtensionContext, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { type Static, Type } from "typebox";
import type { DelegationDecisionRecord } from "../domain/main-task-policy.js";
import type { TaskRecord } from "./task/types.js";
import type { MainTaskEvaluationContext } from "./task/picky-task-runtime.js";

/** The main-task service surface the tools use. Implemented by `application/main-task-service.ts`. */
export interface MainTaskToolPort {
  createTask(input: { title?: string; instruction: string; cwd?: string; readonly?: boolean; branch?: readonly unknown[] }): TaskRecord;
  reviseTask(taskId: string, instruction: string): Promise<TaskRecord>;
  resumeTask(taskId: string, instruction?: string): Promise<TaskRecord>;
  stopTask(taskId: string): Promise<TaskRecord>;
  listTasks(): TaskRecord[];
  getTask(taskId: string): TaskRecord;
  createDecision(input: { title: string; instructions: string; cwd?: string; question?: string; fromTaskId?: string; branch?: readonly unknown[] }): DelegationDecisionRecord;
  resolveDecision(decisionId: string, choice: "pickle" | "task" | "cancel", actor: "form" | "model"): Promise<DelegationDecisionRecord>;
  listDecisions(): DelegationDecisionRecord[];
}

export const MAIN_TASK_TOOL = "Task";
export const PICKLE_DELEGATION_TOOL = "pickle_delegation";

type ToolText = { content: Array<{ type: "text"; text: string }>; details: Record<string, unknown> };
const result = (text: string, details: Record<string, unknown> = {}): ToolText => ({ content: [{ type: "text", text }], details });
const failure = (error: unknown): ToolText & { isError: true } => ({ ...result(error instanceof Error ? error.message : String(error), { error: true }), isError: true });

function branchOf(ctx: ExtensionContext): readonly unknown[] {
  try {
    return ctx.sessionManager.getBranch();
  } catch {
    return [];
  }
}

function describeTask(record: TaskRecord): string {
  const head = `${record.id} r${record.revision} "${record.title}": ${record.status}`;
  const report = record.report ? `\n${record.report.status}: ${record.report.summary}` : record.error ? `\n${record.error}` : "";
  return `${head} (${record.cwd})${report}`;
}

const TaskParams = Type.Object({
  action: Type.Optional(Type.Union([
    Type.Literal("create"), Type.Literal("revise"), Type.Literal("resume"), Type.Literal("stop"), Type.Literal("list"), Type.Literal("detail"),
  ], { description: "create (default), revise a running or finished Task, resume a stopped one, stop on the user's request, list, or detail." })),
  title: Type.Optional(Type.String({ description: "Short label the user sees for a new Task, in the user's language." })),
  task: Type.Optional(Type.String({ description: "The instruction for create, or the added instruction for revise/resume. Include the goal, constraints, known paths or URLs, and the expected result." })),
  taskId: Type.Optional(Type.String()),
  cwd: Type.Optional(Type.String({ description: "Absolute working folder for a new Task. Omit to use Picky's default working folder." })),
  readonly: Type.Optional(Type.Boolean({ description: "Investigate without changing files. An instruction to the worker, not a sandbox." })),
});

/**
 * `Task`: run multi-step work in a Picky-owned background worker that belongs to the main
 * conversation. Creation returns at once; the result arrives later as its own message.
 */
export function createMainTaskTool(port: MainTaskToolPort, evaluation: MainTaskEvaluationContext): ToolDefinition {
  return defineTool({
    name: MAIN_TASK_TOOL,
    label: "Task",
    description:
      "Run multi-step work in the background as a Picky Task: finding, editing, or opening files, researching several sources, one-off scripts, and other everyday procedures. Create returns a Task ID immediately and the final result arrives automatically as a later message; do not poll. Revise adds an instruction to the same worker. Stop shuts the worker and its background jobs down; use it only when the user asks. Production-level code work needs pickle_delegation first.",
    promptSnippet: "Task: run multi-step work in a background worker; the result arrives later as a message.",
    promptGuidelines: [
      "Use Task for work that needs several tool calls; answer directly when one or two quick calls are enough.",
      "Give each Task a short title in the user's language and a self-contained instruction; the worker cannot see your conversation beyond a snapshot.",
      "Do not poll list/detail to wait. Results arrive automatically. Stop a Task only when the user asks.",
      "Workers share the file system. Give parallel Tasks separate files or folders to change.",
    ],
    parameters: TaskParams,
    execute: async (_toolCallId, params, _signal, _onUpdate, ctx) => {
      evaluation.update(ctx);
      try {
        const action = params.action ?? "create";
        if (action === "list") {
          const records = port.listTasks().sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)).slice(0, 20);
          return result(records.map(describeTask).join("\n\n") || "No Tasks.", { taskIds: records.map((record) => record.id) });
        }
        if (action === "create") {
          if (!params.task?.trim()) throw new Error("task is required to create a Task");
          const record = port.createTask({ title: params.title, instruction: params.task, cwd: params.cwd, readonly: params.readonly, branch: branchOf(ctx) });
          return result(`${describeTask(record)}\nAccepted. The result will arrive automatically; tell the user it is running and do not poll.`, { taskId: record.id });
        }
        if (!params.taskId) throw new Error("taskId is required");
        if (action === "detail") {
          const record = port.getTask(params.taskId);
          return result(JSON.stringify({ ...record, sessionFile: undefined, contextFile: undefined }, null, 2), { taskId: record.id });
        }
        if (action === "stop") {
          const record = await port.stopTask(params.taskId);
          const note = record.cleanup === "uncertain" ? " Picky could not confirm that the worker exited." : "";
          return result(`${describeTask(record)}${note}`, { taskId: record.id });
        }
        if (action === "resume") {
          const record = await port.resumeTask(params.taskId, params.task);
          return result(`${describeTask(record)}\nResumed in the same worker session. The result will arrive automatically.`, { taskId: record.id });
        }
        if (!params.task?.trim()) throw new Error("task is required to revise a Task");
        const record = await port.reviseTask(params.taskId, params.task);
        return result(`${describeTask(record)}\nRevision accepted. The result will arrive automatically.`, { taskId: record.id });
      } catch (error) {
        return failure(error);
      }
    },
  });
}

const DelegationParams = Type.Object({
  action: Type.Union([Type.Literal("ask"), Type.Literal("resolve"), Type.Literal("cancel"), Type.Literal("list")], {
    description: "ask the user before production-level code work; resolve or cancel a pending decision from the user's reply; list decisions.",
  }),
  title: Type.Optional(Type.String({ description: "Short label of the work, in the user's language." })),
  instructions: Type.Optional(Type.String({ description: "Self-contained brief for whoever does the work: goal, constraints, key paths or URLs, expected result." })),
  cwd: Type.Optional(Type.String({ description: "Absolute working folder of the work, such as the repository root." })),
  question: Type.Optional(Type.String({ description: "The question shown to the user, in the user's language." })),
  pickleLabel: Type.Optional(Type.String({ description: "Label of the hand-to-Pickle choice, in the user's language." })),
  taskLabel: Type.Optional(Type.String({ description: "Label of the keep-it-as-a-Task choice, in the user's language." })),
  fromTaskId: Type.Optional(Type.String({ description: "The Task whose work grew into production code work, for a handoff." })),
  decisionId: Type.Optional(Type.String()),
  choice: Type.Optional(Type.Union([Type.Literal("pickle"), Type.Literal("task")])),
});

function describeDecision(decision: DelegationDecisionRecord): string {
  if (decision.state === "pending") return `Decision ${decision.id} "${decision.title}" is pending. Nothing has started.`;
  if (decision.state === "cancelled") return `Decision ${decision.id} "${decision.title}" was cancelled. Nothing runs.`;
  if (decision.state === "task") return `Decision ${decision.id}: the user chose a Task. Task ${decision.taskId} runs this scope; do not ask about a Pickle again for it.`;
  const pickle = decision.pickle;
  if (pickle?.state === "created") return `Decision ${decision.id}: handed to Pickle ${pickle.sessionId}. Progress is in the Picky dock.`;
  if (pickle?.state === "failed") return `Decision ${decision.id}: creating the Pickle failed (${pickle.error ?? "unknown error"}). Nothing else started. The user can retry or choose a Task.`;
  return `Decision ${decision.id}: the Pickle is being created.`;
}

function choiceFrom(answer: unknown): "pickle" | "task" | undefined {
  const value = answer && typeof answer === "object" && !Array.isArray(answer) ? (answer as Record<string, unknown>).choice : undefined;
  const picked = Array.isArray(value) ? value[0] : value;
  return picked === "pickle" || picked === "task" ? picked : undefined;
}

/**
 * `pickle_delegation`: the only way production-level code work reaches a Pickle or a Task after a
 * question. The choice executes here, from the user's form answer; a closed form leaves the
 * decision pending and starts nothing.
 */
export function createPickleDelegationTool(port: MainTaskToolPort): ToolDefinition {
  return defineTool({
    name: PICKLE_DELEGATION_TOOL,
    label: "Pickle delegation",
    description:
      "Ask the user whether production-level code work (maintained product code that needs verification and Git tracking) should go to a Pickle or run as a Picky Task, and carry out the answer. Do not start the work, create worktrees, or create Pickles before the user answers. A closed question leaves the decision pending and nothing runs. Resolve a pending decision only when the user's own reply clearly answers it.",
    promptSnippet: "pickle_delegation: ask Pickle-or-Task before production-level code work and carry out the user's answer.",
    promptGuidelines: [
      "Call action ask before production-level code work: product bug fixes, features, refactors of maintained code, or builds and integration checks of a product. One-off scripts and everyday work are not production code work.",
      "Do not ask again for a scope the user already placed in a Task or a Pickle.",
      "If the user explicitly asks for a Pickle, create it with the picky CLI instead of asking.",
    ],
    parameters: DelegationParams,
    execute: async (_toolCallId, params, signal, _onUpdate, ctx) => {
      try {
        if (params.action === "list") return listDecisions(port);
        if (params.action === "resolve" || params.action === "cancel") return await answerDecision(port, params);
        return await askDecision(port, params, ctx, signal);
      } catch (error) {
        return failure(error);
      }
    },
  });
}

type DelegationInput = Static<typeof DelegationParams>;

function listDecisions(port: MainTaskToolPort): ToolText {
  const decisions = port.listDecisions().sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)).slice(0, 10);
  return result(decisions.map(describeDecision).join("\n") || "No delegation decisions.", { decisionIds: decisions.map((decision) => decision.id) });
}

/** The model relays an answer the user gave in conversation; the service checks who started the turn. */
async function answerDecision(port: MainTaskToolPort, params: DelegationInput): Promise<ToolText> {
  if (!params.decisionId) throw new Error("decisionId is required");
  const choice = params.action === "cancel" ? "cancel" : params.choice;
  if (!choice) throw new Error("choice is required to resolve a decision");
  const decision = await port.resolveDecision(params.decisionId, choice, "model");
  return result(describeDecision(decision), { decisionId: decision.id, state: decision.state });
}

async function askDecision(port: MainTaskToolPort, params: DelegationInput, ctx: ExtensionContext, signal: AbortSignal | undefined): Promise<ToolText> {
  if (!params.title?.trim() || !params.instructions?.trim()) throw new Error("title and instructions are required to ask");
  const decision = port.createDecision({
    title: params.title, instructions: params.instructions, cwd: params.cwd, question: params.question, fromTaskId: params.fromTaskId, branch: branchOf(ctx),
  });
  // A repeated ask about the same Task returns the decision it already holds.
  if (decision.state !== "pending") return result(describeDecision(decision), { decisionId: decision.id, state: decision.state });
  const ui = ctx.ui as unknown as Record<string, unknown>;
  const askUserQuestion = ui.askUserQuestion ?? ui.ask_user_question;
  if (!ctx.hasUI || typeof askUserQuestion !== "function") {
    return result(`${describeDecision(decision)} Picky could not show the question; ask the user in your reply and resolve the decision from their answer.`, { decisionId: decision.id, state: decision.state });
  }
  const answer = await (askUserQuestion as (request: unknown, options?: { signal?: AbortSignal }) => Promise<unknown>)(delegationQuestion(params), { signal });
  const choice = choiceFrom(answer);
  if (!choice) {
    return result(`The user closed the question without answering. Decision ${decision.id} stays pending and nothing was started. If the user's next message clearly answers it, call pickle_delegation with action resolve; otherwise leave it pending.`, { decisionId: decision.id, state: "pending" });
  }
  const resolved = await port.resolveDecision(decision.id, choice, "form");
  return result(describeDecision(resolved), { decisionId: resolved.id, state: resolved.state });
}

function delegationQuestion(params: DelegationInput): Record<string, unknown> {
  return {
    title: params.title,
    ...(params.question ? {} : { description: params.instructions }),
    questions: [{
      id: "choice",
      type: "radio",
      prompt: params.question ?? params.title,
      options: [
        { value: "pickle", label: params.pickleLabel?.trim() || "Hand it to a Pickle" },
        { value: "task", label: params.taskLabel?.trim() || "Run it here as a Task" },
      ],
      allowOther: false,
      required: true,
    }],
  };
}

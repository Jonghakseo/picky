/**
 * Private extension loaded into every Picky Task worker process. It gives the child exactly three things
 * the parent needs: a report channel, read access to the parent conversation snapshot, and a
 * control command that moves the child to a new revision without restarting the process.
 *
 * It is never installed by a user. agentd passes it with `--extension`, and the identity of the
 * Task arrives through `PICKY_TASK_*` environment variables.
 */
import { readFile } from "node:fs/promises";
import type { AgentToolResult, ExtensionAPI, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { type Static, Type } from "typebox";
import { queryContext } from "./context.js";
import type { TaskContextSnapshot } from "./types.js";
import {
  buildTaskReport,
  buildWorkerInstructions,
  ENV_TASK_CONTEXT_FILE,
  ENV_TASK_ID,
  ENV_TASK_READONLY,
  ENV_TASK_REVISION,
  ENV_TASK_SCOPE_APPROVED,
  isRecursiveToolName,
  parseWorkerControl,
  TASK_CONTEXT_TOOL,
  TASK_REPORT_TOOL,
  type TaskReportDetails,
  WORKER_CONTROL_COMMAND,
  WORKER_PROMPT_SECTION,
} from "./protocol.js";

const ReportParams = Type.Object(
  {
    revision: Type.Integer({
      minimum: 1,
      description: "The active revision from your instructions. A stale revision is rejected.",
    }),
    status: Type.Union([Type.Literal("success"), Type.Literal("failed"), Type.Literal("blocked")], {
      description:
        "success only when the result is verified; failed when the work broke; blocked when you cannot continue.",
    }),
    summary: Type.String({ description: "What you did and what the parent now has, in a few sentences." }),
    artifacts: Type.Optional(
      Type.Array(Type.String(), { description: "Files, commands, or URLs the parent should look at." }),
    ),
    verification: Type.Optional(
      Type.Array(Type.String(), {
        description: "Checks you actually ran, with their outcome. Leave empty when you ran none.",
      }),
    ),
    blockers: Type.Optional(
      Type.Array(Type.String(), { description: "What stopped you, and what the parent must decide." }),
    ),
    escalation: Type.Optional(
      Type.Literal("production_code", {
        description: "Set with status blocked when the work needs production-level code changes this Task was not approved for.",
      }),
    ),
  },
  { additionalProperties: false },
);

const ContextParams = Type.Object(
  {
    query: Type.Optional(Type.String({ description: "Keywords to search the parent conversation snapshot for." })),
    refs: Type.Optional(
      Type.Array(Type.String(), { description: "Exact entry refs to expand, as returned by an earlier call." }),
    ),
    offset: Type.Optional(
      Type.Integer({ minimum: 0, description: "Resume from this offset of a truncated earlier result." }),
    ),
    limit: Type.Optional(
      Type.Integer({
        minimum: 1,
        description: "Characters per entry when expanding refs; otherwise the number of search or index results.",
      }),
    ),
  },
  { additionalProperties: false },
);

interface WorkerState {
  taskId: string;
  revision: number;
  readonly: boolean;
  scopeApproved: boolean;
  contextFile: string;
}

function text(value: string): AgentToolResult<undefined> {
  return { content: [{ type: "text", text: value }], details: undefined };
}

async function readSnapshot(file: string): Promise<TaskContextSnapshot> {
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch {
    throw new Error(
      `The parent conversation snapshot is unavailable (${file}). Continue from the instructions you have.`,
    );
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("The parent conversation snapshot is corrupt. Continue from the instructions you have.");
  }
  if (!parsed || typeof parsed !== "object") throw new Error("The parent conversation snapshot is corrupt.");
  const snapshot = parsed as Partial<TaskContextSnapshot>;
  return {
    brief: typeof snapshot.brief === "string" ? snapshot.brief : "",
    entries: Array.isArray(snapshot.entries) ? snapshot.entries : [],
  };
}

/**
 * A report shuts the worker down, which stops every job it still runs, so a report while one of
 * its jobs runs throws that job's result away. bash_async results name a job and its status, and a
 * list names every job this process keeps. Reading a finished job's output carries no status, so
 * before refusing, the bridge asks bash_async for the list instead of trusting what it last saw.
 */
const BACKGROUND_JOB_TOOL = "bash_async";
/** Any other status, including one a newer bash_async adds, counts as ended so a report is never held forever. */
const LIVE_JOB_STATUSES: ReadonlySet<string> = new Set(["queued", "running"]);

interface JobFact { id: string; status: string; title?: string }

function jobFact(value: unknown, idKey: "id" | "jobId"): JobFact | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  const id = record[idKey];
  if (typeof id !== "string" || typeof record.status !== "string") return undefined;
  return { id, status: record.status, ...(typeof record.title === "string" ? { title: record.title } : {}) };
}

/** A list is the whole set (`all`); other results describe only the job they name. Errors and rate limits describe nothing. */
function readJobs(details: unknown): { all: boolean; jobs: JobFact[] } {
  const jobs = details && typeof details === "object" ? (details as Record<string, unknown>).jobs : undefined;
  if (Array.isArray(jobs)) return { all: true, jobs: jobs.flatMap((job) => jobFact(job, "id") ?? []) };
  const single = jobFact(details, "jobId");
  return { all: false, jobs: single ? [single] : [] };
}

function reportWhileJobsRunReason(jobs: ReadonlyArray<{ id: string; title: string }>): string {
  const list = jobs.map((job) => (job.title ? `"${job.title}" (${job.id})` : job.id)).join(", ");
  return [
    `${TASK_REPORT_TOOL} is refused while background jobs you started are still running: ${list}.`,
    "Reporting now would stop them before you have their result.",
    `End your turn without ${TASK_REPORT_TOOL}; each job's completion message wakes you in this session.`,
    `If you no longer need a job, stop it with ${BACKGROUND_JOB_TOOL} kill first.`,
  ].join(" ");
}

export default function taskWorkerBridge(pi: ExtensionAPI): void {
  const taskId = process.env[ENV_TASK_ID]?.trim();
  // Loaded outside a Task worker (a stray --extension, a user copy): register nothing.
  if (!taskId) return;
  const startingRevision = Number(process.env[ENV_TASK_REVISION]);
  const state: WorkerState = {
    taskId,
    revision: Number.isInteger(startingRevision) && startingRevision > 0 ? startingRevision : 1,
    readonly: process.env[ENV_TASK_READONLY] === "1",
    scopeApproved: process.env[ENV_TASK_SCOPE_APPROVED] === "1",
    contextFile: process.env[ENV_TASK_CONTEXT_FILE] ?? "",
  };

  /**
   * Jobs this worker process started and has not seen end, with their titles. A resumed Task runs
   * in a new process whose old jobs died with the previous one, so they are never carried over.
   */
  const liveJobs = new Map<string, string>();
  const noteJobs = (details: unknown, startTitle = ""): void => {
    const { all, jobs } = readJobs(details);
    const titles = new Map(liveJobs);
    if (all) liveJobs.clear();
    for (const job of jobs) {
      if (LIVE_JOB_STATUSES.has(job.status)) liveJobs.set(job.id, job.title ?? titles.get(job.id) ?? startTitle);
      else liveJobs.delete(job.id);
    }
  };
  /** Settles which tracked jobs still run. A rate-limited list returns no jobs and leaves the last answer standing. */
  const confirmLiveJobs = async (ctx: ExtensionToolContext | undefined): Promise<void> => {
    if (typeof ctx?.executeTool !== "function") return;
    try {
      const outcome = await ctx.executeTool(BACKGROUND_JOB_TOOL, { action: "list" });
      if (!outcome.isError) noteJobs(outcome.result.details);
    } catch {
      // executeTool reports tool failures as isError; anything else leaves the tracked jobs in charge.
    }
  };

  /** Delegation tools can register lazily, so the active set is filtered again every turn. */
  const dropRecursiveTools = (): void => {
    try {
      const active = pi.getActiveTools();
      const kept = active.filter((name) => !isRecursiveToolName(name));
      if (kept.length !== active.length) pi.setActiveTools(kept);
    } catch {
      // The tool registry is not ready yet; the tool_call block still covers this turn.
    }
  };

  pi.registerTool({
    name: TASK_REPORT_TOOL,
    label: "Task report",
    description:
      "File the final result of this Task revision with the parent agent. This is the only way to finish; a normal assistant message does not. The worker process shuts down after a successful report, so finish or abandon your background jobs first.",
    promptSnippet: "task_report: hand the final result of this Task back to the parent agent.",
    parameters: ReportParams,
    annotations: { readOnlyHint: true, openWorldHint: false },
    async execute(_toolCallId, params: Static<typeof ReportParams>, _signal, _onUpdate, ctx): Promise<AgentToolResult<TaskReportDetails>> {
      if (params.revision !== state.revision) {
        throw new Error(
          `Revision ${params.revision} is not active. The active revision is ${state.revision}: re-read the newest instruction and report against it.`,
        );
      }
      if (liveJobs.size > 0) await confirmLiveJobs(ctx);
      if (liveJobs.size > 0) throw new Error(reportWhileJobsRunReason([...liveJobs].map(([id, title]) => ({ id, title }))));
      const report = buildTaskReport(state.taskId, { ...params });
      return {
        content: [
          {
            type: "text",
            text: `Reported ${report.status} for revision ${report.revision}. The parent has the result and this worker is shutting down.`,
          },
        ],
        details: { taskReport: report },
      };
    },
  });

  pi.registerTool({
    name: TASK_CONTEXT_TOOL,
    label: "Task context",
    description:
      "Read the parent conversation snapshot this Task was created from. Search it with a query, expand exact refs, and page through long entries with offset. The snapshot is frozen at the last instruction, so it never shows what the parent did afterwards.",
    promptSnippet: "task_context: read the parent conversation snapshot behind this Task.",
    parameters: ContextParams,
    annotations: { readOnlyHint: true, openWorldHint: false },
    async execute(_toolCallId, params: Static<typeof ContextParams>): Promise<AgentToolResult<undefined>> {
      if (!state.contextFile) throw new Error("This Task has no parent conversation snapshot.");
      const snapshot = await readSnapshot(state.contextFile);
      return text(queryContext(snapshot, params));
    },
  });

  pi.registerCommand(WORKER_CONTROL_COMMAND, {
    description: "Internal Task worker control channel.",
    handler: async (args) => {
      // Parent-only channel. Nothing from it is echoed back into the conversation.
      const message = parseWorkerControl(args);
      state.revision = message.revision;
    },
  });

  pi.on("tool_result", (event) => {
    if (event.toolName !== BACKGROUND_JOB_TOOL || event.isError) return undefined;
    noteJobs(event.details, typeof event.input.title === "string" ? event.input.title : "");
    return undefined;
  });

  pi.on("tool_call", (event) => {
    if (!isRecursiveToolName(event.toolName)) return undefined;
    return {
      block: true,
      reason: `${event.toolName} is not available inside a Task. Do the work in this process and report it with ${TASK_REPORT_TOOL}.`,
    };
  });

  pi.on("session_start", () => {
    dropRecursiveTools();
  });

  pi.on("before_agent_start", (event) => {
    dropRecursiveTools();
    const options = event.systemPromptOptions;
    options.selectedTools = options.selectedTools.filter((name) => !isRecursiveToolName(name));
    options.sections[WORKER_PROMPT_SECTION] = buildWorkerInstructions(state);
    return undefined;
  });
}

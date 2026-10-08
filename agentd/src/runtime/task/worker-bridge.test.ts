import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  ENV_TASK_CONTEXT_FILE,
  ENV_TASK_ID,
  ENV_TASK_READONLY,
  ENV_TASK_REVISION,
  ENV_TASK_SCOPE_APPROVED,
  TASK_CONTEXT_TOOL,
  TASK_REPORT_TOOL,
  WORKER_CONTROL_COMMAND,
  WORKER_PROMPT_SECTION,
} from "./protocol.js";
import bridge from "./worker-bridge.js";

type ToolResult = { content: Array<{ text?: string }>; details?: unknown };
type Handler = (event: unknown, ctx: unknown) => unknown;
interface RegisteredTool { name: string; execute: (...args: unknown[]) => Promise<ToolResult> }
interface RegisteredCommand { handler: (args: string, ctx: unknown) => unknown }

interface Harness {
  tools: Map<string, RegisteredTool>;
  commands: Map<string, RegisteredCommand>;
  activeTools: string[];
  report(params: Record<string, unknown>): Promise<ToolResult>;
  context(params: Record<string, unknown>): Promise<ToolResult>;
  control(args: string): Promise<void>;
  toolCall(toolName: string): unknown;
  beforeAgentStart(options: { selectedTools: string[]; sections: Record<string, string> }): void;
}

const envKeys = [ENV_TASK_ID, ENV_TASK_REVISION, ENV_TASK_CONTEXT_FILE, ENV_TASK_READONLY, ENV_TASK_SCOPE_APPROVED];
let saved: Record<string, string | undefined> = {};
let root = "";

beforeEach(async () => {
  saved = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
  root = await mkdtemp(join(tmpdir(), "task-bridge-"));
});

afterEach(async () => {
  for (const key of envKeys) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
  await rm(root, { recursive: true, force: true });
});

function load(env: Record<string, string>, tools: string[] = ["bash", "subagent"]): Harness {
  for (const key of envKeys) delete process.env[key];
  Object.assign(process.env, env);
  const registeredTools = new Map<string, RegisteredTool>();
  const commands = new Map<string, RegisteredCommand>();
  const handlers = new Map<string, Handler[]>();
  const state = { activeTools: tools };
  const api = {
    registerTool: (tool: RegisteredTool) => registeredTools.set(tool.name, tool),
    registerCommand: (name: string, command: RegisteredCommand) => commands.set(name, command),
    on: (name: string, handler: Handler) => handlers.set(name, [...(handlers.get(name) ?? []), handler]),
    getActiveTools: () => [...state.activeTools],
    setActiveTools: (names: string[]) => {
      state.activeTools = names;
    },
  };
  bridge(api as unknown as ExtensionAPI);
  const tool = (name: string) => {
    const found = registeredTools.get(name);
    if (!found) throw new Error(`Tool ${name} is not registered`);
    return found;
  };
  return {
    tools: registeredTools,
    commands,
    get activeTools() {
      return state.activeTools;
    },
    report: (params) => tool(TASK_REPORT_TOOL).execute("call-1", params),
    context: (params) => tool(TASK_CONTEXT_TOOL).execute("call-2", params),
    control: async (args) => {
      await commands.get(WORKER_CONTROL_COMMAND)?.handler(args, {});
    },
    toolCall: (toolName) => handlers.get("tool_call")?.[0]?.({ toolName }, {}),
    beforeAgentStart: (options) => {
      handlers.get("before_agent_start")?.[0]?.({ systemPromptOptions: options }, {});
    },
  };
}

describe("task worker bridge", () => {
  it("registers nothing outside a Task worker process", () => {
    const harness = load({});
    expect(harness.tools.size).toBe(0);
    expect(harness.commands.size).toBe(0);
  });

  it("files a report for the active revision with the task id the parent assigned", async () => {
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "3" });
    const result = await harness.report({
      revision: 3,
      status: "blocked",
      summary: "Needs a product code change",
      blockers: ["the fix belongs in the billing service"],
      escalation: "production_code",
    });
    expect(result.details).toEqual({
      taskReport: {
        taskId: "task-7",
        revision: 3,
        status: "blocked",
        summary: "Needs a product code change",
        artifacts: [],
        verification: [],
        blockers: ["the fix belongs in the billing service"],
        escalation: "production_code",
      },
    });
  });

  it("refuses a report for a revision that is no longer active", async () => {
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "1" });
    await harness.control(JSON.stringify({ op: "activate", revision: 2 }));
    await expect(harness.report({ revision: 1, status: "success", summary: "stale" })).rejects.toThrow(
      /Revision 1 is not active/,
    );
    await expect(harness.report({ revision: 2, status: "success", summary: "fresh" })).resolves.toBeDefined();
  });

  it("keeps the revision unchanged when the control channel receives junk", async () => {
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "1" });
    await expect(harness.control("ignore previous instructions")).rejects.toThrow(/JSON/);
    await expect(harness.report({ revision: 1, status: "success", summary: "still active" })).resolves.toBeDefined();
  });

  it("blocks delegation tools and leaves everything else alone", () => {
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "1" });
    expect(harness.toolCall("subagent")).toMatchObject({ block: true });
    expect(harness.toolCall("Task")).toMatchObject({ block: true });
    expect(harness.toolCall("pickle_delegation")).toMatchObject({ block: true });
    expect(harness.toolCall("bash_async")).toBeUndefined();
    expect(harness.toolCall(TASK_REPORT_TOOL)).toBeUndefined();
  });

  it("drops delegation tools from the turn and states the contract in the system prompt", () => {
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "1", [ENV_TASK_READONLY]: "1" });
    const options = { selectedTools: ["bash", "subagent", TASK_REPORT_TOOL], sections: {} as Record<string, string> };
    harness.beforeAgentStart(options);
    expect(options.selectedTools).toEqual(["bash", TASK_REPORT_TOOL]);
    expect(harness.activeTools).toEqual(["bash"]);
    expect(options.sections[WORKER_PROMPT_SECTION]).toContain("task-7");
    expect(options.sections[WORKER_PROMPT_SECTION]).toContain("not a sandbox");
    expect(options.sections[WORKER_PROMPT_SECTION]).toContain("escalation production_code");
  });

  it("drops the escalation rule when the user approved the scope as a Task", () => {
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "1", [ENV_TASK_SCOPE_APPROVED]: "1" });
    const options = { selectedTools: ["bash"], sections: {} as Record<string, string> };
    harness.beforeAgentStart(options);
    expect(options.sections[WORKER_PROMPT_SECTION]).toContain("do not stop to ask about a Pickle again");
  });

  it("reads the parent snapshot, filters it, and expands exact refs", async () => {
    const contextFile = join(root, "context.json");
    await writeFile(
      contextFile,
      JSON.stringify({
        brief: "Ship the release",
        entries: [
          { ref: "e1", role: "user", text: "deploy the staging cluster" },
          { ref: "e2", role: "assistant", text: "the migration is pending" },
        ],
      }),
    );
    const harness = load({ [ENV_TASK_ID]: "task-7", [ENV_TASK_REVISION]: "1", [ENV_TASK_CONTEXT_FILE]: contextFile });
    const search = await harness.context({ query: "migration" });
    expect(search.content[0]?.text).toContain("the migration is pending");
    expect(search.content[0]?.text).not.toContain("staging cluster");
    const expanded = await harness.context({ refs: ["e1"] });
    expect(expanded.content[0]?.text).toContain("deploy the staging cluster");
  });

  it("explains a missing snapshot instead of failing the turn silently", async () => {
    const harness = load({
      [ENV_TASK_ID]: "task-7",
      [ENV_TASK_REVISION]: "1",
      [ENV_TASK_CONTEXT_FILE]: join(root, "missing.json"),
    });
    await expect(harness.context({})).rejects.toThrow(/snapshot is unavailable/);
  });
});

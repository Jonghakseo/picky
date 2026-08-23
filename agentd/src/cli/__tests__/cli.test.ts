import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { writeConnectionInfo } from "../../connection-info-store.js";
import { PROTOCOL_VERSION, type EventEnvelope, type PickyAgentSession } from "../../protocol.js";

function sessionFixture(overrides: Partial<PickyAgentSession>): Record<string, unknown> {
  return {
    id: overrides.id ?? "session-fixture",
    title: overrides.title ?? "Fixture",
    status: overrides.status ?? "running",
    createdAt: overrides.createdAt ?? new Date().toISOString(),
    updatedAt: overrides.updatedAt ?? new Date().toISOString(),
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    queuedSteers: [],
    queuedFollowUps: [],
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    activitySummary: { edit: 0, bash: 0, thinking: 0, other: 0, read: 0, write: 0 },
    ...overrides,
  } as unknown as Record<string, unknown>;
}
import { startMockAgentd, type MockAgentd } from "./mock-agentd.js";

const execFileAsync = promisify(execFile);

const here = fileURLToPath(new URL(".", import.meta.url));
const cliEntry = resolve(here, "..", "..", "cli.ts");
const tsxBin = resolve(here, "..", "..", "..", "node_modules", ".bin", "tsx");

let server: MockAgentd;
let appSupportDir: string;

beforeEach(async () => {
  server = await startMockAgentd();
  server.onCommand("listDockGroups", (_, send) => {
    send({ type: "dockGroupsSnapshot", groups: [] });
  });
  appSupportDir = await mkdtemp(join(tmpdir(), "picky-cli-test-"));
  await writeConnectionInfo(appSupportDir, {
    protocolVersion: PROTOCOL_VERSION,
    url: `ws://127.0.0.1:${server.port}`,
    token: server.token,
    port: server.port,
    pid: process.pid,
    appSupportDir,
    defaultCwd: appSupportDir,
    startedAt: new Date().toISOString(),
  });
});

afterEach(async () => {
  await server.stop();
});

async function runCli(args: string[], env: NodeJS.ProcessEnv = {}): Promise<{ stdout: string; stderr: string; code: number }> {
  try {
    const result = await execFileAsync(tsxBin, [cliEntry, ...args], {
      env: { ...process.env, PICKY_APP_SUPPORT_DIR: appSupportDir, ...env },
    });
    return { stdout: result.stdout, stderr: result.stderr, code: 0 };
  } catch (error) {
    const err = error as { stdout?: string; stderr?: string; code?: number };
    return { stdout: err.stdout ?? "", stderr: err.stderr ?? "", code: err.code ?? 1 };
  }
}

describe("picky cli", () => {
  it("submit forwards text and resolves on externalEntryAck", async () => {
    server.onCommand("submitMainFromExternal", (command, send) => {
      send({
        type: "externalEntryAck",
        commandId: (command as { id: string }).id,
        kind: "submitMain",
        sessionId: "main-1",
      });
    });

    const result = await runCli(["submit", "hello", "--no-context", "--cwd", "/tmp/x"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Submitted to main session (session=main-1)");
    expect(server.received).toHaveLength(1);
    expect(server.received[0]).toMatchObject({ type: "submitMainFromExternal", text: "hello", captureContext: false, cwd: "/tmp/x" });
  });

  it("submit defaults captureContext to true when --no-context not passed", async () => {
    server.onCommand("submitMainFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "submitMain" });
    });
    const result = await runCli(["submit", "hi"]);
    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({ captureContext: true });
  });

  it("submit prints raw ack JSON when --json is passed", async () => {
    server.onCommand("submitMainFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "submitMain", sessionId: "main-9" });
    });
    const result = await runCli(["submit", "json please", "--json"]);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout);
    expect(parsed).toMatchObject({ type: "externalEntryAck", kind: "submitMain", sessionId: "main-9" });
  });

  it("pickle-create requires title and --instructions when not --empty", async () => {
    const missingTitle = await runCli(["pickle-create"]);
    expect(missingTitle.code).toBe(64);
    expect(missingTitle.stderr).toContain("Missing required <title>");

    const missingInstructions = await runCli(["pickle-create", "scope"]);
    expect(missingInstructions.code).toBe(64);
    expect(missingInstructions.stderr).toContain("Missing required --instructions");
  });

  it("pickle-create with --empty rejects title/instructions and acks ok", async () => {
    server.onCommand("createPickleFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "createPickle", sessionId: "pickle-empty-1" });
    });

    const conflict = await runCli(["pickle-create", "scope", "--empty"]);
    expect(conflict.code).toBe(64);
    expect(conflict.stderr).toContain("--empty cannot be combined");

    const ok = await runCli(["pickle-create", "--empty"]);
    expect(ok.code).toBe(0);
    expect(ok.stdout).toContain("Created empty Pickle (session=pickle-empty-1)");
  });

  it("pickle-create forwards instructions, cwd, captureContext, and trimmed group", async () => {
    server.onCommand("createPickleFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "createPickle", sessionId: "pickle-2" });
    });
    const result = await runCli([
      "pickle-create",
      "Audit",
      "--instructions",
      "Check things",
      "--cwd",
      "/tmp/audit",
      "--group",
      "  Research  ",
      "--no-context",
    ]);
    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({
      type: "createPickleFromExternal",
      title: "Audit",
      instructions: "Check things",
      cwd: "/tmp/audit",
      group: "Research",
      captureContext: false,
    });
  });

  it("pickle-create rejects a blank --group", async () => {
    const result = await runCli(["pickle-create", "Audit", "--instructions", "Check things", "--group", "   "]);
    expect(result.code).toBe(64);
    expect(result.stderr).toContain("--group cannot be empty");
    expect(server.received).toHaveLength(0);
  });

  it("pickle-create --empty forwards a trimmed group", async () => {
    server.onCommand("createPickleFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "createPickle", sessionId: "pickle-empty-group" });
    });
    const result = await runCli(["pickle-create", "--empty", "--group", "  Research  "]);
    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({
      type: "createPickleFromExternal",
      group: "Research",
    });
  });

  it("pickle-list includes each visible session's dock group id and name", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({
        type: "sessionSnapshot",
        sessions: [
          sessionFixture({ id: "p-1", title: "First", status: "running", cwd: "/tmp/a" }),
          sessionFixture({ id: "p-2", title: "Second", status: "completed", archived: true }),
        ],
      });
    });
    server.onCommand("listDockGroups", (_, send) => {
      send({
        type: "dockGroupsSnapshot",
        groups: [{ id: "group-1", name: "Research", color: 6, memberSessionIds: ["p-1"], collapsed: false }],
      });
    });
    const result = await runCli(["pickle-list"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("p-1\trunning\tFirst cwd=/tmp/a groupId=group-1 group=Research");
    expect(result.stdout).not.toContain("p-2\tcompleted\tSecond");
  });

  it("pickle-list --include-archived includes archived sessions", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({
        type: "sessionSnapshot",
        sessions: [
          sessionFixture({ id: "p-1", title: "First", status: "running" }),
          sessionFixture({ id: "p-2", title: "Second", status: "completed", archived: true }),
        ],
      });
    });
    const result = await runCli(["pickle-list", "--include-archived"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("p-1\trunning\tFirst");
    expect(result.stdout).toContain("p-2\tcompleted\tSecond");
  });

  it("pickle-list --json emits the filtered snapshot with dock-group metadata", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "visible" }), sessionFixture({ id: "archived", archived: true })] });
    });
    server.onCommand("listDockGroups", (_, send) => {
      send({
        type: "dockGroupsSnapshot",
        groups: [{ id: "group-json", name: "JSON group", color: 4, memberSessionIds: ["visible"], collapsed: true }],
      });
    });
    const result = await runCli(["pickle-list", "--json"]);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout);
    expect(parsed).toMatchObject({
      type: "sessionSnapshot",
      sessions: [{
        id: "visible",
        dockGroup: { id: "group-json", name: "JSON group", color: 4, collapsed: true },
      }],
    });
    expect(parsed.sessions).toHaveLength(1);
    expect(parsed.sessions[0].dockGroup).not.toHaveProperty("memberSessionIds");
  });

  it("pickle-list --archived prints only archived sessions with archive metadata", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({
        type: "sessionSnapshot",
        sessions: [
          sessionFixture({ id: "visible", title: "Visible", status: "running" }),
          sessionFixture({ id: "archived", title: "Archived", status: "completed", archived: true, archivedAt: "2026-07-01T00:00:00.000Z" }),
        ],
      });
    });
    const result = await runCli(["pickle-list", "--archived"]);
    expect(result.code).toBe(0);
    expect(result.stdout).not.toContain("visible\trunning\tVisible");
    expect(result.stdout).toContain("archived\tcompleted\tArchived archived=true archivedAt=2026-07-01T00:00:00.000Z");
  });

  it("pickle-list --query filters the selected session set", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({
        type: "sessionSnapshot",
        sessions: [
          sessionFixture({ id: "p-1", title: "Sentry audit", status: "completed", archived: true }),
          sessionFixture({ id: "p-2", title: "Release notes", status: "completed", archived: true }),
        ],
      });
    });
    const result = await runCli(["pickle-list", "--archived", "--query", "sentry"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("p-1\tcompleted\tSentry audit");
    expect(result.stdout).not.toContain("p-2\tcompleted\tRelease notes");
  });

  it("pickle-list rejects ambiguous archive filters", async () => {
    const result = await runCli(["pickle-list", "--archived", "--include-archived"]);
    expect(result.code).toBe(64);
    expect(result.stderr).toContain("--archived cannot be combined with --include-archived");
  });

  it("main-agent pickle-archive sends a caller-tagged setSessionArchived(true) and waits for the authoritative event", async () => {
    server.onCommand("getPickle", (command, send) => {
      const sessionId = (command as { sessionId: string }).sessionId;
      send({ type: "sessionUpdated", session: sessionFixture({ id: sessionId, title: "Archive me", status: "completed" }) });
    });
    server.onCommand("setPickleArchived", (command, send) => {
      const cmd = command as { sessionId: string; archived: boolean };
      send({ type: "sessionArchivedAuthoritative", sessionId: cmd.sessionId, archived: cmd.archived });
    });
    const result = await runCli(["pickle-archive", "p-1", "--from-main"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Archived Pickle p-1");
    expect(server.received.find((command) => (command as { type?: string }).type === "setPickleArchived")).toMatchObject({ type: "setPickleArchived", caller: "mainAgent", sessionId: "p-1", archived: true });
  });

  it("pickle-archive is a safe no-op for an already archived session", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-archived", title: "Archived", status: "completed", archived: true })] });
    });
    const result = await runCli(["pickle-archive", "p-archived"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Pickle already archived: p-archived");
    expect(server.received.some((command) => (command as { type?: string }).type === "setPickleArchived")).toBe(false);
  });

  it("pickle-unarchive sends setSessionArchived(false) and waits for the authoritative event", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "Restore me", status: "completed", archived: true })] });
    });
    server.onCommand("setPickleArchived", (command, send) => {
      const cmd = command as { sessionId: string; archived: boolean };
      send({ type: "sessionArchivedAuthoritative", sessionId: cmd.sessionId, archived: cmd.archived });
    });
    const result = await runCli(["pickle-unarchive", "p-1"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Restored Pickle p-1");
    expect(server.received.find((command) => (command as { type?: string }).type === "setPickleArchived")).toMatchObject({ type: "setPickleArchived", sessionId: "p-1", archived: false });
  });

  it("pickle-unarchive refuses an unknown session id", async () => {
    server.onCommand("listPickles", (command, send) => {
      void command;
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "Known", status: "completed", archived: true })] });
    });
    const result = await runCli(["pickle-unarchive", "missing"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Pickle session not found: missing");
    expect(server.received.some((command) => (command as { type?: string }).type === "setPickleArchived")).toBe(false);
  });

  it("pickle-group-list prints dock groups", async () => {
    server.onCommand("listDockGroups", (command, send) => {
      void command;
      send({
        type: "dockGroupsSnapshot",
        groups: [
          { id: "group-1", name: "Research", color: 6, memberSessionIds: ["p-1", "p-2"], collapsed: false },
        ],
      });
    });
    const result = await runCli(["pickle-group-list"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("group-1\tResearch\tmembers=2");
  });

  it("main-agent group list normalizes and bounds user-controlled fields", async () => {
    const longMemberId = `member-${"x".repeat(200)}`;
    server.onCommand("listDockGroups", (_, send) => {
      send({
        type: "dockGroupsSnapshot",
        groups: [{
          id: "group-1\nspoofed-row",
          name: `Research\t${"y".repeat(240)}`,
          color: 6,
          memberSessionIds: ["p-1\nspoofed-member", longMemberId],
          collapsed: false,
        }],
      });
    });

    const result = await runCli(["pickle-group-list", "--from-main"]);

    expect(result.code).toBe(0);
    expect(result.stdout.trim().split("\n")).toHaveLength(1);
    expect(result.stdout).toContain("group-1 spoofed-row\tResearch");
    expect(result.stdout).toContain("members=p-1 spoofed-member,member-");
    expect(result.stdout).toContain("…");
  });

  it("pickle-group-list --json emits dock groups JSON", async () => {
    server.onCommand("listDockGroups", (command, send) => {
      void command;
      send({ type: "dockGroupsSnapshot", groups: [{ id: "group-1", name: "Research", color: 6, memberSessionIds: [], collapsed: false }] });
    });
    const result = await runCli(["pickle-group-list", "--json"]);
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject([{ id: "group-1", name: "Research" }]);
  });

  it("main-agent pickle-create preserves the internal caller and uses current-context command", async () => {
    server.onCommand("createPickleFromMain", (command, send) => {
      send({
        type: "externalEntryAck",
        commandId: (command as { id: string }).id,
        kind: "createPickle",
        sessionId: "main-pickle-1",
      });
    });

    const result = await runCli([
      "pickle-create", "Audit", "--instructions", "Inspect the release", "--cwd", "/tmp/product", "--from-main",
    ]);

    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({
      type: "createPickleFromMain",
      caller: "mainAgent",
      title: "Audit",
      instructions: "Inspect the release",
      cwd: "/tmp/product",
    });
    expect(server.received[0]).not.toHaveProperty("captureContext");
  });

  it("ignores ambient PICKY_CLI_CALLER env so co-hosted sessions never inherit the main-agent identity", async () => {
    // Regression: the primary daemon prepends a shared `picky` wrapper to PATH for
    // every in-process session. When the wrapper exported PICKY_CLI_CALLER=mainAgent,
    // a Pickle running `picky pickle-create --no-context` was routed to
    // createPickleFromMain and rejected with "No active Picky main context to hand off".
    server.onCommand("createPickleFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "createPickle", sessionId: "pickle-ext-env" });
    });

    const result = await runCli(
      ["pickle-create", "Orchestrator", "--instructions", "Rewrite setup", "--no-context"],
      { PICKY_CLI_CALLER: "mainAgent" },
    );

    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({ type: "createPickleFromExternal", captureContext: false });
    expect(server.received[0]).not.toHaveProperty("caller");
  });

  it("accepts --from-main before the subcommand name", async () => {
    server.onCommand("listPickles", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [] });
    });

    const result = await runCli(["--from-main", "pickle-list"]);

    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({ type: "listPickles", caller: "mainAgent" });
  });

  it("main-agent list bounds rows and normalizes user-controlled fields", async () => {
    const firstSessionId = `p-1\nspoofed-row-${"x".repeat(160)}`;
    server.onCommand("listPickles", (_, send) => {
      send({
        type: "sessionSnapshot",
        sessions: Array.from({ length: 25 }, (_, index) => sessionFixture({
          id: index === 0 ? firstSessionId : `p-${index + 1}`,
          title: index === 0 ? `Pickle\t${"y".repeat(240)}` : `Pickle ${index + 1}`,
          cwd: index === 0 ? `/tmp\n${"z".repeat(240)}` : undefined,
          ...(index === 0 ? { lastSummary: "Found a\nrelease risk", changedFiles: [{ path: "src/a.ts", status: "M" }] } : {}),
        })),
      });
    });
    server.onCommand("listDockGroups", (_, send) => {
      send({
        type: "dockGroupsSnapshot",
        groups: [{
          id: "group-1\nspoofed-group-id",
          name: `Research\t${"g".repeat(240)}`,
          color: 6,
          memberSessionIds: [firstSessionId],
          collapsed: false,
        }],
      });
    });

    const result = await runCli(["pickle-list", "--from-main"]);
    expect(result.code).toBe(0);
    expect(result.stdout.trim().split("\n")).toHaveLength(10);
    expect(result.stdout).toContain("p-1 spoofed-row-");
    expect(result.stdout).toContain("Pickle y");
    expect(result.stdout).toContain("cwd=/tmp z");
    expect(result.stdout).toContain("updatedAt=");
    expect(result.stdout).toContain("groupId=group-1 spoofed-group-id");
    expect(result.stdout).toContain("group=Research g");
    expect(result.stdout).toContain("changedFiles=1");
    expect(result.stdout).toContain("summary=Found a release risk");
    expect(result.stdout).toContain("…");
    expect(server.received[0]).toMatchObject({ type: "listPickles", caller: "mainAgent" });

    const json = await runCli(["pickle-list", "--json", "--from-main"]);
    expect(json.code).toBe(64);
    expect(json.stderr).toContain("--json is not available");
  });

  it("main-agent CLI rejects recursive submit, PTT, wait, and empty Pickle creation", async () => {
    expect((await runCli(["submit", "recurse", "--from-main"])).code).toBe(64);
    expect((await runCli(["ptt", "press", "--from-main"])).code).toBe(64);
    expect((await runCli(["pickle-create", "Audit", "--instructions", "Inspect", "--wait", "--from-main"])).code).toBe(64);
    expect((await runCli(["pickle-create", "--empty", "--from-main"])).code).toBe(64);
    expect(server.received).toEqual([]);
  });

  it("main-agent pickle-steer uses child-aware preflight and sends a caller-tagged control", async () => {
    server.onCommand("getPickle", (command, send) => {
      send({ type: "sessionUpdated", session: sessionFixture({ id: (command as { sessionId: string }).sessionId, title: "T", status: "running" }) });
    });
    server.onCommand("controlPickle", (command, send) => {
      send({ type: "sessionUpdated", session: sessionFixture({ id: (command as { sessionId: string }).sessionId, title: "T", status: "running" }) });
    });

    const result = await runCli(["pickle-steer", "p-1", "focus on tests", "--from-main"]);

    expect(result.code).toBe(0);
    expect(server.received.find((command) => (command as { type?: string }).type === "controlPickle")).toMatchObject({
      type: "controlPickle",
      pickleAction: "steer",
      caller: "mainAgent",
      sessionId: "p-1",
      text: "focus on tests",
    });
  });

  it("group CLI commands map to explicit app-owned mutations", async () => {
    server.onCommand("manageDockGroups", (_, send) => {
      send({ type: "dockGroupsSnapshot", groups: [] });
    });
    expect((await runCli(["pickle-group-create", "Research", "p-1", "p-2", "--from-main"])).code).toBe(0);
    expect((await runCli(["pickle-group-add", "group-1", "p-3", "--from-main"])).code).toBe(0);
    expect((await runCli(["pickle-group-remove-members", "group-1", "p-1", "--from-main"])).code).toBe(0);
    expect((await runCli(["pickle-group-remove", "group-1", "--from-main"])).code).toBe(0);
    expect((await runCli(["pickle-group-delete", "group-1", "--from-main"])).code).toBe(64);
    expect((await runCli(["pickle-group-delete", "group-1", "--archive-members", "--confirm", "--from-main"])).code).toBe(0);

    const mutations = server.received.filter((command) => (command as { type?: string }).type === "manageDockGroups");
    expect(mutations).toEqual([
      expect.objectContaining({ caller: "mainAgent", groupAction: "create", name: "Research", sessionIds: ["p-1", "p-2"] }),
      expect.objectContaining({ caller: "mainAgent", groupAction: "addMembers", groupId: "group-1", sessionIds: ["p-3"] }),
      expect.objectContaining({ caller: "mainAgent", groupAction: "removeMembers", groupId: "group-1", sessionIds: ["p-1"] }),
      expect.objectContaining({ caller: "mainAgent", groupAction: "removeGroup", groupId: "group-1" }),
      expect.objectContaining({ caller: "mainAgent", groupAction: "archiveGroup", groupId: "group-1" }),
    ]);
  });

  it("submit surfaces server errorMessage with exit code 1", async () => {
    server.onCommand("submitMainFromExternal", (command, send) => {
      send({ type: "externalEntryAck", commandId: (command as { id: string }).id, kind: "submitMain", errorMessage: "boom" });
    });
    const result = await runCli(["submit", "fail me"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("boom");
  });

  it("exits 2 when connection info is missing", async () => {
    await server.stop();
    const empty = await mkdtemp(join(tmpdir(), "picky-cli-empty-"));
    const { execFile } = await import("node:child_process");
    const exec = promisify(execFile);
    let stderr = "";
    let code = 0;
    try {
      await exec(tsxBin, [cliEntry, "submit", "hi"], {
        env: { ...process.env, PICKY_APP_SUPPORT_DIR: empty },
      });
    } catch (error) {
      const err = error as { stderr?: string; code?: number };
      stderr = err.stderr ?? "";
      code = err.code ?? 1;
    }
    expect(code).toBe(2);
    expect(stderr).toContain("Picky daemon is not reachable");
  });

  it("pickle-followup sends a child-aware follow-up control and prints queued message", async () => {
    server.onCommand("listPickles", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "T", status: "running" })] });
    });
    server.onCommand("controlPickle", (command, send) => {
      const cmd = command as { sessionId: string };
      send({
        type: "sessionUpdated",
        session: sessionFixture({ id: cmd.sessionId, title: "T", status: "running" }),
      });
    });
    const result = await runCli(["pickle-followup", "p-1", "more please"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Queued follow-up for p-1");
    expect(server.received.find((command) => (command as { type?: string }).type === "controlPickle")).toMatchObject({ type: "controlPickle", pickleAction: "followUp", sessionId: "p-1", text: "more please" });
  });

  it("pickle-followup refuses to steer an archived Pickle and never sends followUp", async () => {
    server.onCommand("listPickles", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-archived", title: "A", status: "completed", archived: true })] });
    });
    const result = await runCli(["pickle-followup", "p-archived", "hey"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("is archived");
    expect(server.received.some((command) => (command as { type?: string }).type === "controlPickle")).toBe(false);
  });

  it("pickle-followup refuses an unknown session id and never sends followUp", async () => {
    server.onCommand("listPickles", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "T", status: "running" })] });
    });
    const result = await runCli(["pickle-followup", "p-missing", "hey"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Pickle session not found: p-missing");
    expect(server.received.some((command) => (command as { type?: string }).type === "controlPickle")).toBe(false);
  });

  it("pickle-abort sends a child-aware abort control and prints requested message", async () => {
    server.onCommand("listPickles", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "T", status: "running" })] });
    });
    server.onCommand("controlPickle", (command, send) => {
      const cmd = command as { sessionId: string };
      send({
        type: "sessionMetaUpdated",
        session: sessionFixture({ id: cmd.sessionId, title: "T", status: "cancelled" }),
      });
    });
    const result = await runCli(["pickle-abort", "p-1"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Abort requested for p-1");
  });

  it("pickle-abort refuses to abort an archived Pickle and never sends abort", async () => {
    server.onCommand("listPickles", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-archived", title: "A", status: "running", archived: true })] });
    });
    const result = await runCli(["pickle-abort", "p-archived"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("is archived");
    expect(server.received.some((command) => (command as { type?: string }).type === "controlPickle")).toBe(false);
  });

  it("ptt press and release send push-to-talk control commands", async () => {
    server.onCommand("controlPushToTalkFromExternal", (command, send) => {
      const cmd = command as { id: string; action: "press" | "release" };
      send({ type: "pushToTalkControlAck", commandId: cmd.id, action: cmd.action });
    });

    const press = await runCli(["ptt", "press"]);
    const release = await runCli(["ptt", "release"]);

    expect(press.code).toBe(0);
    expect(press.stdout).toContain("PTT press sent");
    expect(release.code).toBe(0);
    expect(release.stdout).toContain("PTT release sent");
    expect(server.received[0]).toMatchObject({ type: "controlPushToTalkFromExternal", action: "press" });
    expect(server.received[1]).toMatchObject({ type: "controlPushToTalkFromExternal", action: "release" });
  });

  it("settings commands request catalog values and preserve typed boolean and toggle inputs", async () => {
    server.onCommand("listPickySettings", (command, send) => {
      send({
        type: "pickySettingsAck",
        commandId: (command as { id: string }).id,
        result: { entries: [{ key: "cursor.visible", currentValue: true }] },
      });
    });
    server.onCommand("getPickySettings", (command, send) => {
      send({
        type: "pickySettingsAck",
        commandId: (command as { id: string }).id,
        result: { key: "cursor.visible", value: true },
      });
    });
    server.onCommand("setPickySettings", (command, send) => {
      const cmd = command as { id: string; key: string; value: unknown };
      send({
        type: "pickySettingsAck",
        commandId: cmd.id,
        result: { key: cmd.key, value: cmd.value, persisted: true, applied: true, restartRequired: false, revision: 4 },
      });
    });

    const list = await runCli(["settings-list"]);
    const get = await runCli(["settings-get", "cursor.visible", "--json"]);
    const boolSet = await runCli(["settings-set", "cursor.visible", "off"]);
    const toggleSet = await runCli(["settings-set", "hud.dockVisible", "toggle", "--display", "display-1"]);

    expect(list).toMatchObject({ code: 0 });
    expect(list.stdout).toContain("cursor.visible\ttrue");
    expect(get.code).toBe(0);
    expect(JSON.parse(get.stdout)).toMatchObject({ type: "pickySettingsAck", result: { key: "cursor.visible", value: true } });
    expect(boolSet.stdout).toContain("Updated cursor.visible=false");
    expect(toggleSet.stdout).toContain("Updated hud.dockVisible=toggle");
    expect(server.received).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: "setPickySettings", key: "cursor.visible", value: false }),
      expect.objectContaining({ type: "setPickySettings", key: "hud.dockVisible", value: "toggle", toggle: true, displayId: "display-1" }),
    ]));
  });

  it("settings-set rejects display targeting for settings other than hud.dockVisible", async () => {
    const result = await runCli(["settings-set", "cursor.visible", "true", "--display", "display-1"]);
    expect(result.code).toBe(64);
    expect(result.stderr).toContain("--display is available only for hud.dockVisible");
    expect(server.received).toHaveLength(0);
  });

  it("settings commands surface daemon error codes as CLI failures", async () => {
    server.onCommand("getPickySettings", (command, send) => {
      send({
        type: "error",
        commandId: (command as { id: string }).id,
        code: "SETTINGS_KEY_NOT_FOUND",
        message: "Unknown Picky setting: does.not.exist",
      });
    });
    const result = await runCli(["settings-get", "does.not.exist"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Unknown Picky setting: does.not.exist");
  });

  it("--help exits 0 and prints command list", async () => {
    const result = await runCli(["--help"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("submit");
    expect(result.stdout).toContain("pickle-create");
    expect(result.stdout).toContain("pickle-list");
    expect(result.stdout).toContain("pickle-archive");
    expect(result.stdout).not.toContain("pickle-remove");
    expect(result.stdout).not.toContain("pickle-delete");
    expect(result.stdout).toContain("pickle-followup");
    expect(result.stdout).toContain("pickle-abort");
    expect(result.stdout).toContain("ptt");
    expect(result.stdout).toContain("Examples:");
  });

  it("submit --wait stays connected and prints the quick reply", async () => {
    server.onCommand("submitMainFromExternal", (command, send) => {
      const id = (command as { id: string }).id;
      const contextId = "context-wait-1";
      send({ type: "externalEntryAck", commandId: id, kind: "submitMain", contextId });
      // Simulate the agent's downstream quickReply landing after the ack.
      setTimeout(() => send({ type: "quickReply", contextId, text: "hi from agent", replyKind: "main", originSource: "cli" }), 30);
    });
    const result = await runCli(["submit", "hi", "--wait"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Submitted to main session");
    expect(result.stdout).toContain("hi from agent");
  });

  it("submit --wait --json emits ack + reply payload", async () => {
    server.onCommand("submitMainFromExternal", (command, send) => {
      const id = (command as { id: string }).id;
      const contextId = "context-wait-json";
      send({ type: "externalEntryAck", commandId: id, kind: "submitMain", contextId, sessionId: "main-9" });
      setTimeout(() => send({ type: "quickReply", contextId, text: "json reply", replyKind: "main" }), 30);
    });
    const result = await runCli(["submit", "json mode", "--wait", "--json"]);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout) as { ack: { contextId: string; sessionId?: string }; reply: string };
    expect(parsed.ack.contextId).toBe("context-wait-json");
    expect(parsed.reply).toBe("json reply");
  });

  it("pickle-create --wait stays connected until the session reaches a terminal status", async () => {
    server.onCommand("createPickleFromExternal", (command, send) => {
      const id = (command as { id: string }).id;
      send({ type: "externalEntryAck", commandId: id, kind: "createPickle", sessionId: "pickle-wait-1", contextId: "context-pickle-wait" });
      // Running first, then a terminal status with a final answer.
      setTimeout(() => send({
        type: "sessionUpdated",
        session: sessionFixture({ id: "pickle-wait-1", title: "Wait pickle", status: "running" }),
      }), 20);
      setTimeout(() => send({
        type: "sessionUpdated",
        session: { ...sessionFixture({ id: "pickle-wait-1", title: "Wait pickle", status: "completed" }), finalAnswer: "pickle done" } as Record<string, unknown>,
      }), 50);
    });
    const result = await runCli(["pickle-create", "Wait pickle", "--instructions", "do it", "--wait"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Created Pickle (session=pickle-wait-1)");
    expect(result.stdout).toContain("pickle done");
  });

  it("--version prints the cli version", async () => {
    const result = await runCli(["--version"]);
    expect(result.code).toBe(0);
    expect(result.stdout.trim()).toBe("0.1.0");
  });
});

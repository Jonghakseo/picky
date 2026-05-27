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

async function runCli(args: string[]): Promise<{ stdout: string; stderr: string; code: number }> {
  try {
    const result = await execFileAsync(tsxBin, [cliEntry, ...args], {
      env: { ...process.env, PICKY_APP_SUPPORT_DIR: appSupportDir },
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

  it("pickle-create forwards instructions, cwd, and captureContext", async () => {
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
      "--no-context",
    ]);
    expect(result.code).toBe(0);
    expect(server.received[0]).toMatchObject({
      type: "createPickleFromExternal",
      title: "Audit",
      instructions: "Check things",
      cwd: "/tmp/audit",
      captureContext: false,
    });
  });

  it("pickle-list prints non-archived sessions in tab-separated form", async () => {
    server.onCommand("listSessions", (command, send) => {
      void command;
      send({
        type: "sessionSnapshot",
        sessions: [
          sessionFixture({ id: "p-1", title: "First", status: "running", cwd: "/tmp/a" }),
          sessionFixture({ id: "p-2", title: "Second", status: "completed", archived: true }),
        ],
      });
    });
    const result = await runCli(["pickle-list"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("p-1\trunning\tFirst cwd=/tmp/a");
    expect(result.stdout).not.toContain("p-2\tcompleted\tSecond");
  });

  it("pickle-list --include-archived includes archived sessions", async () => {
    server.onCommand("listSessions", (command, send) => {
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

  it("pickle-list --json emits the filtered snapshot", async () => {
    server.onCommand("listSessions", (command, send) => {
      void command;
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "visible" }), sessionFixture({ id: "archived", archived: true })] });
    });
    const result = await runCli(["pickle-list", "--json"]);
    expect(result.code).toBe(0);
    const parsed = JSON.parse(result.stdout);
    expect(parsed).toMatchObject({ type: "sessionSnapshot", sessions: [expect.objectContaining({ id: "visible" })] });
    expect(parsed.sessions).toHaveLength(1);
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

  it("pickle-followup sends followUp command and prints queued message", async () => {
    server.onCommand("listSessions", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "T", status: "running" })] });
    });
    server.onCommand("followUp", (command, send) => {
      const cmd = command as { sessionId: string };
      send({
        type: "sessionUpdated",
        session: sessionFixture({ id: cmd.sessionId, title: "T", status: "running" }),
      });
    });
    const result = await runCli(["pickle-followup", "p-1", "more please"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Queued follow-up for p-1");
    expect(server.received.find((command) => (command as { type?: string }).type === "followUp")).toMatchObject({ type: "followUp", sessionId: "p-1", text: "more please" });
  });

  it("pickle-followup refuses to steer an archived Pickle and never sends followUp", async () => {
    server.onCommand("listSessions", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-archived", title: "A", status: "completed", archived: true })] });
    });
    const result = await runCli(["pickle-followup", "p-archived", "hey"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("is archived");
    expect(server.received.some((command) => (command as { type?: string }).type === "followUp")).toBe(false);
  });

  it("pickle-followup refuses an unknown session id and never sends followUp", async () => {
    server.onCommand("listSessions", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "T", status: "running" })] });
    });
    const result = await runCli(["pickle-followup", "p-missing", "hey"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("Pickle session not found: p-missing");
    expect(server.received.some((command) => (command as { type?: string }).type === "followUp")).toBe(false);
  });

  it("pickle-abort sends abort command and prints requested message", async () => {
    server.onCommand("listSessions", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-1", title: "T", status: "running" })] });
    });
    server.onCommand("abort", (command, send) => {
      const cmd = command as { sessionId: string };
      send({
        type: "sessionUpdated",
        session: sessionFixture({ id: cmd.sessionId, title: "T", status: "cancelled" }),
      });
    });
    const result = await runCli(["pickle-abort", "p-1"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Abort requested for p-1");
  });

  it("pickle-abort refuses to abort an archived Pickle and never sends abort", async () => {
    server.onCommand("listSessions", (_, send) => {
      send({ type: "sessionSnapshot", sessions: [sessionFixture({ id: "p-archived", title: "A", status: "running", archived: true })] });
    });
    const result = await runCli(["pickle-abort", "p-archived"]);
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("is archived");
    expect(server.received.some((command) => (command as { type?: string }).type === "abort")).toBe(false);
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

  it("--help exits 0 and prints command list", async () => {
    const result = await runCli(["--help"]);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("submit");
    expect(result.stdout).toContain("pickle-create");
    expect(result.stdout).toContain("pickle-list");
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

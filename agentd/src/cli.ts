import { Command, Option } from "commander";
import type { EventEnvelope } from "./protocol.js";
import { loadCliConnection, PickyCliDaemonNotRunningError } from "./cli/connection-loader.js";
import { sendCommand, sendCommandAndWaitForReply, PickyCliConnectionError, PickyCliServerError, PickyCliTimeoutError } from "./cli/ws-client.js";

const VERSION = "0.1.0";

interface SharedOptions {
  json?: boolean;
}

const program = new Command();
program
  .name("picky")
  .description("Programmatic interface to a running Picky.app. Submits text into the main session, creates Pickles, and lists/aborts/follows up on existing Pickles.")
  .version(VERSION, "-v, --version", "Print the picky CLI version and exit")
  .addHelpText("after", `
Examples:
  $ picky submit "정리 좀 해줘"
  $ picky submit "context-free reminder" --no-context
  $ picky pickle-create "Sentry 조사" --instructions "최근 24h 에러 그룹 정리"
  $ picky pickle-create --empty
  $ picky pickle-create "리서치" --instructions "경쟁사 조사" --group "Research"
  $ picky pickle-list --json
  $ picky pickle-list --include-archived
  $ picky pickle-group-list
  $ picky pickle-followup pickle-abc "production 환경으로 다시"
  $ picky pickle-abort pickle-abc
  $ picky ptt press
  $ picky ptt release

Environment:
  PICKY_APP_SUPPORT_DIR   Override the directory containing agentd-connection.json
                          (default: ~/Library/Application Support/Picky)

Exit codes:
  0   success
  1   server-side error returned by picky-agentd
  2   Picky daemon not reachable (Picky.app likely not running)
  3   timed out waiting for daemon response
`);

program
  .command("submit <text>")
  .description("Send <text> into the Picky main session. By default Picky.app captures live desktop context (active app/window/screenshots).")
  .option("--no-context", "Skip app-side context capture; send the text alone with cwd/timestamp metadata only")
  .option("--cwd <path>", "Override the cwd attached to the captured context")
  .option("--wait", "Keep the connection open until the main agent's reply lands, then print it to stdout (default: fire-and-forget)")
  .option("--json", "Emit the raw ack JSON to stdout (with --wait, includes the reply text)")
  .addHelpText("after", `
Examples:
  $ picky submit "이 디자인 어떻게 줄일 수 있을까?"
  $ picky submit "queue this in the main agent" --no-context --cwd "$PWD"
  $ picky submit "표본 더 있으면 알려줘" --wait
`)
  .action(async (text: string, options: SharedOptions & { context?: boolean; cwd?: string; wait?: boolean }) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const command = {
        type: "submitMainFromExternal",
        text,
        captureContext: options.context !== false,
        ...(options.cwd ? { cwd: options.cwd } : {}),
      } as const;
      if (!options.wait) {
        const ack = await sendCommand(connection, command, { matchEvent: matchExternalEntryAck("submitMain") });
        printAck(ack, options.json, "Submitted to main session");
        return;
      }
      const { ack, replyText } = await sendCommandAndWaitForReply<ExternalEntryAck>(connection, command, {
        matchAck: matchExternalEntryAckParsed("submitMain"),
        matchReply: matchMainReplyForContext,
      });
      printWaitResult(ack, replyText, options.json, "Submitted to main session");
    });
  });

const pickleCreate = program
  .command("pickle-create [title]")
  .description("Create a Pickle session. Provide a title and --instructions for a workspace-scoped Pickle, or --empty for a blank Pickle.")
  .option("--instructions <text>", "Instructions to seed the new Pickle's prompt")
  .option("--empty", "Create an empty Pickle session (no title or instructions required)")
  .option("--cwd <path>", "Workspace cwd for the Pickle session (defaults to the captured context cwd)")
  .option("--group <name>", "Assign the new Pickle to a dock group by name (created if it doesn't exist; first match wins on duplicate names)")
  .option("--no-context", "Skip app-side context capture; build a neutral context using cwd/timestamp only")
  .option("--json", "Emit the raw ack JSON to stdout")
  .addHelpText("after", `
Examples:
  $ picky pickle-create "Sentry 조사" --instructions "최근 24h 에러 그룹 정리"
  $ picky pickle-create --empty
  $ picky pickle-create "release audit" --instructions "지난 주 머지 PR QA" --cwd "$PWD"
  $ picky pickle-create "리서치" --instructions "경쟁사 조사" --group "Research"
`)
  .option("--wait", "Keep the connection open until the Pickle finishes, then print its final answer (default: fire-and-forget)")
  .action(async (title: string | undefined, options: SharedOptions & { instructions?: string; empty?: boolean; context?: boolean; cwd?: string; group?: string; wait?: boolean }) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const group = options.group !== undefined ? options.group.trim() : undefined;
      if (options.group !== undefined && group?.length === 0) {
        fail("--group cannot be empty", 64);
      }
      if (options.empty) {
        if (title || options.instructions) {
          fail("--empty cannot be combined with a title or --instructions", 64);
        }
        const emptyCmd = {
          type: "createPickleFromExternal",
          title: "Untitled Pickle",
          instructions: "(empty pickle session)",
          captureContext: options.context !== false,
          ...(options.cwd ? { cwd: options.cwd } : {}),
          ...(group ? { group } : {}),
        } as const;
        if (!options.wait) {
          const ack = await sendCommand(connection, emptyCmd, { matchEvent: matchExternalEntryAck("createPickle") });
          printAck(ack, options.json, "Created empty Pickle");
          return;
        }
        const { ack, replyText } = await sendCommandAndWaitForReply<ExternalEntryAck>(connection, emptyCmd, {
          matchAck: matchExternalEntryAckParsed("createPickle"),
          matchReply: matchPickleFinalAnswerForSession,
        });
        printWaitResult(ack, replyText, options.json, "Created empty Pickle");
        return;
      }
      if (!title) {
        fail("Missing required <title>. Use `picky pickle-create --help` for usage, or pass --empty.", 64);
      }
      if (!options.instructions || options.instructions.trim().length === 0) {
        fail("Missing required --instructions. Use `picky pickle-create --help` for usage, or pass --empty.", 64);
      }
      const namedCmd = {
        type: "createPickleFromExternal",
        title,
        instructions: options.instructions,
        captureContext: options.context !== false,
        ...(options.cwd ? { cwd: options.cwd } : {}),
        ...(group ? { group } : {}),
      } as const;
      if (!options.wait) {
        const ack = await sendCommand(connection, namedCmd, { matchEvent: matchExternalEntryAck("createPickle") });
        printAck(ack, options.json, "Created Pickle");
        return;
      }
      const { ack, replyText } = await sendCommandAndWaitForReply<ExternalEntryAck>(connection, namedCmd, {
        matchAck: matchExternalEntryAckParsed("createPickle"),
        matchReply: matchPickleFinalAnswerForSession,
      });
      printWaitResult(ack, replyText, options.json, "Created Pickle");
    });
  });
void pickleCreate;

program
  .command("pickle-list")
  .description("List non-archived Pickle sessions shown in the Picky dock.")
  .option("--json", "Emit the session snapshot JSON to stdout")
  .option("--include-archived", "Include archived Pickle sessions hidden from the Picky dock")
  .action(async (options: SharedOptions & { includeArchived?: boolean }) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const snapshot = await sendCommand(connection, { type: "listSessions" }, {
        matchEvent: (event) => (event.type === "sessionSnapshot" ? event : null),
      });
      if (snapshot.type !== "sessionSnapshot") return;
      const sessions = options.includeArchived ? snapshot.sessions : snapshot.sessions.filter((session) => session.archived !== true);
      const visibleSnapshot = { ...snapshot, sessions };
      if (options.json) {
        process.stdout.write(`${JSON.stringify(visibleSnapshot, null, 2)}\n`);
        return;
      }
      if (sessions.length === 0) {
        process.stdout.write("(no sessions)\n");
        return;
      }
      for (const session of sessions) {
        const cwd = session.cwd ? ` cwd=${session.cwd}` : "";
        process.stdout.write(`${session.id}\t${session.status}\t${session.title}${cwd}\n`);
      }
    });
  });

program
  .command("pickle-group-list")
  .description("List Pickle dock groups defined in the Picky app dock.")
  .option("--json", "Emit the dock groups JSON to stdout")
  .addHelpText("after", `
Examples:
  $ picky pickle-group-list
  $ picky pickle-group-list --json
`)
  .action(async (options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const snapshot = await sendCommand(connection, { type: "listDockGroups" }, {
        matchEvent: (event) => (event.type === "dockGroupsSnapshot" ? event : null),
      });
      if (snapshot.type !== "dockGroupsSnapshot") return;
      const groups = snapshot.groups;
      if (options.json) {
        process.stdout.write(`${JSON.stringify(groups, null, 2)}\n`);
        return;
      }
      if (groups.length === 0) {
        process.stdout.write("(no groups)\n");
        return;
      }
      for (const group of groups) {
        const name = group.name.trim().length > 0 ? group.name : "(untitled)";
        process.stdout.write(`${group.id}\t${name}\tmembers=${group.memberSessionIds.length}\n`);
      }
    });
  });

const ptt = program
  .command("ptt")
  .description("Control Picky push-to-talk from external integrations such as hardware buttons.");

ptt
  .command("press")
  .description("Start a Picky push-to-talk turn, equivalent to pressing the configured PTT shortcut.")
  .option("--json", "Emit the raw ack JSON to stdout")
  .addHelpText("after", `
Examples:
  $ picky ptt press
`)
  .action(async (options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const ack = await sendCommand(connection, { type: "controlPushToTalkFromExternal", action: "press" }, {
        matchEvent: matchPushToTalkControlAck("press"),
      });
      printAck(ack, options.json, "PTT press sent");
    });
  });

ptt
  .command("release")
  .description("End the current Picky push-to-talk turn, equivalent to releasing the configured PTT shortcut.")
  .option("--json", "Emit the raw ack JSON to stdout")
  .addHelpText("after", `
Examples:
  $ picky ptt release
`)
  .action(async (options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const ack = await sendCommand(connection, { type: "controlPushToTalkFromExternal", action: "release" }, {
        matchEvent: matchPushToTalkControlAck("release"),
      });
      printAck(ack, options.json, "PTT release sent");
    });
  });
void ptt;

program
  .command("pickle-followup <session-id> <text>")
  .description("Append <text> as a follow-up turn to an existing Pickle session.")
  .option("--no-context", "Skip app-side context capture for the follow-up")
  .addHelpText("after", `
Examples:
  $ picky pickle-followup pickle-abc "production 환경으로 다시"
`)
  .action(async (sessionId: string, text: string, options: { context?: boolean }) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      await ensureSessionIsSteerable(connection, sessionId, "follow-up");
      // No bespoke ack event yet — the daemon does not return a "followUp accepted"
      // event today. Use a short ack timeout and resolve as soon as a session update
      // tagged with the same session id arrives, which the supervisor emits when the
      // queued follow-up lands.
      // For v1 we simply send the command and exit on the next sessionUpdated for
      // this session, with a small grace period.
      await sendCommand(connection, {
        type: "followUp",
        sessionId,
        text,
        ...(options.context === false ? {} : {}),
      }, {
        matchEvent: (event) => (event.type === "sessionUpdated" && (event as { session: { id: string } }).session.id === sessionId ? event : null),
        timeoutMs: 4_000,
      }).catch((error) => {
        // followUp does not strictly need an ack — if no sessionUpdated arrives in time,
        // the command was still sent. Surface only hard server errors.
        if (error instanceof PickyCliServerError) throw error;
        if (error instanceof PickyCliConnectionError) throw error;
      });
      process.stdout.write(`Queued follow-up for ${sessionId}\n`);
    });
  });

program
  .command("pickle-abort <session-id>")
  .description("Abort an in-flight Pickle session.")
  .addHelpText("after", `
Examples:
  $ picky pickle-abort pickle-abc
`)
  .action(async (sessionId: string) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      await ensureSessionIsSteerable(connection, sessionId, "abort");
      await sendCommand(connection, { type: "abort", sessionId }, {
        matchEvent: (event) => (event.type === "sessionUpdated" && (event as { session: { id: string } }).session.id === sessionId ? event : null),
        timeoutMs: 4_000,
      }).catch((error) => {
        if (error instanceof PickyCliServerError) throw error;
        if (error instanceof PickyCliConnectionError) throw error;
      });
      process.stdout.write(`Abort requested for ${sessionId}\n`);
    });
  });

/**
 * Sanity-check that the target Pickle exists and is not archived before we
 * fire `followUp` / `abort` at the daemon. Archived Pickles are hidden from
 * the Picky dock and the user has already opted out of touching them, so
 * steering or aborting them from the CLI is almost always a mistake (e.g. a
 * stale session id copy-pasted from an old `pickle-list --include-archived`
 * dump). The daemon enforces the same rule, but doing it here gives the user
 * a clear, non-generic error message and avoids issuing the side-effectful
 * command at all.
 */
async function ensureSessionIsSteerable(connection: Awaited<ReturnType<typeof loadCliConnection>>, sessionId: string, action: "follow-up" | "abort"): Promise<void> {
  const snapshot = await sendCommand(connection, { type: "listSessions" }, {
    matchEvent: (event) => (event.type === "sessionSnapshot" ? event : null),
  });
  if (snapshot.type !== "sessionSnapshot") return;
  const target = snapshot.sessions.find((session) => session.id === sessionId);
  if (!target) fail(`Pickle session not found: ${sessionId}`, 1);
  if (target.archived === true) {
    fail(`Pickle session ${sessionId} is archived; un-archive it from the Picky dock before sending a ${action}.`, 1);
  }
}

async function runWithErrorHandling(action: () => Promise<void>): Promise<void> {
  try {
    await action();
  } catch (error) {
    if (error instanceof PickyCliDaemonNotRunningError) {
      process.stderr.write(`picky: ${error.message}\n`);
      process.exit(2);
    }
    if (error instanceof PickyCliTimeoutError) {
      process.stderr.write(`picky: ${error.message}\n`);
      process.exit(3);
    }
    if (error instanceof PickyCliServerError) {
      process.stderr.write(`picky: ${error.message}\n`);
      process.exit(1);
    }
    if (error instanceof PickyCliConnectionError) {
      process.stderr.write(`picky: ${error.message}\n`);
      process.exit(2);
    }
    process.stderr.write(`picky: ${(error as Error).message ?? String(error)}\n`);
    process.exit(1);
  }
}

function fail(message: string, code: number): never {
  process.stderr.write(`picky: ${message}\n`);
  process.exit(code);
}

interface ExternalEntryAck {
  commandId: string;
  kind: string;
  sessionId?: string;
  contextId?: string;
  errorMessage?: string;
}

type PushToTalkControlAction = "press" | "release";

interface PushToTalkControlAck {
  commandId: string;
  action: PushToTalkControlAction;
}

function matchPushToTalkControlAck(action: PushToTalkControlAction): (event: EventEnvelope, commandId: string) => EventEnvelope | null {
  return (event, commandId) => {
    if (event.type !== "pushToTalkControlAck") return null;
    const ack = event as unknown as PushToTalkControlAck;
    if (ack.commandId !== commandId) return null;
    if (ack.action !== action) return null;
    return event;
  };
}

function matchExternalEntryAck(kind: "submitMain" | "createPickle"): (event: EventEnvelope, commandId: string) => EventEnvelope | null {
  return (event, commandId) => {
    if (event.type !== "externalEntryAck") return null;
    const ack = event as unknown as ExternalEntryAck;
    if (ack.commandId !== commandId) return null;
    if (ack.kind !== kind) return null;
    if (ack.errorMessage) {
      throw new PickyCliServerError("external_entry_failed", ack.errorMessage, commandId);
    }
    return event;
  };
}

function matchExternalEntryAckParsed(kind: "submitMain" | "createPickle"): (event: EventEnvelope, commandId: string) => ExternalEntryAck | null {
  const inner = matchExternalEntryAck(kind);
  return (event, commandId) => {
    const matched = inner(event, commandId);
    return matched ? (matched as unknown as ExternalEntryAck) : null;
  };
}

/**
 * Reply matcher for `submit --wait`: the route may have taken the quick_reply path
 * (main agent answers without opening a Pickle) or the create path (a new Pickle
 * session whose first message is the assistant reply). Match whichever lands.
 */
function matchMainReplyForContext(event: EventEnvelope, ack: ExternalEntryAck): string | null {
  if (event.type === "quickReply" && (event as { contextId?: string }).contextId === ack.contextId) {
    return (event as { text?: string }).text ?? "";
  }
  if (ack.sessionId && event.type === "sessionUpdated") {
    const session = (event as { session?: { id?: string; status?: string; finalAnswer?: string; lastSummary?: string } }).session;
    if (session?.id === ack.sessionId && (session.status === "completed" || session.status === "failed" || session.status === "cancelled")) {
      return session.finalAnswer ?? session.lastSummary ?? "";
    }
  }
  return null;
}

/**
 * Reply matcher for `pickle-create --wait`: hang on until the Pickle session
 * reaches a terminal status and surface its final answer.
 */
function matchPickleFinalAnswerForSession(event: EventEnvelope, ack: ExternalEntryAck): string | null {
  if (!ack.sessionId || event.type !== "sessionUpdated") return null;
  const session = (event as { session?: { id?: string; status?: string; finalAnswer?: string; lastSummary?: string } }).session;
  if (session?.id !== ack.sessionId) return null;
  if (session.status === "completed" || session.status === "failed" || session.status === "cancelled") {
    return session.finalAnswer ?? session.lastSummary ?? "";
  }
  return null;
}

function printAck(ack: ExternalEntryAck | EventEnvelope, asJson: boolean | undefined, defaultMessage: string): void {
  if (asJson) {
    process.stdout.write(`${JSON.stringify(ack, null, 2)}\n`);
    return;
  }
  const sessionId = (ack as { sessionId?: string }).sessionId;
  if (sessionId) {
    process.stdout.write(`${defaultMessage} (session=${sessionId})\n`);
  } else {
    process.stdout.write(`${defaultMessage}\n`);
  }
}

function printWaitResult(ack: ExternalEntryAck, replyText: string, asJson: boolean | undefined, defaultMessage: string): void {
  if (asJson) {
    process.stdout.write(`${JSON.stringify({ ack, reply: replyText }, null, 2)}\n`);
    return;
  }
  const sessionId = ack.sessionId;
  if (sessionId) process.stdout.write(`${defaultMessage} (session=${sessionId})\n`);
  else process.stdout.write(`${defaultMessage}\n`);
  if (replyText.length > 0) process.stdout.write(`${replyText}\n`);
}

// Use `Option`'s default fallback so commander's auto-help / --help / help <cmd> work
// out of the box without us having to think about edge cases.
void Option;

program.parseAsync(process.argv).catch((error) => {
  process.stderr.write(`picky: ${(error as Error).message ?? String(error)}\n`);
  process.exit(1);
});

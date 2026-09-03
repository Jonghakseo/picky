import { Command, Option } from "commander";
import type { DockGroup, EventEnvelope, PickyAgentSession } from "./protocol.js";
import { loadCliConnection, PickyCliDaemonNotRunningError } from "./cli/connection-loader.js";
import { sendCommand, sendCommandAndWaitForReply, PickyCliConnectionError, PickyCliServerError, PickyCliTimeoutError } from "./cli/ws-client.js";
import { sliceUtf16Safe } from "./domain/safe-truncate.js";

const VERSION = "0.1.0";

interface SharedOptions {
  json?: boolean;
}

interface PickleGroupListOptions extends SharedOptions {
  includeArchived?: boolean;
}

interface PickleListOptions extends SharedOptions {
  rawJson?: boolean;
  includeArchived?: boolean;
  archived?: boolean;
  query?: string;
  limit?: string;
}

interface CompactPickleListDockGroup {
  id: string;
  name: string;
  color: number;
  collapsed: boolean;
}

interface CompactPickleListArtifact {
  id: string;
  kind: string;
  title: string;
  url?: string;
  updatedAt: string;
}

interface CompactPickleListSession {
  id: string;
  title: string;
  status: PickyAgentSession["status"];
  cwd?: string;
  createdAt: string;
  updatedAt: string;
  archived: boolean;
  archivedAt?: string;
  artifacts: CompactPickleListArtifact[];
  dockGroup?: CompactPickleListDockGroup;
}

interface CompactPickleListEnvelope {
  type: "pickleList";
  schemaVersion: 1;
  sessions: CompactPickleListSession[];
}

interface PickleCreateOptions extends SharedOptions {
  instructions?: string;
  empty?: boolean;
  context?: boolean;
  cwd?: string;
  group?: string;
  wait?: boolean;
}

type SessionSnapshotEvent = Extract<EventEnvelope, { type: "sessionSnapshot" }>;
type SessionArchivedAuthoritativeEvent = Extract<EventEnvelope, { type: "sessionArchivedAuthoritative" }>;

// Set from the explicit `--from-main` flag in a preAction hook. The Picky main
// agent identifies itself per invocation; ambient environment variables are
// intentionally not consulted so sessions sharing the daemon environment (for
// example Pickles hosted in the primary daemon) can never inherit the
// main-agent identity by accident.
let isMainAgentCaller = false;
let callerFields: { caller: "mainAgent" } | Record<string, never> = {};
const MAIN_AGENT_LIST_DEFAULT = 10;
const MAIN_AGENT_LIST_MAX = 20;
const MAIN_AGENT_ID_MAX_CHARS = 128;
const MAIN_AGENT_TEXT_MAX_CHARS = 200;

const program = new Command();
program
  .name("picky")
  .description("Programmatic interface to a running Picky.app. Creates and manages Pickles, dock groups, push-to-talk, and main-session submissions.")
  .version(VERSION, "-v, --version", "Print the picky CLI version and exit")
  .option("--from-main", "Identify this invocation as the Picky main agent: pickle-create hands off the current main-turn context and list output stays compact")
  .addHelpText("after", `
Examples:
  $ picky submit "정리 좀 해줘"
  $ picky submit "context-free reminder" --no-context
  $ picky pickle-create "Sentry 조사" --instructions "최근 24h 에러 그룹 정리"
  $ picky pickle-create --empty
  $ picky pickle-create "리서치" --instructions "경쟁사 조사" --group "Research"
  $ picky pickle-list --json
  $ picky pickle-list --include-archived
  $ picky pickle-list --archived --query "sentry"
  $ picky pickle-archive pickle-abc
  $ picky pickle-unarchive pickle-abc
  $ picky pickle-steer pickle-abc "production 환경으로 다시"
  $ picky pickle-abort pickle-abc
  $ picky pickle-group-list
  $ picky pickle-group-create "Research" pickle-abc pickle-def
  $ picky pickle-group-add group-abc pickle-ghi
  $ picky pickle-group-remove group-abc
  $ picky ptt press
  $ picky ptt release
  $ picky settings-list
  $ picky settings-set hud.dockVisible toggle
  $ picky settings-set cursor.visible off

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
      rejectForMainAgent("submit");
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
  .action(async (title: string | undefined, options: PickleCreateOptions) => {
    await runWithErrorHandling(() => runPickleCreate(title, options));
  });
void pickleCreate;

async function runPickleCreate(title: string | undefined, options: PickleCreateOptions): Promise<void> {
  if (isMainAgentCaller && options.wait) fail("--wait is not available from the Picky main agent", 64);
  if (isMainAgentCaller && options.empty) fail("--empty is not available from the Picky main agent", 64);
  const group = options.group?.trim();
  if (options.group !== undefined && !group) fail("--group cannot be empty", 64);
  const connection = await loadCliConnection();
  if (options.empty) return await createEmptyPickle(connection, title, options, group);
  return await createNamedPickle(connection, title, options, group);
}

async function createEmptyPickle(
  connection: Awaited<ReturnType<typeof loadCliConnection>>,
  title: string | undefined,
  options: PickleCreateOptions,
  group: string | undefined,
): Promise<void> {
  if (title || options.instructions) fail("--empty cannot be combined with a title or --instructions", 64);
  const command = {
    type: "createPickleFromExternal" as const,
    title: "Untitled Pickle",
    instructions: "(empty pickle session)",
    captureContext: options.context !== false,
    ...(options.cwd ? { cwd: options.cwd } : {}),
    ...(group ? { group } : {}),
  };
  if (!options.wait) {
    const ack = await sendCommand(connection, command, { matchEvent: matchExternalEntryAck("createPickle") });
    printAck(ack, options.json, "Created empty Pickle");
    return;
  }
  const { ack, replyText } = await sendCommandAndWaitForReply<ExternalEntryAck>(connection, command, {
    matchAck: matchExternalEntryAckParsed("createPickle"),
    matchReply: matchPickleFinalAnswerForSession,
  });
  printWaitResult(ack, replyText, options.json, "Created empty Pickle");
}

async function createNamedPickle(
  connection: Awaited<ReturnType<typeof loadCliConnection>>,
  title: string | undefined,
  options: PickleCreateOptions,
  group: string | undefined,
): Promise<void> {
  if (!title) fail("Missing required <title>. Use `picky pickle-create --help` for usage, or pass --empty.", 64);
  const instructions = options.instructions?.trim();
  if (!instructions) fail("Missing required --instructions. Use `picky pickle-create --help` for usage, or pass --empty.", 64);
  const command = isMainAgentCaller
    ? { type: "createPickleFromMain" as const, title, instructions, ...callerFields, ...(options.cwd ? { cwd: options.cwd } : {}), ...(group ? { group } : {}) }
    : { type: "createPickleFromExternal" as const, title, instructions, captureContext: options.context !== false, ...(options.cwd ? { cwd: options.cwd } : {}), ...(group ? { group } : {}) };
  if (!options.wait) {
    const ack = await sendCommand(connection, command, { matchEvent: matchExternalEntryAck("createPickle") });
    printAck(ack, options.json, "Created Pickle");
    return;
  }
  const { ack, replyText } = await sendCommandAndWaitForReply<ExternalEntryAck>(connection, command, {
    matchAck: matchExternalEntryAckParsed("createPickle"),
    matchReply: matchPickleFinalAnswerForSession,
  });
  printWaitResult(ack, replyText, options.json, "Created Pickle");
}

program
  .command("pickle-list")
  .description("List non-archived Pickle sessions shown in the Picky dock.")
  .option("--json", "Emit stable compact JSON for automation (safe allowlisted session, artifact, and dock-group fields)")
  .option("--raw-json", "Emit the legacy filtered session snapshot; may contain sensitive session details")
  .option("--include-archived", "Include archived Pickle sessions hidden from the Picky dock")
  .option("--archived", "List only archived Pickle sessions hidden from the Picky dock")
  .option("--query <text>", "Filter the selected Pickle set by id, title, cwd, status, summary, or final answer")
  .option("--limit <count>", "Maximum rows to print (main-agent calls default to 10 and cap at 20)")
  .addHelpText("after", `
Examples:
  $ picky pickle-list
  $ picky pickle-list --json
  $ picky pickle-list --include-archived --json
  $ picky pickle-list --archived --query "sentry"
  $ picky pickle-list --raw-json  # legacy snapshot; may expose sensitive session details
`)
  .action(async (options: PickleListOptions) => {
    await runWithErrorHandling(async () => {
      if (options.archived && options.includeArchived) {
        fail("--archived cannot be combined with --include-archived", 64);
      }
      if (options.json && options.rawJson) fail("--json cannot be combined with --raw-json", 64);
      if (isMainAgentCaller && options.json) fail("--json is not available from the Picky main agent; use --query and --limit", 64);
      if (isMainAgentCaller && options.rawJson) fail("--raw-json is not available from the Picky main agent; use --query and --limit", 64);
      const connection = await loadCliConnection();
      const snapshot = await fetchSessionSnapshot(connection);
      const dockGroups = await fetchDockGroups(connection);
      const groupBySessionId = indexDockGroupsBySessionId(dockGroups);
      const sessions = filterSessionsForList(snapshot.sessions, options).slice(0, parseListLimit(options.limit));
      const enrichedSessions = sessions.map((session) => sessionWithDockGroup(session, groupBySessionId.get(session.id)));
      if (options.json) {
        const compactList: CompactPickleListEnvelope = {
          type: "pickleList",
          schemaVersion: 1,
          sessions: enrichedSessions.map(compactSessionForList),
        };
        process.stdout.write(`${JSON.stringify(compactList, null, 2)}\n`);
        return;
      }
      if (options.rawJson) {
        const visibleSnapshot = {
          ...snapshot,
          sessions: enrichedSessions,
        };
        process.stdout.write(`${JSON.stringify(visibleSnapshot, null, 2)}\n`);
        return;
      }
      if (sessions.length === 0) {
        process.stdout.write("(no sessions)\n");
        return;
      }
      for (const session of sessions) {
        process.stdout.write(`${formatSessionListRow(session, groupBySessionId.get(session.id))}\n`);
      }
    });
  });

program
  .command("pickle-archive <session-id>")
  .description("Archive a Pickle session so it is hidden from the Picky dock. Archived terminal Pickles follow Picky's 7-day retention window.")
  .option("--json", "Emit the archive-state event JSON to stdout")
  .addHelpText("after", `
Examples:
  $ picky pickle-archive pickle-abc
`)
  .action(async (sessionId: string, options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const session = await requireSessionForArchiveAction(connection, sessionId);
      if (session.archived === true) {
        printArchiveNoop(sessionId, true, options.json, session);
        return;
      }
      const event = await setPickleArchiveState(connection, sessionId, true);
      printArchiveStateResult(event, options.json, `Archived Pickle ${sessionId}`);
    });
  });

program
  .command("pickle-unarchive <session-id>")
  .description("Restore an archived Pickle session so it reappears in the Picky dock, if it is still within the retention window.")
  .option("--json", "Emit the archive-state event JSON to stdout")
  .addHelpText("after", `
Examples:
  $ picky pickle-unarchive pickle-abc
`)
  .action(async (sessionId: string, options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const session = await requireSessionForArchiveAction(connection, sessionId);
      if (session.archived !== true) {
        printArchiveNoop(sessionId, false, options.json, session);
        return;
      }
      const event = await setPickleArchiveState(connection, sessionId, false);
      printArchiveStateResult(event, options.json, `Restored Pickle ${sessionId}`);
    });
  });

program
  .command("pickle-group-list")
  .description("List Pickle dock groups defined in the Picky app dock.")
  .option("--json", "Emit the dock groups JSON to stdout")
  .option("--include-archived", "Include archived Pickle member IDs in main-agent output")
  .addHelpText("after", `
Examples:
  $ picky pickle-group-list
  $ picky pickle-group-list --from-main --include-archived
  $ picky pickle-group-list --json
`)
  .action(async (options: PickleGroupListOptions) => {
    await runWithErrorHandling(async () => {
      if (isMainAgentCaller && options.json) fail("--json is not available from the Picky main agent", 64);
      const connection = await loadCliConnection();
      const snapshot = await sendCommand(connection, { type: "listDockGroups", ...callerFields }, {
        matchEvent: (event) => (event.type === "dockGroupsSnapshot" ? event : null),
      });
      if (snapshot.type !== "dockGroupsSnapshot") return;
      const groups = isMainAgentCaller && !options.includeArchived
        ? excludeArchivedGroupMembers(snapshot.groups, (await fetchSessionSnapshot(connection)).sessions)
        : snapshot.groups;
      if (options.json) {
        process.stdout.write(`${JSON.stringify(groups, null, 2)}\n`);
        return;
      }
      if (groups.length === 0) {
        process.stdout.write("(no groups)\n");
        return;
      }
      for (const group of groups) {
        const name = isMainAgentCaller
          ? normalizeMainAgentListText(group.name, MAIN_AGENT_TEXT_MAX_CHARS) || "(untitled)"
          : group.name.trim().length > 0 ? group.name : "(untitled)";
        const members = isMainAgentCaller ? formatGroupMemberIDs(group.memberSessionIds) : String(group.memberSessionIds.length);
        const id = isMainAgentCaller ? normalizeMainAgentListText(group.id, MAIN_AGENT_ID_MAX_CHARS) : group.id;
        process.stdout.write(`${id}\t${name}\tmembers=${members}\n`);
      }
    });
  });

program
  .command("pickle-group-create <name> [session-ids...]")
  .description("Create a persisted Picky dock group, optionally with existing Pickle session IDs.")
  .action(async (name: string, sessionIds: string[]) => {
    await runWithErrorHandling(async () => {
      await runDockGroupMutation({ groupAction: "create", name, sessionIds });
    });
  });

program
  .command("pickle-group-add <group-id> <session-ids...>")
  .description("Move existing Pickles into a dock group by exact IDs.")
  .action(async (groupId: string, sessionIds: string[]) => {
    await runWithErrorHandling(async () => {
      await runDockGroupMutation({ groupAction: "addMembers", groupId, sessionIds });
    });
  });

program
  .command("pickle-group-remove-members <group-id> <session-ids...>")
  .description("Move members out of a group while keeping the Pickles active in the top-level dock.")
  .action(async (groupId: string, sessionIds: string[]) => {
    await runWithErrorHandling(async () => {
      await runDockGroupMutation({ groupAction: "removeMembers", groupId, sessionIds });
    });
  });

program
  .command("pickle-group-remove <group-id>")
  .description("Remove a dock group and keep all of its Pickles active at top level.")
  .action(async (groupId: string) => {
    await runWithErrorHandling(async () => {
      await runDockGroupMutation({ groupAction: "removeGroup", groupId });
    });
  });

program
  .command("pickle-group-delete <group-id>")
  .description("Remove a dock group and archive every Pickle in it. Requires explicit confirmation flags.")
  .option("--archive-members", "Archive every group member")
  .option("--confirm", "Confirm the destructive group operation")
  .action(async (groupId: string, options: { archiveMembers?: boolean; confirm?: boolean }) => {
    await runWithErrorHandling(async () => {
      if (!options.archiveMembers || !options.confirm) {
        fail("pickle-group-delete requires --archive-members --confirm", 64);
      }
      await runDockGroupMutation({ groupAction: "archiveGroup", groupId });
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
      rejectForMainAgent("ptt");
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
      rejectForMainAgent("ptt");
      const connection = await loadCliConnection();
      const ack = await sendCommand(connection, { type: "controlPushToTalkFromExternal", action: "release" }, {
        matchEvent: matchPushToTalkControlAck("release"),
      });
      printAck(ack, options.json, "PTT release sent");
    });
  });
void ptt;

program
  .command("settings-list")
  .description("List Picky settings that can be read or changed through the running app.")
  .option("--json", "Emit the raw settings acknowledgement JSON to stdout")
  .action(async (options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const ack = await sendCommand(connection, { type: "listPickySettings", ...callerFields }, {
        matchEvent: matchPickySettingsAck,
      });
      printPickySettingsResult("list", ack, options.json);
    });
  });

program
  .command("settings-get <key>")
  .description("Read one Picky setting by catalog key.")
  .option("--json", "Emit the raw settings acknowledgement JSON to stdout")
  .action(async (key: string, options: SharedOptions) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      const ack = await sendCommand(connection, { type: "getPickySettings", key, ...callerFields }, {
        matchEvent: matchPickySettingsAck,
      });
      printPickySettingsResult("get", ack, options.json);
    });
  });

program
  .command("settings-set <key> <value>")
  .description("Change one Picky setting. Boolean values accept true/false/on/off; toggle is available for catalog entries that allow it.")
  .option("--display <id>", "Target a display for hud.dockVisible")
  .option("--json", "Emit the raw settings acknowledgement JSON to stdout")
  .action(async (key: string, rawValue: string, options: SharedOptions & { display?: string }) => {
    await runWithErrorHandling(async () => {
      if (options.display && key !== "hud.dockVisible") {
        fail("--display is available only for hud.dockVisible", 64);
      }
      const parsed = parsePickySettingValue(rawValue);
      const connection = await loadCliConnection();
      const ack = await sendCommand(connection, {
        type: "setPickySettings",
        key,
        value: parsed.value,
        ...(parsed.toggle ? { toggle: true } : {}),
        ...(options.display ? { displayId: options.display } : {}),
        ...callerFields,
      }, {
        matchEvent: matchPickySettingsAck,
      });
      printPickySettingsResult("set", ack, options.json);
    });
  });

program
  .command("pickle-steer <session-id> <text>")
  .description("Steer an existing Pickle at its next steering point.")
  .action(async (sessionId: string, text: string) => {
    await runWithErrorHandling(async () => {
      const connection = await loadCliConnection();
      await ensureSessionIsSteerable(connection, sessionId, "follow-up");
      await sendPickleInput(connection, "steer", sessionId, text);
      process.stdout.write(`Steering sent to ${sessionId}\n`);
    });
  });

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
      // Exit on the next session update (full lifecycle or thin metadata) for
      // this session, with a small grace period.
      void options;
      await sendPickleInput(connection, "followUp", sessionId, text);
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
      await sendCommand(connection, { type: "controlPickle", pickleAction: "abort", sessionId, ...callerFields }, {
        matchEvent: (event) => isSessionUpdateFor(event, sessionId) ? event : null,
        timeoutMs: 4_000,
      });
      process.stdout.write(`Abort requested for ${sessionId}\n`);
    });
  });

async function sendPickleInput(
  connection: Awaited<ReturnType<typeof loadCliConnection>>,
  type: "steer" | "followUp",
  sessionId: string,
  text: string,
): Promise<void> {
  await sendCommand(connection, { type: "controlPickle", pickleAction: type, sessionId, text, ...callerFields }, {
    matchEvent: (event) => isSessionUpdateFor(event, sessionId) ? event : null,
    timeoutMs: 4_000,
  });
}

async function runDockGroupMutation(input: {
  groupAction: "create" | "addMembers" | "removeMembers" | "removeGroup" | "archiveGroup";
  groupId?: string;
  name?: string;
  sessionIds?: string[];
}): Promise<void> {
  const connection = await loadCliConnection();
  const snapshot = await sendCommand(connection, {
    type: "manageDockGroups",
    ...input,
    ...callerFields,
  }, {
    matchEvent: (event) => event.type === "dockGroupsSnapshot" ? event : null,
  });
  if (snapshot.type !== "dockGroupsSnapshot") return;
  process.stdout.write(`Updated Pickle dock groups (${snapshot.groups.length} groups)\n`);
}

function excludeArchivedGroupMembers(groups: DockGroup[], sessions: PickyAgentSession[]): DockGroup[] {
  const archivedSessionIds = new Set(
    sessions.filter((session) => session.archived === true).map((session) => session.id),
  );
  if (archivedSessionIds.size === 0) return groups;
  return groups.map((group) => ({
    ...group,
    memberSessionIds: group.memberSessionIds.filter((sessionId) => !archivedSessionIds.has(sessionId)),
  }));
}

function formatGroupMemberIDs(sessionIds: string[]): string {
  if (sessionIds.length === 0) return "none";
  const shown = sessionIds
    .slice(0, 50)
    .map((sessionId) => normalizeMainAgentListText(sessionId, MAIN_AGENT_ID_MAX_CHARS))
    .join(",");
  const remaining = sessionIds.length - 50;
  return remaining > 0 ? `${shown},…(+${remaining})` : shown;
}

function parseListLimit(raw: string | undefined): number {
  if (raw === undefined) return isMainAgentCaller ? MAIN_AGENT_LIST_DEFAULT : Number.MAX_SAFE_INTEGER;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < 1) fail("--limit must be a positive integer", 64);
  return isMainAgentCaller ? Math.min(parsed, MAIN_AGENT_LIST_MAX) : parsed;
}

function rejectForMainAgent(command: string): void {
  if (isMainAgentCaller) fail(`${command} cannot be called from the Picky main agent`, 64);
}

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
  const target = await fetchSessionByID(connection, sessionId);
  if (!target) fail(`Pickle session not found: ${sessionId}`, 1);
  if (target.archived === true) {
    fail(`Pickle session ${sessionId} is archived; un-archive it from the Picky dock before sending a ${action}.`, 1);
  }
}

async function requireSessionForArchiveAction(connection: Awaited<ReturnType<typeof loadCliConnection>>, sessionId: string): Promise<PickyAgentSession> {
  const target = await fetchSessionByID(connection, sessionId);
  if (!target) fail(`Pickle session not found: ${sessionId}`, 1);
  return target;
}

async function fetchSessionByID(connection: Awaited<ReturnType<typeof loadCliConnection>>, sessionId: string): Promise<PickyAgentSession | undefined> {
  if (!isMainAgentCaller) {
    const snapshot = await fetchSessionSnapshot(connection);
    return snapshot.sessions.find((session) => session.id === sessionId);
  }
  const event = await sendCommand(connection, { type: "getPickle", sessionId, ...callerFields }, {
    matchEvent: (candidate) => candidate.type === "sessionUpdated" && candidate.session.id === sessionId ? candidate : null,
  });
  return event.type === "sessionUpdated" ? event.session : undefined;
}

async function fetchSessionSnapshot(connection: Awaited<ReturnType<typeof loadCliConnection>>): Promise<SessionSnapshotEvent> {
  return await sendCommand(connection, { type: "listPickles", ...callerFields }, {
    matchEvent: (event) => (event.type === "sessionSnapshot" ? event as SessionSnapshotEvent : null),
  });
}

async function fetchDockGroups(connection: Awaited<ReturnType<typeof loadCliConnection>>): Promise<DockGroup[]> {
  const snapshot = await sendCommand(connection, { type: "listDockGroups", ...callerFields }, {
    matchEvent: (event) => event.type === "dockGroupsSnapshot" ? event : null,
  });
  return snapshot.type === "dockGroupsSnapshot" ? snapshot.groups : [];
}

function indexDockGroupsBySessionId(groups: DockGroup[]): Map<string, DockGroup> {
  const result = new Map<string, DockGroup>();
  for (const group of groups) {
    for (const sessionId of group.memberSessionIds) {
      if (!result.has(sessionId)) result.set(sessionId, group);
    }
  }
  return result;
}

type SessionWithDockGroup = PickyAgentSession & { dockGroup?: CompactPickleListDockGroup };

function sessionWithDockGroup(session: PickyAgentSession, group: DockGroup | undefined): SessionWithDockGroup {
  if (!group) return session;
  return {
    ...session,
    dockGroup: { id: group.id, name: group.name, color: group.color, collapsed: group.collapsed },
  };
}

function compactSessionForList(session: SessionWithDockGroup): CompactPickleListSession {
  const compactSession: CompactPickleListSession = {
    id: session.id,
    title: session.title,
    status: session.status,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    archived: session.archived === true,
    artifacts: session.artifacts.map(compactArtifactForList),
  };
  if (session.cwd !== undefined) compactSession.cwd = session.cwd;
  if (session.archivedAt !== undefined) compactSession.archivedAt = session.archivedAt;
  if (session.dockGroup !== undefined) {
    compactSession.dockGroup = {
      id: session.dockGroup.id,
      name: session.dockGroup.name,
      color: session.dockGroup.color,
      collapsed: session.dockGroup.collapsed,
    };
  }
  return compactSession;
}

function compactArtifactForList(artifact: PickyAgentSession["artifacts"][number]): CompactPickleListArtifact {
  const compactArtifact: CompactPickleListArtifact = {
    id: artifact.id,
    kind: artifact.kind,
    title: artifact.title,
    updatedAt: artifact.updatedAt,
  };
  if (artifact.url !== undefined) compactArtifact.url = artifact.url;
  return compactArtifact;
}

function filterSessionsForList(sessions: PickyAgentSession[], options: { includeArchived?: boolean; archived?: boolean; query?: string }): PickyAgentSession[] {
  const selected = options.archived
    ? sessions.filter((session) => session.archived === true)
    : options.includeArchived
      ? sessions
      : sessions.filter((session) => session.archived !== true);
  const query = options.query?.trim().toLowerCase();
  if (!query) return selected;
  return selected.filter((session) => sessionSearchText(session).includes(query));
}

function sessionSearchText(session: PickyAgentSession): string {
  return [
    session.id,
    session.title,
    session.cwd,
    session.status,
    session.lastSummary,
    session.finalAnswer,
  ].filter((value): value is string => typeof value === "string" && value.length > 0).join(" ").toLowerCase();
}

function formatSessionListRow(session: PickyAgentSession, group: DockGroup | undefined): string {
  const cwd = session.cwd ? ` cwd=${session.cwd}` : "";
  const archived = session.archived === true ? " archived=true" : "";
  const archivedAt = session.archived === true && session.archivedAt ? ` archivedAt=${session.archivedAt}` : "";
  const dockGroup = formatSessionDockGroup(group, false);
  if (!isMainAgentCaller) return `${session.id}\t${session.status}\t${session.title}${cwd}${archived}${archivedAt}${dockGroup}`;

  const pendingInput = session.pendingExtensionUiRequest ? " pendingInput=true" : "";
  const changedFiles = session.changedFiles.length > 0 ? ` changedFiles=${session.changedFiles.length}` : "";
  const summarySource = session.lastSummary ?? session.finalAnswer;
  const summary = summarySource
    ? ` summary=${normalizeMainAgentListText(summarySource, MAIN_AGENT_TEXT_MAX_CHARS)}`
    : "";
  const id = normalizeMainAgentListText(session.id, MAIN_AGENT_ID_MAX_CHARS);
  const title = normalizeMainAgentListText(session.title, MAIN_AGENT_TEXT_MAX_CHARS);
  const normalizedCwd = session.cwd ? ` cwd=${normalizeMainAgentListText(session.cwd, MAIN_AGENT_TEXT_MAX_CHARS)}` : "";
  const normalizedDockGroup = formatSessionDockGroup(group, true);
  return `${id}\t${session.status}\t${title}${normalizedCwd}${archived} updatedAt=${normalizeMainAgentListText(session.updatedAt, MAIN_AGENT_ID_MAX_CHARS)}${normalizedDockGroup}${pendingInput}${changedFiles}${summary}`;
}

function formatSessionDockGroup(group: DockGroup | undefined, normalize: boolean): string {
  if (!group) return "";
  const id = normalize ? normalizeMainAgentListText(group.id, MAIN_AGENT_ID_MAX_CHARS) : group.id;
  const name = normalize ? normalizeMainAgentListText(group.name, MAIN_AGENT_TEXT_MAX_CHARS) : group.name;
  return ` groupId=${id} group=${name || "(untitled)"}`;
}

function normalizeMainAgentListText(value: string, maxChars: number): string {
  return truncateCliText(value.replaceAll(/\s+/g, " ").trim(), maxChars);
}

function truncateCliText(value: string, maxChars: number): string {
  return value.length <= maxChars ? value : `${sliceUtf16Safe(value, maxChars - 1)}…`;
}

async function setPickleArchiveState(connection: Awaited<ReturnType<typeof loadCliConnection>>, sessionId: string, archived: boolean): Promise<SessionArchivedAuthoritativeEvent> {
  return await sendCommand(connection, { type: "setPickleArchived", sessionId, archived, ...callerFields }, {
    matchEvent: (event) => {
      if (event.type !== "sessionArchivedAuthoritative") return null;
      const archiveEvent = event as SessionArchivedAuthoritativeEvent;
      return archiveEvent.sessionId === sessionId && archiveEvent.archived === archived ? archiveEvent : null;
    },
  });
}

function printArchiveStateResult(event: SessionArchivedAuthoritativeEvent, asJson: boolean | undefined, message: string): void {
  if (asJson) {
    process.stdout.write(`${JSON.stringify(event, null, 2)}\n`);
    return;
  }
  process.stdout.write(`${message}\n`);
}

function printArchiveNoop(sessionId: string, archived: boolean, asJson: boolean | undefined, session: PickyAgentSession): void {
  if (asJson) {
    process.stdout.write(`${JSON.stringify({ session, noop: true }, null, 2)}\n`);
    return;
  }
  process.stdout.write(archived ? `Pickle already archived: ${sessionId}\n` : `Pickle already visible: ${sessionId}\n`);
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

type PickySettingsAck = Extract<EventEnvelope, { type: "pickySettingsAck" }>;

function matchPickySettingsAck(event: EventEnvelope, commandId: string): PickySettingsAck | null {
  if (event.type !== "pickySettingsAck" || event.commandId !== commandId) return null;
  return event;
}

function parsePickySettingValue(raw: string): { value: boolean | string; toggle?: true } {
  const normalized = raw.trim().toLowerCase();
  if (normalized === "true" || normalized === "on") return { value: true };
  if (normalized === "false" || normalized === "off") return { value: false };
  if (normalized === "toggle") return { value: raw, toggle: true };
  return { value: raw };
}

function printPickySettingsResult(action: "list" | "get" | "set", ack: PickySettingsAck, asJson: boolean | undefined): void {
  if (asJson) {
    process.stdout.write(`${JSON.stringify(ack, null, 2)}\n`);
    return;
  }
  const result = ack.result as Record<string, unknown>;
  if (action === "list" && Array.isArray(result.entries)) {
    for (const entry of result.entries) {
      if (!entry || typeof entry !== "object") continue;
      const { key, currentValue } = entry as { key?: unknown; currentValue?: unknown };
      if (typeof key === "string") process.stdout.write(`${key}\t${formatPickySettingValue(currentValue)}\n`);
    }
    return;
  }
  if (action === "get" && typeof result.key === "string") {
    process.stdout.write(`${result.key}=${formatPickySettingValue(result.value)}\n`);
    return;
  }
  if (action === "set" && typeof result.key === "string") {
    const applicationError = typeof result.errorMessage === "string" ? `: ${result.errorMessage}` : "";
    const applied = result.applied === false ? ` (saved but not applied${applicationError})` : "";
    process.stdout.write(`Updated ${result.key}=${formatPickySettingValue(result.value)}${applied}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

function formatPickySettingValue(value: unknown): string {
  return typeof value === "string" ? value : JSON.stringify(value);
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
  if (ack.sessionId && isSessionUpdate(event)) {
    const session = event.session;
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
  if (!ack.sessionId || !isSessionUpdate(event)) return null;
  const session = event.session;
  if (session?.id !== ack.sessionId) return null;
  if (session.status === "completed" || session.status === "failed" || session.status === "cancelled") {
    return session.finalAnswer ?? session.lastSummary ?? "";
  }
  return null;
}

function isSessionUpdate(event: EventEnvelope): event is Extract<EventEnvelope, { type: "sessionUpdated" | "sessionMetaUpdated" }> {
  return event.type === "sessionUpdated" || event.type === "sessionMetaUpdated";
}

function isSessionUpdateFor(event: EventEnvelope, sessionId: string): event is Extract<EventEnvelope, { type: "sessionUpdated" | "sessionMetaUpdated" }> {
  return isSessionUpdate(event) && event.session.id === sessionId;
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

// Accept `--from-main` both before and after the subcommand name.
function registerFromMainOption(command: Command): void {
  for (const sub of command.commands) {
    sub.option("--from-main", "Identify this invocation as the Picky main agent");
    registerFromMainOption(sub);
  }
}
registerFromMainOption(program);

program.hook("preAction", (_thisCommand, actionCommand) => {
  isMainAgentCaller = Boolean(actionCommand.optsWithGlobals().fromMain);
  callerFields = isMainAgentCaller ? { caller: "mainAgent" } : {};
});

program.parseAsync(process.argv).catch((error) => {
  process.stderr.write(`picky: ${(error as Error).message ?? String(error)}\n`);
  process.exit(1);
});

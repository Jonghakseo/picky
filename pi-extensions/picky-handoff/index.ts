import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_PROTOCOL_VERSION = "2026-07-19";
const DEFAULT_CONNECTION_FILE = join(homedir(), "Library", "Application Support", "Picky", "agentd-connection.json");
const DEFAULT_WAIT_FOR_IDLE_TIMEOUT_MS = 10_000;
const MAX_BRANCH_ENTRIES = 16;
const MAX_BRANCH_CHARS = 12_000;

type MinimalWebSocket = {
  send(data: string): void;
  close(): void;
  addEventListener(type: "open" | "message" | "error" | "close", listener: (event: { data?: unknown; error?: unknown; reason?: unknown }) => void): void;
};

type MinimalWebSocketConstructor = new (url: string | URL) => MinimalWebSocket;

interface PickyAgentdConnectionInfo {
  protocolVersion?: string;
  url: string;
  token: string;
  defaultCwd?: string;
}

interface PickyContextPacket {
  id: string;
  source: "text";
  capturedAt: string;
  transcript: string;
  cwd?: string;
  activeApp?: { name?: string; bundleId?: string };
  screenshots: [];
  warnings: string[];
}

interface PickyAgentSessionSummary {
  id: string;
  title: string;
  status: string;
}

interface PiCommandContext {
  cwd?: string;
  ui: { notify(message: string, level?: "info" | "warning" | "error" | "success"): void };
  isIdle(): boolean;
  abort(): void;
  waitForIdle(): Promise<void>;
  sessionManager: {
    getSessionFile(): string | undefined;
    getBranch(): unknown[];
  };
}

interface PiExtensionAPI {
  getSessionName(): string | undefined;
  registerCommand(name: string, options: { description: string; handler(args: string, ctx: PiCommandContext): Promise<void> }): void;
}

export default function pickyHandoffExtension(pi: PiExtensionAPI) {
  registerHandoffCommand(pi, "handoff-to-picky");
}

function registerHandoffCommand(pi: PiExtensionAPI, name: string): void {
  pi.registerCommand(name, {
    description: "Hand off this Pi session to Picky (idle: move as-is; busy: stop and auto-resume)",
    handler: async (args, ctx) => {
      try {
        const wasIdle = ctx.isIdle();
        if (!wasIdle) {
          ctx.abort();
          await waitForIdleWithTimeout(ctx);
        }
        const sessionName = pi.getSessionName();
        const cwd = ctx.cwd;
        const sessionFile = ctx.sessionManager.getSessionFile();
        const branch = ctx.sessionManager.getBranch();
        const connection = await readConnectionInfo();
        const protocolVersion = connection.protocolVersion || DEFAULT_PROTOCOL_VERSION;
        const id = `pi-handoff-${Date.now()}-${Math.random().toString(16).slice(2)}`;
        const baseContext = {
          id,
          source: "text" as const,
          capturedAt: new Date().toISOString(),
          cwd: cwd || connection.defaultCwd,
          activeApp: { name: "Pi", bundleId: "dev.pi.local" },
          screenshots: [] as [],
          warnings: ["Started from a Pi extension command; no desktop screenshots were captured for this handoff."],
        };

        if (wasIdle) {
          const goal = args.trim() || "Pin the current completed Pi task in Picky as a Pickle.";
          const title = makeTitle(goal, sessionName, cwd);
          const transcript = buildPinTranscript({ goal, title, cwd, sessionName, sessionFile, branch });
          const context: PickyContextPacket = { ...baseContext, transcript };
          const session = await sendPickyCommand(connection, {
            id: `cmd-${id}`,
            protocolVersion,
            type: "pinPickleSession",
            title,
            context,
          });
          ctx.ui.notify(`Picky Pickle pinned: ${session.title}`, "info");
          return;
        }

        const instructions = args.trim() || "continue";
        const title = makeTitle(instructions, sessionName, cwd);
        const transcript = buildContinueTranscript({ instructions, title, cwd, sessionName, sessionFile, branch });
        const context: PickyContextPacket = { ...baseContext, transcript };
        const session = await sendPickyCommand(connection, {
          id: `cmd-${id}`,
          protocolVersion,
          type: "createPickleFromHandoff",
          title,
          instructions,
          ...(cwd ? { cwd } : {}),
          context,
        });
        ctx.ui.notify(`Picky Pickle started: ${session.title}`, "info");
      } catch (error) {
        ctx.ui.notify(`Picky handoff failed: ${messageOf(error)}`, "error");
      }
    },
  });
}

async function readConnectionInfo(): Promise<PickyAgentdConnectionInfo> {
  const path = process.env.PICKY_AGENTD_CONNECTION_FILE || DEFAULT_CONNECTION_FILE;
  let contents: string;
  try {
    contents = await readFile(path, "utf8");
  } catch (error) {
    if (isMissingConnectionFileError(error)) {
      throw new Error(
        `Picky connection file not found: ${path}. Make sure the Picky app is running and that picky-agentd has started. If the diagnostic log shows PICKY_UNSUPPORTED_NODE, install Node 22.19.0 or newer and relaunch Picky.`,
      );
    }
    throw error;
  }
  const raw = JSON.parse(contents) as Partial<PickyAgentdConnectionInfo>;
  if (!raw.url || !raw.token) throw new Error(`Invalid Picky connection file: ${path}`);
  return { protocolVersion: raw.protocolVersion, url: raw.url, token: raw.token, defaultCwd: raw.defaultCwd };
}

function isMissingConnectionFileError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "ENOENT";
}

async function waitForIdleWithTimeout(ctx: PiCommandContext): Promise<void> {
  const timeoutMs = configuredWaitForIdleTimeoutMs();
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      ctx.waitForIdle(),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`Timed out waiting for the Pi turn to stop after ${timeoutMs}ms.`)), timeoutMs);
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function configuredWaitForIdleTimeoutMs(): number {
  const raw = process.env.PICKY_HANDOFF_WAIT_FOR_IDLE_TIMEOUT_MS?.trim();
  if (!raw) return DEFAULT_WAIT_FOR_IDLE_TIMEOUT_MS;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? Math.max(1, Math.floor(parsed)) : DEFAULT_WAIT_FOR_IDLE_TIMEOUT_MS;
}

async function sendPickyCommand(
  connection: PickyAgentdConnectionInfo,
  payload: Record<string, unknown>,
): Promise<PickyAgentSessionSummary> {
  const WebSocketCtor = (globalThis as unknown as { WebSocket?: MinimalWebSocketConstructor }).WebSocket;
  if (!WebSocketCtor) throw new Error("This Node.js runtime does not expose global WebSocket.");

  const url = new URL(connection.url);
  url.searchParams.set("token", connection.token);

  return await new Promise<PickyAgentSessionSummary>((resolve, reject) => {
    const ws = new WebSocketCtor(url);
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error("Timed out waiting for picky-agentd."));
    }, 10_000);

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify(payload));
    });

    ws.addEventListener("message", (event) => {
      const payload = parseEventData(event.data);
      if (!payload) return;
      if (payload.type === "error") {
        clearTimeout(timeout);
        ws.close();
        reject(new Error(typeof payload.message === "string" ? payload.message : "picky-agentd returned an error"));
        return;
      }
      if (payload.type === "sessionUpdated" && payload.session && typeof payload.session.id === "string") {
        clearTimeout(timeout);
        ws.close();
        resolve({ id: payload.session.id, title: String(payload.session.title || "Picky task"), status: String(payload.session.status || "queued") });
      }
    });

    ws.addEventListener("error", (event) => {
      clearTimeout(timeout);
      reject(new Error(`WebSocket error: ${messageOf(event.error ?? event.reason ?? "unknown")}`));
    });

    ws.addEventListener("close", () => clearTimeout(timeout));
  });
}

function buildPinTranscript(input: { goal: string; title: string; cwd?: string; sessionName?: string; sessionFile?: string; branch: unknown[] }): string {
  const lines = [
    input.title,
    "",
    "A Pi extension command pinned this idle/completed task to Picky as a completed Pickle card in the Picky dock.",
    "No new Pickle run has been started by this handoff. Treat the source Pi session as context for a future follow-up, not as an instruction to skip verification.",
    "",
    "## User handoff request",
    input.goal,
    "",
    "## Source Pi session",
    `- CWD: ${input.cwd || "(unknown)"}`,
    `- Session name: ${input.sessionName || "(not set)"}`,
    `- Session file: ${input.sessionFile || "(ephemeral or unavailable)"}`,
    "",
    "## Recent source-session branch excerpt",
    summarizeBranch(input.branch),
  ];
  return lines.join("\n");
}

function buildContinueTranscript(input: { instructions: string; title: string; cwd?: string; sessionName?: string; sessionFile?: string; branch: unknown[] }): string {
  const lines = [
    input.title,
    "",
    "A Pi extension command interrupted the source Pi session and spawned this new Pickle in Picky to continue the work.",
    "The kickoff instruction below has been sent as the first user message of this Pickle. Treat the branch excerpt as the state of the source session at the moment of handoff.",
    "",
    "## Kickoff instruction",
    input.instructions,
    "",
    "## Source Pi session",
    `- CWD: ${input.cwd || "(unknown)"}`,
    `- Session name: ${input.sessionName || "(not set)"}`,
    `- Session file: ${input.sessionFile || "(ephemeral or unavailable)"}`,
    "",
    "## Recent source-session branch excerpt",
    summarizeBranch(input.branch),
  ];
  return lines.join("\n");
}

function summarizeBranch(branch: unknown[]): string {
  const entries = branch.slice(-MAX_BRANCH_ENTRIES).map(formatEntry).filter(Boolean);
  const text = entries.join("\n\n").trim();
  if (!text) return "(No source-session messages were available.)";
  return text.length <= MAX_BRANCH_CHARS ? text : `${text.slice(0, MAX_BRANCH_CHARS - 1)}…`;
}

function formatEntry(entry: unknown): string {
  const record = asRecord(entry);
  if (record.type === "message") {
    const message = asRecord(record.message);
    return `### ${String(message.role || "message")}\n${formatContent(message.content)}`;
  }
  if (record.type === "compaction" || record.type === "branch_summary") {
    return `### ${record.type}\n${truncate(String(record.summary || ""), 1200)}`;
  }
  if (record.type === "custom_message") {
    return `### custom_message:${String(record.customType || "unknown")}\n${formatContent(record.content)}`;
  }
  return "";
}

function formatContent(content: unknown): string {
  if (typeof content === "string") return truncate(content, 1200);
  if (!Array.isArray(content)) return truncate(String(JSON.stringify(content) ?? ""), 1200);
  return content
    .map((part) => {
      const item = asRecord(part);
      if (item.type === "text") return String(item.text || "");
      if (item.type === "toolCall") return `[toolCall:${String(item.name || "unknown")}] ${truncate(String(JSON.stringify(item.arguments || {}) ?? ""), 500)}`;
      if (item.type === "image") return "[image]";
      if (item.type === "thinking") return "[thinking omitted]";
      return truncate(String(JSON.stringify(item) ?? ""), 500);
    })
    .filter(Boolean)
    .join("\n");
}

function parseEventData(data: unknown): Record<string, any> | undefined {
  try {
    if (typeof data === "string") return JSON.parse(data) as Record<string, any>;
    if (data instanceof ArrayBuffer) return JSON.parse(Buffer.from(data).toString("utf8")) as Record<string, any>;
    return JSON.parse(String(data)) as Record<string, any>;
  } catch {
    return undefined;
  }
}

function makeTitle(goal: string, sessionName?: string, cwd?: string): string {
  const basis = sessionName || goal || cwd || "current Pi session";
  return truncate(basis.replace(/\s+/g, " ").trim(), 44);
}

function truncate(value: string, maxChars: number): string {
  return value.length <= maxChars ? value : `${value.slice(0, Math.max(0, maxChars - 1))}…`;
}

function asRecord(value: unknown): Record<string, any> {
  return value && typeof value === "object" ? (value as Record<string, any>) : {};
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

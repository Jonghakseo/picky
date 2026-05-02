import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_PROTOCOL_VERSION = "2026-05-01";
const DEFAULT_CONNECTION_FILE = join(homedir(), "Library", "Application Support", "Picky", "agentd-connection.json");
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
  registerHandoffCommand(pi, "pin-as-side-agent");
  registerHandoffCommand(pi, "handoff-to-picky");
}

function registerHandoffCommand(pi: PiExtensionAPI, name: string): void {
  pi.registerCommand(name, {
    description: "Hand off the current Pi context to a Picky side agent",
    handler: async (args, ctx) => {
      try {
        const goal = args.trim() || "Continue the current Pi task in Picky as a side agent.";
        const title = makeTitle(goal, pi.getSessionName(), ctx.cwd);
        const connection = await readConnectionInfo();
        const transcript = buildTranscript({
          goal,
          title,
          cwd: ctx.cwd,
          sessionName: pi.getSessionName(),
          sessionFile: ctx.sessionManager.getSessionFile(),
          branch: ctx.sessionManager.getBranch() as unknown[],
        });
        const context: PickyContextPacket = {
          id: `pi-handoff-${Date.now()}-${Math.random().toString(16).slice(2)}`,
          source: "text",
          capturedAt: new Date().toISOString(),
          transcript,
          cwd: ctx.cwd || connection.defaultCwd,
          activeApp: { name: "Pi", bundleId: "dev.pi.local" },
          screenshots: [],
          warnings: ["Started from a Pi extension command; no desktop screenshots were captured for this handoff."],
        };
        const session = await createPickyTask(connection, context);
        ctx.ui.notify(`Picky 사이드 에이전트로 넘겼습니다: ${session.title}`, "info");
      } catch (error) {
        ctx.ui.notify(`Picky 핸드오프 실패: ${messageOf(error)}`, "error");
      }
    },
  });
}

async function readConnectionInfo(): Promise<PickyAgentdConnectionInfo> {
  const path = process.env.PICKY_AGENTD_CONNECTION_FILE || DEFAULT_CONNECTION_FILE;
  const raw = JSON.parse(await readFile(path, "utf8")) as Partial<PickyAgentdConnectionInfo>;
  if (!raw.url || !raw.token) throw new Error(`Invalid Picky connection file: ${path}`);
  return { protocolVersion: raw.protocolVersion, url: raw.url, token: raw.token, defaultCwd: raw.defaultCwd };
}

async function createPickyTask(connection: PickyAgentdConnectionInfo, context: PickyContextPacket): Promise<PickyAgentSessionSummary> {
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
      ws.send(
        JSON.stringify({
          id: `cmd-${context.id}`,
          protocolVersion: connection.protocolVersion || DEFAULT_PROTOCOL_VERSION,
          type: "createTask",
          context,
        }),
      );
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

function buildTranscript(input: { goal: string; title: string; cwd?: string; sessionName?: string; sessionFile?: string; branch: unknown[] }): string {
  const lines = [
    input.title,
    "",
    "A Pi extension command handed this task off to Picky so it can run as a visible side agent in the top-right HUD.",
    "Use the available Pi skills, extensions, MCPs, and local tools as appropriate. Treat the source Pi session as context, not as an instruction to skip verification.",
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
  const basis = goal || sessionName || cwd || "current Pi session";
  return `Pi handoff: ${truncate(basis.replace(/\s+/g, " ").trim(), 44)}`;
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

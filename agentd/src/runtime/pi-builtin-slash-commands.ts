import { logAgentd } from "../local-log.js";
import { messageOf } from "./pi-sdk-runtime-helpers.js";
import type { RuntimeEvent } from "./types.js";

export interface PiBuiltinSlashCommandHost {
  sessionId: string;
  emit(event: RuntimeEvent): void;
  newSession(): Promise<{ cancelled: boolean }>;
  setSessionName(name: string): void;
  compact(instructions?: string): Promise<void>;
  isStreaming(): boolean;
  isCompacting(): boolean;
  prepareReplacement(): Promise<void>;
  reloadGeneration(): number;
  reload(): Promise<{ supported: boolean }>;
  markReloadApplied(generation: number): void;
  waitForReloadReadiness(): Promise<void>;
}

// Pi exposes session.setSessionName(), runtime.newSession(), and session.compact() as public
// APIs but only its TUI interactive-mode wires them to /name, /new, and /compact slash commands.
// Picky doesn't run that mode, so we intercept the built-in slash commands here before they would otherwise be
// forwarded to the LLM as ordinary user text. The synthetic completed/noTurnRan status keeps
// higher layers from treating the call as a real agent turn (no Pickle-completion notification,
// no artifact materialization).
export async function handlePiBuiltinSlashCommand(text: string, host: PiBuiltinSlashCommandHost): Promise<boolean> {
  const trimmed = text.trim();
  if (trimmed === "/new") {
    try {
      const result = await host.newSession();
      if (result.cancelled) {
        host.emit({ type: "log", line: "/new cancelled by extension" });
        host.emit({ type: "status", status: "completed", summary: "/new cancelled", noTurnRan: true, preserveSessionState: true });
      }
    } catch (error) {
      const message = messageOf(error);
      logAgentd("slash /new failed", { sessionId: host.sessionId, error: message });
      host.emit({ type: "status", status: "failed", summary: `/new failed: ${message}`, noTurnRan: true });
    }
    return true;
  }
  if (trimmed === "/name" || trimmed.startsWith("/name ")) {
    const name = trimmed.replace(/^\/name\s*/, "").trim();
    if (!name) {
      host.emit({ type: "log", line: "/name requires a name argument (usage: /name <session name>)" });
      host.emit({ type: "status", status: "completed", summary: "/name: missing argument", noTurnRan: true, preserveSessionState: true });
      return true;
    }
    try {
      host.setSessionName(name);
      host.emit({ type: "log", line: `session renamed to "${name}"` });
      // Pi emits session_info_changed internally, so the title flips via the normalized event.
      host.emit({ type: "status", status: "completed", summary: `Session renamed to ${name}`, noTurnRan: true, preserveSessionState: true });
    } catch (error) {
      const message = messageOf(error);
      logAgentd("slash /name failed", { sessionId: host.sessionId, error: message });
      host.emit({ type: "log", line: `/name failed: ${message}` });
      host.emit({ type: "status", status: "completed", summary: `/name failed: ${message}`, noTurnRan: true, preserveSessionState: true });
    }
    return true;
  }
  if (trimmed === "/compact" || trimmed.startsWith("/compact ")) {
    const instructions = trimmed.replace(/^\/compact\s*/, "").trim() || undefined;
    await host.compact(instructions);
    return true;
  }
  if (trimmed === "/reload") {
    if (host.isStreaming()) {
      host.emit({ type: "log", line: "/reload rejected: wait for the current response to finish" });
      host.emit({ type: "status", status: "completed", summary: "/reload is unavailable while the agent is running", noTurnRan: true, preserveSessionState: true });
      return true;
    }
    if (host.isCompacting()) {
      host.emit({ type: "log", line: "/reload rejected: wait for compaction to finish" });
      host.emit({ type: "status", status: "completed", summary: "/reload is unavailable while the session is compacting", noTurnRan: true, preserveSessionState: true });
      return true;
    }
    await host.prepareReplacement();
    host.emit({ type: "status", status: "running", summary: "Reloading Pi resources…" });
    try {
      const reloadGeneration = host.reloadGeneration();
      const outcome = await host.reload();
      if (!outcome.supported) {
        host.emit({ type: "status", status: "failed", summary: "/reload is not supported by this Pi runtime", noTurnRan: true });
        return true;
      }
      // A manual reload also satisfies plugin reloads requested before it started.
      host.markReloadApplied(reloadGeneration);
      host.emit({ type: "log", line: "pi resources reloaded" });
      host.emit({ type: "status", status: "completed", summary: "Pi resources reloaded", noTurnRan: true });
      await host.waitForReloadReadiness();
    } catch (error) {
      const message = messageOf(error);
      logAgentd("slash /reload failed", { sessionId: host.sessionId, error: message });
      host.emit({ type: "status", status: "failed", summary: `/reload failed: ${message}`, noTurnRan: true });
    }
    return true;
  }
  return false;
}

//
// pi-capabilities.ts
//
// Centralised wrappers for every pi-coding-agent surface that we reach into via
// `session as unknown as { ... }` because the public AgentSession type does not
// formally expose it. Each wrapper:
//
//   1. Performs the unsafe cast in exactly one place so the next pi version
//      bump only needs auditing here and the pi-coupling.md doc.
//   2. Detects "method missing" at runtime and returns a discriminated result
//      (or `undefined`) so the caller can take a deterministic fallback path
//      instead of throwing TypeError.
//   3. Logs the first missing-capability observation per session via
//      `logAgentd`, so a pi upgrade that drops a method shows up loudly in
//      `agentd.stdout.log` even when the user-visible fallback is silent.
//
// Backward-compatibility: callers must always treat "capability unavailable"
// as a normal branch, never an error, so the daemon keeps running on older or
// reshuffled pi builds. Anything truly mandatory belongs in `pi-contract.test.ts`
// (smoke test) instead of a capability wrapper.
//

import type { AgentSession } from "@mariozechner/pi-coding-agent";
import type { ModelCycleDirection } from "../protocol.js";
import type { RuntimeBashExecutionResult, ThinkingLevel } from "./types.js";
import { logAgentd } from "../local-log.js";

export interface PiContextUsage {
  tokens: number | null;
  contextWindow: number;
  percent: number | null;
}

export interface PiCycleModelResult {
  thinkingLevel?: ThinkingLevel;
}

export interface PiModelMetadata {
  api?: string;
  provider?: string;
  modelId?: string;
}

// "session.extensionRunner.emitUserBash" payload shape Picky has historically passed in.
export interface PiUserBashEvent {
  command: string;
  excludeFromContext: boolean;
  cwd: string;
}

// Per-process record of (sessionId, capability) pairs we have already warned about. Stops the
// per-session log from repeating on every turn while still keeping the first observation loud.
const warnedAbsences = new Set<string>();

function warnOnceForAbsence(sessionId: string, capability: string): void {
  const key = `${sessionId}::${capability}`;
  if (warnedAbsences.has(key)) return;
  warnedAbsences.add(key);
  logAgentd("pi capability absent", { sessionId, capability });
}

/** Per-process map of (sessionId -> set of capabilities recorded as available). Lets the smoke
 *  test inspect which capabilities a session actually exposed at runtime without hammering pi's
 *  internals from outside this module. */
const recordedPresence = new Map<string, Set<string>>();

function recordPresence(sessionId: string, capability: string): void {
  let set = recordedPresence.get(sessionId);
  if (!set) {
    set = new Set();
    recordedPresence.set(sessionId, set);
  }
  set.add(capability);
}

export function observedCapabilities(sessionId: string): ReadonlySet<string> {
  return recordedPresence.get(sessionId) ?? new Set();
}

/** Reset the per-process warn/observe caches. Tests rely on this; production code never calls it. */
export function __resetPiCapabilityCachesForTests(): void {
  warnedAbsences.clear();
  recordedPresence.clear();
}

// MARK: - Capability accessors

export function trySetThinkingLevel(session: AgentSession, sessionId: string, level: ThinkingLevel): boolean {
  const method = (session as unknown as { setThinkingLevel?: (level: ThinkingLevel) => void }).setThinkingLevel;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "setThinkingLevel");
    return false;
  }
  recordPresence(sessionId, "setThinkingLevel");
  method.call(session, level);
  return true;
}

export function tryCycleThinkingLevel(session: AgentSession, sessionId: string): ThinkingLevel | undefined {
  const method = (session as unknown as { cycleThinkingLevel?: () => ThinkingLevel | undefined }).cycleThinkingLevel;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "cycleThinkingLevel");
    return undefined;
  }
  recordPresence(sessionId, "cycleThinkingLevel");
  return method.call(session);
}

export async function tryCycleModel(
  session: AgentSession,
  sessionId: string,
  direction: ModelCycleDirection,
): Promise<PiCycleModelResult | undefined> {
  const method = (session as unknown as { cycleModel?: (direction: ModelCycleDirection) => Promise<PiCycleModelResult | undefined> }).cycleModel;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "cycleModel");
    return undefined;
  }
  recordPresence(sessionId, "cycleModel");
  return await method.call(session, direction);
}

export function tryGetContextUsage(session: AgentSession, sessionId: string): PiContextUsage | undefined {
  const method = (session as unknown as { getContextUsage?: () => PiContextUsage | undefined }).getContextUsage;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "getContextUsage");
    return undefined;
  }
  recordPresence(sessionId, "getContextUsage");
  return method.call(session);
}

export async function tryCompact(session: AgentSession, sessionId: string, instructions?: string): Promise<{ supported: true } | { supported: false }> {
  const method = (session as unknown as { compact?: (instructions?: string) => Promise<unknown> }).compact;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "compact");
    return { supported: false };
  }
  recordPresence(sessionId, "compact");
  await method.call(session, instructions);
  return { supported: true };
}

export async function tryReload(session: AgentSession, sessionId: string): Promise<{ supported: true } | { supported: false }> {
  const method = (session as unknown as { reload?: () => Promise<void> }).reload;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "reload");
    return { supported: false };
  }
  recordPresence(sessionId, "reload");
  await method.call(session);
  return { supported: true };
}

export function tryRefreshSystemPromptFromActiveTools(session: AgentSession, sessionId: string): boolean {
  const candidate = session as unknown as {
    getActiveToolNames?: () => string[];
    setActiveToolsByName?: (toolNames: string[]) => void;
  };
  if (typeof candidate.getActiveToolNames !== "function" || typeof candidate.setActiveToolsByName !== "function") {
    warnOnceForAbsence(sessionId, "getActiveToolNames/setActiveToolsByName");
    return false;
  }
  try {
    recordPresence(sessionId, "getActiveToolNames");
    recordPresence(sessionId, "setActiveToolsByName");
    candidate.setActiveToolsByName.call(session, candidate.getActiveToolNames.call(session));
    return true;
  } catch (error) {
    logAgentd("pi capability refresh system prompt failed", { sessionId, error: error instanceof Error ? error.message : String(error) });
    return false;
  }
}

export function isCompacting(session: AgentSession): boolean {
  return (session as unknown as { isCompacting?: boolean }).isCompacting === true;
}

// MARK: - User-bash bridge

export interface PiBashSurface {
  isBashRunning: boolean;
  executeBash: (command: string, onChunk?: (chunk: string) => void, options?: { excludeFromContext?: boolean; operations?: unknown }) => Promise<RuntimeBashExecutionResult>;
  recordBashResult: (command: string, result: RuntimeBashExecutionResult, options?: { excludeFromContext?: boolean }) => void;
  /**
   * If pi's session exposes `extensionRunner.emitUserBash`, this wrapper injects the
   * fixed `type: "user_bash"` discriminator so call sites don't have to remember the
   * pi-internal payload shape. Returns `undefined` when the underlying pi capability
   * is missing.
   */
  emitUserBash?: (event: PiUserBashEvent) => Promise<{ result?: unknown; operations?: unknown } | undefined>;
}

/**
 * Best-effort capture of pi's optional user-bash surface. Returns `undefined` if pi's session
 * doesn't expose bash execution at all (older builds, non-bash runtimes). Callers that need
 * bash must guard on the return value.
 */
export function tryGetBashSurface(session: AgentSession, sessionId: string): PiBashSurface | undefined {
  const candidate = session as unknown as {
    isBashRunning?: boolean;
    executeBash?: PiBashSurface["executeBash"];
    recordBashResult?: PiBashSurface["recordBashResult"];
    extensionRunner?: { emitUserBash?: (event: { type: "user_bash" } & PiUserBashEvent) => Promise<{ result?: unknown; operations?: unknown } | undefined> };
  };
  if (typeof candidate.executeBash !== "function" || typeof candidate.recordBashResult !== "function") {
    warnOnceForAbsence(sessionId, "executeBash/recordBashResult");
    return undefined;
  }
  recordPresence(sessionId, "executeBash");
  recordPresence(sessionId, "recordBashResult");
  const rawEmit = candidate.extensionRunner?.emitUserBash;
  if (typeof rawEmit === "function") {
    recordPresence(sessionId, "extensionRunner.emitUserBash");
  }
  const extensionRunner = candidate.extensionRunner;
  const emitUserBash = typeof rawEmit === "function"
    ? (event: PiUserBashEvent) => rawEmit.call(extensionRunner, { type: "user_bash", ...event })
    : undefined;
  return {
    isBashRunning: candidate.isBashRunning === true,
    executeBash: candidate.executeBash.bind(session),
    recordBashResult: candidate.recordBashResult.bind(session),
    emitUserBash,
  };
}

// MARK: - Model + thinking-level metadata

export function readModelMetadata(session: AgentSession): PiModelMetadata | undefined {
  const raw = (session as unknown as { state?: { model?: Record<string, unknown> } }).state?.model;
  if (!raw || typeof raw !== "object") return undefined;
  return {
    api: stringValue(raw.api),
    provider: stringValue(raw.provider),
    modelId: stringValue(raw.id),
  };
}

export function readThinkingLevel(session: AgentSession): ThinkingLevel | undefined {
  const direct = (session as unknown as { thinkingLevel?: unknown }).thinkingLevel;
  const fromDirect = parseThinkingLevel(direct);
  if (fromDirect) return fromDirect;
  const fromState = parseThinkingLevel((session as unknown as { state?: { thinkingLevel?: unknown } }).state?.thinkingLevel);
  return fromState;
}

function parseThinkingLevel(value: unknown): ThinkingLevel | undefined {
  if (value === "off" || value === "minimal" || value === "low" || value === "medium" || value === "high" || value === "xhigh") return value;
  return undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

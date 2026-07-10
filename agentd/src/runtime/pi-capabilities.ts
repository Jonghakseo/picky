//
// pi-capabilities.ts
//
// Centralised wrappers for the pi-coding-agent AgentSession surfaces Picky drives.
// As of pi 0.80.x these methods are part of the public AgentSession type, so each
// wrapper narrows the session to `Partial<Pick<AgentSession, ...>>` instead of an
// `as unknown as { ... }` hand-written shape: the method signatures are now checked
// against pi's real types, while `Partial` keeps every capability optional so the
// runtime guard below stays valid. Each wrapper:
//
//   1. Narrows to the capability in exactly one place so the next pi version bump
//      only needs auditing here and the pi-coupling.md doc.
//   2. Detects "method missing" at runtime and returns a discriminated result
//      (or `undefined`) so the caller can take a deterministic fallback path
//      instead of throwing TypeError. We keep this guard even though the types now
//      mark the methods present, because Picky must keep running on older or
//      reshuffled pi builds where a capability may be absent.
//   3. Logs the first missing-capability observation per session via `logAgentd`,
//      so a pi upgrade that drops a method shows up loudly in `agentd.stdout.log`
//      even when the user-visible fallback is silent.
//
// A few surfaces still need a structural cast where pi's published type diverges
// from Picky's local shape (e.g. ExtensionRunner.emitUserBash, which pi mangles in
// its public types); those are flagged inline.
//
// Backward-compatibility: callers must always treat "capability unavailable" as a
// normal branch, never an error, so the daemon keeps running on older or reshuffled
// pi builds. Anything truly mandatory belongs in `pi-contract.test.ts` (smoke test)
// instead of a capability wrapper.
//

import type { AgentSession } from "@earendil-works/pi-coding-agent";
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
  const method = (session as Partial<Pick<AgentSession, "setThinkingLevel">>).setThinkingLevel;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "setThinkingLevel");
    return false;
  }
  recordPresence(sessionId, "setThinkingLevel");
  method.call(session, level);
  return true;
}

export function tryCycleThinkingLevel(session: AgentSession, sessionId: string): ThinkingLevel | undefined {
  const method = (session as Partial<Pick<AgentSession, "cycleThinkingLevel">>).cycleThinkingLevel;
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
  const method = (session as Partial<Pick<AgentSession, "cycleModel">>).cycleModel;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "cycleModel");
    return undefined;
  }
  recordPresence(sessionId, "cycleModel");
  return await method.call(session, direction);
}

export function tryGetContextUsage(session: AgentSession, sessionId: string): PiContextUsage | undefined {
  const method = (session as Partial<Pick<AgentSession, "getContextUsage">>).getContextUsage;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "getContextUsage");
    return undefined;
  }
  recordPresence(sessionId, "getContextUsage");
  return method.call(session);
}

export async function tryCompact(session: AgentSession, sessionId: string, instructions?: string): Promise<{ supported: true } | { supported: false }> {
  const method = (session as Partial<Pick<AgentSession, "compact">>).compact;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "compact");
    return { supported: false };
  }
  recordPresence(sessionId, "compact");
  await method.call(session, instructions);
  return { supported: true };
}

export async function tryReload(session: AgentSession, sessionId: string): Promise<{ supported: true } | { supported: false }> {
  const method = (session as Partial<Pick<AgentSession, "reload">>).reload;
  if (typeof method !== "function") {
    warnOnceForAbsence(sessionId, "reload");
    return { supported: false };
  }
  recordPresence(sessionId, "reload");
  await method.call(session);
  return { supported: true };
}

export function tryRefreshSystemPromptFromActiveTools(session: AgentSession, sessionId: string): boolean {
  const candidate = session as Partial<Pick<AgentSession, "getActiveToolNames" | "setActiveToolsByName">>;
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
  return (session as Partial<Pick<AgentSession, "isCompacting">>).isCompacting === true;
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
  const candidate = session as Partial<Pick<AgentSession, "isBashRunning" | "executeBash" | "recordBashResult" | "extensionRunner">>;
  if (typeof candidate.executeBash !== "function" || typeof candidate.recordBashResult !== "function") {
    warnOnceForAbsence(sessionId, "executeBash/recordBashResult");
    return undefined;
  }
  recordPresence(sessionId, "executeBash");
  recordPresence(sessionId, "recordBashResult");
  // pi mangles ExtensionRunner.emitUserBash in its published types, so this single field stays structural.
  const runner = candidate.extensionRunner as undefined | {
    emitUserBash?: (event: { type: "user_bash" } & PiUserBashEvent) => Promise<{ result?: unknown; operations?: unknown } | undefined>;
  };
  const rawEmit = runner?.emitUserBash;
  if (typeof rawEmit === "function") {
    recordPresence(sessionId, "extensionRunner.emitUserBash");
  }
  const emitUserBash = typeof rawEmit === "function"
    ? (event: PiUserBashEvent) => rawEmit.call(runner, { type: "user_bash", ...event })
    : undefined;
  return {
    isBashRunning: candidate.isBashRunning === true,
    executeBash: candidate.executeBash.bind(session) as PiBashSurface["executeBash"],
    recordBashResult: candidate.recordBashResult.bind(session) as PiBashSurface["recordBashResult"],
    emitUserBash,
  };
}

// MARK: - Model + thinking-level metadata

export function readModelMetadata(session: AgentSession): PiModelMetadata | undefined {
  const model = session.model ?? readStateModelFallback(session);
  if (!model) return undefined;
  return {
    api: model.api,
    provider: model.provider,
    modelId: model.id,
  };
}

function readStateModelFallback(session: AgentSession): AgentSession["model"] | undefined {
  return ((session as Partial<Pick<AgentSession, "state">>).state as { model?: AgentSession["model"] } | undefined)?.model;
}

export function readThinkingLevel(session: AgentSession): ThinkingLevel | undefined {
  const direct = (session as Partial<Pick<AgentSession, "thinkingLevel">>).thinkingLevel;
  const fromDirect = parseThinkingLevel(direct);
  if (fromDirect) return fromDirect;
  const fromState = parseThinkingLevel((session as Partial<Pick<AgentSession, "state">>).state?.thinkingLevel);
  return fromState;
}

function parseThinkingLevel(value: unknown): ThinkingLevel | undefined {
  if (value === "off" || value === "minimal" || value === "low" || value === "medium" || value === "high" || value === "xhigh" || value === "max") return value;
  return undefined;
}

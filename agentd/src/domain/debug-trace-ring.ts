import { randomUUID } from "node:crypto";
import type { PickyContextPacket } from "../protocol.js";
import {
  DEBUG_TRACE_ID_MAX_LENGTH,
  DEBUG_TRACE_LABEL_MAX_LENGTH,
  DEBUG_TRACE_READ_DEFAULT_LIMIT,
  type DebugTraceRecord,
  type StoredDebugTraceRecord,
} from "../features/debug/schema.js";

/**
 * The always-on debug trace ring.
 *
 * It holds a bounded window of semantic transitions (input accepted, prompt
 * delivered, turn started, reply emitted) with no payload: the wire schema
 * allowlists the fields, and `normalizeDebugTraceRecord` clamps anything a
 * daemon call site passes directly. Reading is cursor-based, so a client polls
 * with the `nextSequence` it last saw and learns from `truncated` when the
 * window moved past its cursor.
 *
 * The ring is process-wide because instrumentation lives deep in the main-agent
 * and session paths, far from the socket that reads it. Each daemon process has
 * its own ring and `instanceId`; a restart produces a new id, which is how a
 * reader detects that sequence numbers restarted.
 */
export const DEBUG_TRACE_RING_CAPACITY = 2000;

export function debugInputModality(source: PickyContextPacket["source"] | undefined): "audio" | "text" {
  return source === "voice" || source === "voice-follow-up" ? "audio" : "text";
}

export interface DebugTraceReadQuery {
  afterSequence?: number;
  limit?: number;
}

export interface DebugTraceReadResult {
  instanceId: string;
  records: StoredDebugTraceRecord[];
  oldestSequence: number;
  nextSequence: number;
  truncated: boolean;
}

/** Everything but the fields the ring stamps itself. */
export type DaemonTraceFields = Omit<DebugTraceRecord, "source" | "name" | "timestamp" | "monotonicMs">;

export class DebugTraceRing {
  private readonly entries: StoredDebugTraceRecord[] = [];
  private nextSequenceNumber = 1;

  constructor(readonly instanceId: string, private readonly capacity: number = DEBUG_TRACE_RING_CAPACITY) {}

  record(record: DebugTraceRecord, receivedAt: string = new Date().toISOString()): StoredDebugTraceRecord {
    const stored: StoredDebugTraceRecord = {
      ...normalizeDebugTraceRecord(record),
      sequence: this.nextSequenceNumber,
      receivedAt,
    };
    this.nextSequenceNumber += 1;
    this.entries.push(stored);
    if (this.entries.length > this.capacity) this.entries.splice(0, this.entries.length - this.capacity);
    return stored;
  }

  read(query: DebugTraceReadQuery = {}): DebugTraceReadResult {
    const afterSequence = Math.max(0, Math.trunc(query.afterSequence ?? 0));
    const limit = Math.max(1, Math.trunc(query.limit ?? DEBUG_TRACE_READ_DEFAULT_LIMIT));
    const oldestSequence = this.entries[0]?.sequence ?? 0;
    const latestSequence = this.entries[this.entries.length - 1]?.sequence ?? 0;
    const records = this.entries.filter((entry) => entry.sequence > afterSequence).slice(0, limit);
    return {
      instanceId: this.instanceId,
      records,
      oldestSequence,
      // An empty page still advances the caller's cursor to the current end, so a
      // poller never re-reads the same window; a cursor ahead of the ring is kept.
      nextSequence: records[records.length - 1]?.sequence ?? Math.max(afterSequence, latestSequence),
      // Hitting `limit` is not truncation: those records are still retained and the
      // next cursor returns them. Only eviction loses transitions.
      truncated: oldestSequence > afterSequence + 1,
    };
  }

  get size(): number {
    return this.entries.length;
  }
}

/** Clamps a record to the wire bounds so a daemon call site cannot grow an entry without limit. */
export function normalizeDebugTraceRecord(record: DebugTraceRecord): DebugTraceRecord {
  const id = (value: string | undefined) => clamp(value, DEBUG_TRACE_ID_MAX_LENGTH);
  const label = (value: string | undefined) => clamp(value, DEBUG_TRACE_LABEL_MAX_LENGTH);
  const textLength = typeof record.textLength === "number" && Number.isFinite(record.textLength)
    ? Math.max(0, Math.trunc(record.textLength))
    : undefined;
  return {
    source: record.source,
    name: label(record.name) ?? "unknown",
    timestamp: record.timestamp,
    monotonicMs: Number.isFinite(record.monotonicMs) ? Math.max(0, record.monotonicMs) : 0,
    ...optional("inputId", id(record.inputId)),
    ...optional("contextId", id(record.contextId)),
    ...optional("sessionId", id(record.sessionId)),
    ...optional("commandId", id(record.commandId)),
    ...optional("state", label(record.state)),
    ...optional("previousState", label(record.previousState)),
    ...optional("outcome", label(record.outcome)),
    ...optional("event", label(record.event)),
    ...optional("target", label(record.target)),
    ...(record.modality ? { modality: record.modality } : {}),
    ...(textLength === undefined ? {} : { textLength }),
  };
}

function optional<Key extends string, Value>(key: Key, value: Value | undefined): Record<Key, Value> | Record<string, never> {
  return value === undefined ? {} : ({ [key]: value } as Record<Key, Value>);
}

function clamp(value: string | undefined, max: number): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed;
}

let sharedRing: DebugTraceRing | undefined;

/** The ring this daemon process records into and serves reads from. */
export function sharedDebugTraceRing(): DebugTraceRing {
  sharedRing ??= new DebugTraceRing(`picky-agentd-${randomUUID()}`);
  return sharedRing;
}

/**
 * Records a daemon-side transition. Instrumentation sits on production paths, so
 * this never throws and never allocates beyond one small record.
 */
export function recordDaemonTrace(name: string, fields: DaemonTraceFields = {}): void {
  try {
    sharedDebugTraceRing().record({
      source: "daemon",
      name,
      timestamp: new Date().toISOString(),
      monotonicMs: performance.now(),
      ...fields,
    });
  } catch {
    // Diagnostics must never break the path they observe.
  }
}

import type { EventEnvelope } from "../protocol.js";

type TraceRecord = Extract<EventEnvelope, { type: "debugTrace" }>["records"][number];
export interface DebugTraceFilter { input?: string; context?: string; session?: string; command?: string }

export function filterDebugTrace(records: TraceRecord[], filter: DebugTraceFilter): TraceRecord[] {
  return records.filter((record) => (!filter.input || record.inputId === filter.input)
    && (!filter.context || record.contextId === filter.context)
    && (!filter.session || record.sessionId === filter.session)
    && (!filter.command || record.commandId === filter.command));
}

/** Follow explicit command/input/context links, never temporal proximity or session reuse. */
export function debugTimeline(records: TraceRecord[], filter: DebugTraceFilter) {
  const links = new Set<string>();
  if (filter.input) links.add(`inputId:${filter.input}`);
  if (filter.context) links.add(`contextId:${filter.context}`);
  if (filter.command) links.add(`commandId:${filter.command}`);
  const recordLinks = (record: TraceRecord) => ["inputId", "contextId", "commandId"]
    .flatMap((key) => { const value = record[key as "inputId" | "contextId" | "commandId"]; return value ? [`${key}:${value}`] : []; });
  if (links.size) {
    let previousSize: number;
    do {
      previousSize = links.size;
      for (const record of records) {
        const ids = recordLinks(record);
        if (ids.some((id) => links.has(id))) for (const id of ids) links.add(id);
      }
    } while (links.size !== previousSize);
  }
  const selected = records.filter((record) => (!filter.session || record.sessionId === filter.session)
    && (!links.size || recordLinks(record).some((id) => links.has(id))));
  const clocks = new Map<string, { first: number; last: number }>();
  return selected.map((record) => {
    const clock = clocks.get(record.source);
    // A decreasing source clock could mean delayed delivery or a restarted source.
    // There is no source epoch on this wire, so mark the gap unknown and start a new segment.
    const discontinuity = clock !== undefined && record.monotonicMs < clock.last;
    const first = !clock || discontinuity ? record.monotonicMs : clock.first;
    const deltaMs = discontinuity ? null : !clock ? 0 : record.monotonicMs - clock.last;
    clocks.set(record.source, { first, last: record.monotonicMs });
    return { ...record, sourceElapsedMs: discontinuity ? null : record.monotonicMs - first, sourceDeltaMs: deltaMs,
      ...(discontinuity ? { timingDiscontinuity: true } : {}) };
  });
}

# PR3 — Activity counter (tool classifier + thinking step) Plan

**Status**: planning only — do NOT modify source code in this task.
**SoT spec**: `docs/refactoring/side-card-conversation-redesign.md` §1.6, §3.2.
**Context handoff**: `/tmp/picky-pr2-5-context.md`.
**Base**: `main` @ commit `7a33393` + PR2 changes (queue + side split).
**Sequential dependency**: depends on PR2 (uses the same `nextSeq(sessionId)` mechanism added in PR2 task 5).

## Goal
Project tool calls and thinking steps onto a 4-bucket counter (`edit / bash / thinking / other`) per session, emit `sessionActivityUpdated` events with monotonic `seq`, and persist counts on `PickyAgentSession.activitySummary`. Pinned sessions stay at zero. No UI changes.

## Intent Type
Build (additive event emission on top of existing tool/thinking event flow).

## Scope

- **In** (PR3):
  1. New `agentd/src/domain/tool-categorizer.ts` exporting `categorize(toolName: string): "edit" | "bash" | "other"`.
  2. Hook into `RuntimeEventHandler.applyToolEvent(...)` to call a new supervisor dependency `incrementActivity(sessionId, category)` exactly once per **new** `tool_call_id` whose status is `"running"` (avoids double-count on subsequent updates / end events).
  3. Thinking-step counting: each contiguous run of `thinking_delta` events for a session = 1 thinking step. Increment on the **first** `thinking_delta` after a non-thinking boundary (status change to `running`, assistant_delta, tool event, or session start).
  4. `SessionSupervisor.incrementActivity(sessionId, category)` patches `session.activitySummary` and emits `sessionActivityUpdated` with `seq = nextSeq(sessionId)` only when the counter actually changed.
  5. Pinned sessions: never increment (no runtime handle, no events arrive). Test asserts pinned `activitySummary` stays `{ edit: 0, bash: 0, thinking: 0, other: 0 }`.
  6. Tests for classifier, increment-once-per-tool-call, thinking step boundaries, pinned sessions, sessionActivityUpdated emission.

- **Out**:
  - Activity strip rendering (Swift, Step 2).
  - Changing existing tool tracking on `session.tools[]` (kept as-is).
  - Persistence of activitySummary across daemon restart (in-memory only, like PR2 queue state).

- **Must Have**:
  - `categorize` is pure / deterministic.
  - Increment-once-per-tool-call: a `tool` event with the same `toolCallId` that arrives multiple times (`running` → `succeeded`) only contributes 1 to the count.
  - Counter only emits on actual change (no spam emissions).
  - `seq` monotonic per session (uses PR2's `nextSeq(sessionId)`).
  - Existing tests pass.

- **Must NOT Have**:
  - Any change to message journal / `agent_text` / `agent_thinking` event emission (PR4 territory).
  - Any change to `session.tools[]` shape (existing flow preserved for backwards compat).
  - Any UI / Swift changes.
  - Any retroactive backfill from `session.tools[]` on daemon restart (counts reset on restart, like queue state).

## Context (Evidence)

- `agentd/src/protocol.ts:127` — `PickyActivitySummarySchema = { edit, bash, thinking, other }` already in PR1.
- `agentd/src/protocol.ts:163` — `PickyAgentSessionSchema.activitySummary` field already in PR1 with default `{ edit:0, bash:0, thinking:0, other:0 }`.
- `agentd/src/protocol.ts:225` — `sessionActivityUpdated` event already in PR1.
- `agentd/src/application/runtime-event-handler.ts:121-129` — `applyToolEvent(...)` is the single funnel for `tool` runtime events. Currently mutates `session.tools[]`; PR3 adds an `incrementActivity` callback **before** the existing logic.
- `agentd/src/application/runtime-event-handler.ts:38` — `applyThinkingEvent(...)` is the single funnel for `thinking_delta`. PR3 needs a "first delta after boundary" signal here.
- `agentd/src/application/runtime-event-handler.ts:25-29` — `RuntimeEventHandler` keeps `assistantDrafts` and `thinkingDrafts` maps. Add a third map `private thinkingActive = new Map<string, boolean>();` to detect boundary entry.
- `agentd/src/application/runtime-event-handler.ts:55-87` — `applyStatusEvent`. Terminal status (`completed/failed/cancelled`) clears `thinkingDrafts`; PR3 must also clear `thinkingActive[sessionId] = false` so a subsequent restart re-counts.
- `agentd/src/application/runtime-event-handler.ts:32-43` — Reset on assistant_delta / tool / extension_ui must also flip `thinkingActive[sessionId] = false` before falling through.
- `agentd/src/runtime/types.ts:18` — `tool` runtime event carries `toolCallId, name, status: "running" | "succeeded" | "failed", preview?`. PR3 keys on `toolCallId` to avoid double-count.
- `agentd/src/domain/pi-event-normalizer.ts:42-78` — `tool_execution_start` → `RuntimeEvent.tool` with `status: "running"`. `tool_execution_update` also `running`. `tool_execution_end` → `succeeded | failed`. PR3 increments only on the **first** running event per `toolCallId` per session.
- `agentd/src/domain/pi-event-normalizer.ts:30-40` — `thinking_delta` → `RuntimeEvent.thinking_delta`. There is no separate `thinking_start` / `thinking_end` event from Pi SDK (verified in `agent-session.d.ts` AgentSessionEvent union). So thinking step count is delta-boundary heuristic.
- `agentd/src/session-supervisor.ts:53-61` — `RuntimeEventHandler` constructor wiring; PR3 adds `incrementActivity` callback here.
- `agentd/src/session-supervisor.ts` — supervisor will gain `private incrementActivity(sessionId, category: ActivityCategory)` method that:
  1. Reads current `session.activitySummary`.
  2. Computes new summary with `[category]++`.
  3. Patches session + emits `sessionActivityUpdated`.
  4. Uses `this.nextSeq(sessionId)` (added in PR2).
- `agentd/src/server.ts:38-44` — supervisor event channel wiring. Add:
  ```ts
  this.options.supervisor.on("activityUpdated", (sessionId, activitySummary, seq) =>
    this.broadcast({ type: "sessionActivityUpdated", sessionId, activitySummary, seq }));
  ```

## Assumptions
- The `RuntimeEventHandler` has visibility on `sessionId` for every event — confirmed (it's the first arg to `handle()`).
- Tools fired during a "synthesized completion" (`/slash` extension, `noTurnRan: true`) still emit normal `tool_execution_start` events when applicable. If a slash command never produces tool events, the activity counter stays unchanged — desired.
- A new tool name like an MCP `mcp__notion__readPage` should map to `"other"` per spec §1.6. The classifier uses the **last segment** of double-underscore-split names if present, but for safety just normalizes lowercase and matches against the `["edit", "write", "multiedit"]` / `["bash"]` whitelists. MCPs / `read` / `grep` / etc. all → `"other"`.
- **Thinking step counting is heuristic**: each contiguous run of `thinking_delta` between non-thinking events = 1 step. Edge: 1000 rapid thinking_deltas in a row = 1 step (good). Long single-paragraph thinking with no other event = 1 step (good).
- Pinned sessions never call `applyRuntimeEvent`, so the supervisor never sees a tool event for them. No special-case needed beyond a sanity test.
- The `seq` counter is **shared** across queue / activity / message events per spec §2.4 (same `seq: number` field on each event). PR3 reuses `nextSeq(sessionId)` from PR2 task 5.

## Execution Strategy (Parallel Waves)

- **Wave 1**: tool-categorizer module (independent).
- **Wave 2** (depends on Wave 1):
  - W2-A: `RuntimeEventHandler` deps interface + thinking-active map.
  - W2-B: Increment hook in `applyToolEvent` (track first `running` per toolCallId).
  - W2-C: Increment hook in `applyThinkingEvent` (boundary detection).
  - W2-D: Boundary clear on `applyStatusEvent` terminal / `assistant_delta` / tool / extension_ui.
- **Wave 3** (depends on Wave 2):
  - W3-A: `SessionSupervisor.incrementActivity` + supervisor event emit.
  - W3-B: server.ts broadcast wiring.
- **Wave 4** (tests).

## Task Breakdown

### 1. tool-categorizer module — Complexity: Low
- **What**: Pure function that maps a tool name to one of four categories.
- **Where**: New file `agentd/src/domain/tool-categorizer.ts`.
  ```ts
  export type ToolCategory = "edit" | "bash" | "thinking" | "other";

  const EDIT_TOOLS = new Set(["edit", "write", "multiedit"]);
  const BASH_TOOLS = new Set(["bash"]);

  export function categorizeTool(toolName: string): Exclude<ToolCategory, "thinking"> {
    const normalized = toolName.trim().toLowerCase();
    if (EDIT_TOOLS.has(normalized)) return "edit";
    if (BASH_TOOLS.has(normalized)) return "bash";
    return "other";
  }
  ```
  Note: `"thinking"` is intentionally NOT returned by `categorizeTool` — it is a separate counter increment driven by `applyThinkingEvent`. Returning `Exclude<ToolCategory, "thinking">` makes that contract type-safe.
- **Depends on**: none.
- **Blocks**: tasks 2, 3.
- **Risks**: none.
- **Acceptance checks**:
  - New unit test `agentd/src/domain/tool-categorizer.test.ts` covering each whitelist + an "other" sample (e.g. `"read"`, `"mcp__notion__readPage"`, `"picky_show_pointer"`).
  - `cd agentd && npx vitest run src/domain/tool-categorizer.test.ts` → green.

### 2. RuntimeEventHandler: dependency + thinking-active map — Complexity: Low
- **What**: Add an `incrementActivity` dep + a `thinkingActive` map + a `seenToolCallIds` map (per session, to dedupe increments per `toolCallId`).
- **Where**: `agentd/src/application/runtime-event-handler.ts`:
  - Interface (lines 12-22) → add:
    ```ts
    incrementActivity(sessionId: string, category: ToolCategory): Promise<void>;
    ```
  - Class (lines 25-29) → add:
    ```ts
    private readonly thinkingActive = new Map<string, boolean>();
    private readonly seenToolCallIds = new Map<string, Set<string>>();
    ```
  - `resetAssistantDraft(sessionId)` → also reset `thinkingActive.set(sessionId, false)` and `seenToolCallIds.delete(sessionId)` (this is called on session create / followUp / steer).
- **Depends on**: task 1.
- **Blocks**: tasks 3, 4, 5.
- **Risks**: import cycle if categorizer imports protocol types — keep categorizer self-contained.
- **Acceptance checks**:
  - `cd agentd && npm run build` → green.

### 3. Increment on tool event (first running per toolCallId) — Complexity: Low
- **What**: In `applyToolEvent(...)` (lines 121-129) at the top:
  ```ts
  const seen = this.seenToolCallIds.get(sessionId) ?? new Set();
  if (event.status === "running" && !seen.has(event.toolCallId)) {
    seen.add(event.toolCallId);
    this.seenToolCallIds.set(sessionId, seen);
    await this.dependencies.incrementActivity(sessionId, categorizeTool(event.name));
  }
  // ALSO: clear thinkingActive — a tool starting marks the end of a thinking step
  this.thinkingActive.set(sessionId, false);
  ```
- **Where**: `agentd/src/application/runtime-event-handler.ts:121-129`.
- **Depends on**: tasks 1, 2.
- **Blocks**: task 5.
- **Risks**: An `update` event for the same toolCallId currently has `status: "running"` (line 50-58 of pi-event-normalizer.ts). Dedup via `seen.has(toolCallId)` covers this. **Verify**: `tool_execution_update` only fires for tools already started, so `seen` will already contain the id by the time update arrives.
- **Acceptance checks**:
  - Test: emit tool_start (running) → tool_update (running) → tool_end (succeeded) for one toolCallId → `incrementActivity` called exactly once with the right category.

### 4. Increment on thinking event (boundary entry) — Complexity: Low
- **What**: In `applyThinkingEvent(...)` (line 91), at the top:
  ```ts
  if (!event.delta) return;
  if (this.thinkingActive.get(sessionId) !== true) {
    this.thinkingActive.set(sessionId, true);
    await this.dependencies.incrementActivity(sessionId, "thinking");
  }
  ```
- **Where**: `agentd/src/application/runtime-event-handler.ts:91-104`.
  - Also: in `handle(...)` (line 32-43), before delegating to `applyToolEvent` / `applyStatusEvent` / `assistant_delta`, set `thinkingActive[sessionId] = false`. Specifically:
    - `assistant_delta` branch (line 35): set `thinkingActive.set(sessionId, false)` (an assistant text token means thinking step is over).
    - `tool` branch (line 121): handled in task 3.
    - `extension_ui` branch: also clear thinkingActive (a question turn ends thinking).
    - `status` branch terminal (line 56-87): clear thinkingActive on terminal status (already clears thinkingDrafts at line 81-82).
- **Depends on**: tasks 1, 2.
- **Blocks**: task 5.
- **Risks**: assistant_delta arriving before any thinking_delta won't increment thinking — correct; not all turns produce thinking. Multiple separate thinking phases within one turn (thinking → text → thinking) → 2 thinking steps — desired per spec §1.6 ("thinking step 횟수").
- **Acceptance checks**:
  - Test: emit 100 thinking_delta in a row → 1 increment.
  - Test: thinking → assistant_delta → thinking → 2 increments.
  - Test: thinking → tool → thinking → 2 increments.

### 5. SessionSupervisor.incrementActivity — Complexity: Medium
- **What**:
  1. New private method:
     ```ts
     private async incrementActivity(sessionId: string, category: ToolCategory): Promise<void> {
       const session = this.sessions.get(sessionId);
       if (!session) return;
       const current = session.activitySummary ?? { edit: 0, bash: 0, thinking: 0, other: 0 };
       const next = { ...current, [category]: current[category] + 1 };
       await this.patch(sessionId, { activitySummary: next });
       const seq = this.nextSeq(sessionId);
       this.emit("activityUpdated", sessionId, next, seq);
     }
     ```
  2. Wire callback in constructor `RuntimeEventHandler` deps (`session-supervisor.ts:53-61`):
     ```ts
     incrementActivity: (sessionId, category) => this.incrementActivity(sessionId, category),
     ```
  3. Add to `agentd/src/server.ts:38-44`:
     ```ts
     this.options.supervisor.on("activityUpdated", (sessionId, activitySummary, seq) =>
       this.broadcast({ type: "sessionActivityUpdated", sessionId, activitySummary, seq }));
     ```
- **Where**: `agentd/src/session-supervisor.ts`, `agentd/src/server.ts`.
- **Depends on**: tasks 1-4 + PR2 task 5 (`nextSeq`).
- **Blocks**: tests.
- **Risks**:
  - `session.activitySummary` will always be defined post-patch (Zod default applies on parse), but pre-patch a session loaded from disk may have it omitted. Always-fallback default in the method handles this.
  - Race: rapid increments could in theory queue out-of-order if `patch` awaits the disk write. Acceptable: `patch` already serializes via the same Map/store; emissions happen after `await patch`.
- **Acceptance checks**:
  - Existing tests pass.
  - New test: drive a `tool` event via mock → assert `supervisor.get(id).activitySummary.other === 1` and the supervisor emitted `activityUpdated`.

### 6. Tests — Complexity: Medium
- **Where**: `agentd/src/domain/tool-categorizer.test.ts` (new), `agentd/src/session-supervisor.test.ts` (additions).
- **Cases**:
  1. `categorizeTool` exhaustive cases: `edit/write/multiedit/EDIT/Edit` → `"edit"`; `bash` → `"bash"`; `read/grep/mcp__x/picky_show_pointer/""` → `"other"`.
  2. **Tool increment idempotency**: emit running + update + succeeded for same toolCallId → counter increments by 1.
  3. **Two distinct toolCallIds same name**: → counter increments by 2.
  4. **Thinking single run**: 5 thinking_deltas → 1 thinking increment.
  5. **Thinking interleaved with tool**: thinking, tool, thinking → 2 thinking + 1 tool increment.
  6. **Thinking interleaved with assistant_delta**: thinking, assistant, thinking → 2 thinking.
  7. **Activity event seq monotonic with queue events**: drive a queue update + tool event + queue update → seqs 1,2,3 in emission order (shared counter per spec).
  8. **Pinned session has no activity**: create pinned session, no events fire → `activitySummary` stays at zero, no `activityUpdated` emitted.
  9. **Reset on followUp/steer**: after first turn (counter at e.g. `{edit:2}`), call `supervisor.followUp(...)` — `seenToolCallIds` and `thinkingActive` cleared so the **next** turn's thinking/tools count fresh, but the **session.activitySummary** persists across turns (cumulative — confirm with spec §1.6: "여기까지 이만큼 일했음" = cumulative session lifetime). **Decision**: counters are session-lifetime cumulative, NOT per-turn.

  > **Rationale**: "여기까지" implies cumulative since session start. The dedup map (`seenToolCallIds`) only prevents double-counting *the same tool call*; the counter itself never resets within a session.

- **Depends on**: tasks 1-5.
- **Blocks**: PR3 ship.
- **Acceptance checks**:
  - `cd agentd && npm test` → all green.

## Test & QA Scenarios

- [ ] Happy: edit + write + multiedit each → `activitySummary.edit` increments correctly.
- [ ] Happy: bash → `activitySummary.bash`.
- [ ] Happy: read + grep + MCP → `activitySummary.other`.
- [ ] Happy: thinking_delta sequence → 1 increment per contiguous run.
- [ ] Edge: tool_call_id reused (shouldn't happen but defensive) — second `running` ignored.
- [ ] Edge: tool event with empty/missing name (defensive) → `categorizeTool("")` returns `"other"` → still increments. Acceptable.
- [ ] Edge: pinned session — no events → no increments → no emissions.
- [ ] Regression: existing `session-supervisor.test.ts` and `runtime-event-handler` related tests pass.

## Edge Cases & Risks
- **Heuristic thinking accuracy** — listed as decided in §7.2 spec ("turn 단위 + heuristic"). Boundary on assistant_delta / tool / status terminal is the heuristic. Document with a one-line code comment.
- **Counter persistence across daemon restart** — `activitySummary` IS persisted via `session-store.ts` (since the field is in the session schema). On restart the counters survive but `seenToolCallIds` / `thinkingActive` reset, which is fine because no in-flight events exist anyway.
- **MCP tool naming** — names like `mcp__notion__readPage` map to `"other"`; spec §1.6 explicitly lists MCP under "기타".
- **Counter monotonic** — tests must verify counters never decrement.

## Decisions Needed
1. **Counter scope: cumulative session-lifetime vs per-turn?** Plan recommends cumulative (matches "여기까지" wording). Per-turn would require reset on followUp/steer which simplifies "current turn at-a-glance" but loses retrospective context. **Recommendation: cumulative.**
2. **Should we also re-emit `sessionActivityUpdated` on `sessionSnapshot`?** No — snapshot already carries `activitySummary` on the session object; clients use that for initial state. Live updates only via `activityUpdated`.

## Defaults Applied
- Counter is cumulative (session-lifetime).
- Thinking step boundary = transition into thinking_delta from any other event type or session start.
- `categorizeTool` returns `"other"` for empty / unknown / MCP / custom names.

## Verification Checklist
```bash
cd /Users/creatrip/Documents/picky/agentd
npm run build
npm test
```
Expected:
- All existing tests pass.
- ~9 new tests added under PR3 scope all pass.
- `rg -n "categorizeTool" agentd/src` returns the new file + 2 callsites (RuntimeEventHandler + tests).

## Worker Reporting Requirements
After implementation, worker MUST report:
- `git status --short` — confirm only PR3-scoped files touched.
- File-by-file change summary mapped back to tasks 1-6.
- Test counts (pass/fail) for `npm test`.
- **Do not commit.**

## Estimated Effort
Low-Medium. New file + ~30 lines in RuntimeEventHandler + ~15 lines in supervisor + ~9 tests. Risk concentrated in thinking-step boundary semantics; covered by tests 4-6.

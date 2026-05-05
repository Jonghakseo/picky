# PR2 — Queue + side session split Plan

**Status**: planning only — do NOT modify source code in this task.
**SoT spec**: `docs/refactoring/side-card-conversation-redesign.md` §1.3, §3.3, §3.4, §3.6.
**Context handoff**: `/tmp/picky-pr2-5-context.md`.
**Base**: `main` @ commit `7a33393` (PR1 foundation).
**Sequential dependency**: this PR runs **first** in the PR2~5 chain. Subsequent PRs (PR3 activity, PR4 messages, PR5 final report) layer on top of these changes.

## Goal
Make queue state observable to clients (`sessionQueueUpdated` events with per-session `seq` + mode mirror), implement the `clearQueue` RPC for real, and split the side-session `followUp` vs `steer` paths so a side agent's queue behaves identically to a primary session's queue. No UI changes; no message journal yet.

## Intent Type
Build (business logic on top of PR1 schema scaffolding).

## Scope

- **In** (PR2):
  1. Subscribe to Pi SDK `queue_update` event in supervisor and project it to `queuedSteers` / `queuedFollowUps` on the session.
  2. Mode mirror: read `handle.steeringMode` / `handle.followUpMode` after every queue_update; emit `sessionQueueUpdated` with optional `steeringMode` / `followUpMode` only when changed since last emission for that session.
  3. Per-session monotonic `seq` counter for `sessionQueueUpdated` (the same counter family is reused by PR3 / PR4; PR2 establishes the counter map).
  4. Replace the `clearQueue` server stub at `agentd/src/server.ts:111` with a real supervisor handler that calls `agentSession.clearQueue()` and re-enqueues the kind-not-targeted half (per spec §3.4 NOTE).
  5. Split side-session steer/followUp: remove the `if (this.isSideSession(sessionId)) return this.steerSideSession(...)` shortcut at `agentd/src/session-supervisor.ts:710`. Side sessions take the same `followUp(...)` queue-enqueue path as visible sessions; `steer(...)` keeps interrupting. Side-only side effects (`clearSideCompletionTracking`, `pinned -> false`) extracted to a private helper invoked from both paths.
  6. Tests: queue projection, mode mirror change-detection, `clearQueue` per-kind, side session followUp path, sequence ordering.

- **Out** (later PRs):
  - Activity counter classifier and `sessionActivityUpdated` emission → PR3.
  - Append-only message journal, `sessionMessageAppended/Replaced/Removed` → PR4.
  - `submit_final_report` tool → PR5.
  - Any UI work; pinned session reattach behavior changes; waiting_for_input auto-cancel.

- **Must Have**:
  - `sessionQueueUpdated` emitted whenever queue length OR contents change for a session, with `seq` strictly monotonic per session.
  - `steeringMode` / `followUpMode` populated **only** when the value differs from what we last emitted for this session (Swift-side null preserves prior).
  - `clearQueue(kind="steering")` clears Pi steering queue while preserving follow-ups (re-enqueued); `kind="followUp"` symmetric; `kind="all"` drains both.
  - Side-session followUp queues the prompt via `handle.followUp(prompt)` (same path as visible sessions), no longer routed to `steer()`.
  - Existing `npm test` and `xcodebuild test` suites continue to pass.

- **Must NOT Have**:
  - Any change to `RuntimeEventHandler` activity counters (PR3 territory).
  - Any change to message journal / event emission for messages (PR4).
  - Any system-prompt edit or tool definition (PR5).
  - Pinned-session reattach implementation (decision §7.10 = B; deferred to PR6).
  - `popLatestQueueItem` / single-item remove RPC (decision §7.13 = B).

## Context (Evidence)

- `agentd/src/protocol.ts:189` — `clearQueue` command schema is already in PR1.
- `agentd/src/protocol.ts:223-224` — `sessionQueueUpdated` event schema is already in PR1 (`steering`, `followUp`, optional modes, `seq`).
- `agentd/src/server.ts:111` — current stub `if (command.type === "clearQueue") this.send(ws, { type: "error", code: "notImplemented", ... })`. PR2 replaces this branch with a supervisor call.
- `agentd/src/server.test.ts:62-68` — existing test asserts the `notImplemented` stub. PR2 must rewrite/replace this test.
- `agentd/src/session-supervisor.ts:710` — `if (this.isSideSession(sessionId)) return this.steerSideSession(sessionId, text);` inside `followUp(...)`. **This line is removed.**
- `agentd/src/session-supervisor.ts:688-696` — `followUpSideSession` / `steerSideSession`. After the split, `followUpSideSession` is unused; either delete it or have it forward to `followUp(sessionId, text)`. Recommendation: delete (no public callers — verified by `rg -n "followUpSideSession" agentd/src` returns only the definition and `steerSideSession(...)` line).
- `agentd/src/session-supervisor.ts:692-696` — `steerSideSession` body (= guard + `clearSideCompletionTracking` + pinned reset + `steer(...)`). Extract the side-only prep (sideSessionIds guard + clearSideCompletionTracking + pinned reset) into a `private prepareSideSessionForUserInput(sessionId)` helper.
- `agentd/src/session-supervisor.ts:710-743` — `followUp(sessionId, text, context)` body. After removing line 710 the existing logic already calls `clearSideCompletionTracking` at line 727 if it's a side session, but does NOT clear `pinned`. The new helper centralizes the pinned reset for both follow-up and steer.
- `agentd/src/session-supervisor.ts:794-814` — `steer(sessionId, text)` body. Replace lines 802 (`if (this.isSideSession(sessionId)) this.clearSideCompletionTracking(sessionId);`) with a call to the new `prepareSideSessionForUserInput(sessionId)` so it also clears `pinned`.
- `agentd/src/runtime/pi-sdk-runtime.ts:300-305` — current `runtimeEventFromPiEvent` updates internal counters from `queue_update` but does NOT forward an event to the supervisor. PR2 makes the runtime emit a typed `RuntimeEvent` for `queue_update`.
- `agentd/src/runtime/types.ts:14-21` — `RuntimeEvent` discriminated union. **Add a new variant** `{ type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }`. (Note: `pi-event-normalizer.ts:80-83` currently maps queue_update to a `log` event line — that mapping is dropped or kept for backward log visibility; recommendation = replace with the new typed forward, since the log line `"queue update: steering=N followUp=M"` is purely informational and not consumed by tests.)
- `agentd/src/domain/pi-event-normalizer.ts:80-83` — current `queue_update` → `log` mapping. PR2 replaces this with a typed event (or removes it and the supervisor reads queue state via the `pi_sdk_runtime`'s own subscription path — see §Implementation choices below).
- `agentd/src/application/runtime-event-handler.ts:32-43` — central handler. PR2 adds a new branch `if (event.type === "queue_update") return this.applyQueueUpdate(...)` that forwards to a supervisor callback (similar to `notifySideCompletion` pattern).
- `agentd/src/runtime/pi-sdk-runtime.test.ts:325-333` — existing test stubs `queue_update` event. Mirrors what PR2 needs.
- `agentd/src/runtime/mock-runtime.ts:33-58` — mock implementation; PR2 needs to make `MockRuntimeSession` emit `queue_update` events on `steer` / `followUp` / `clearQueue` so supervisor tests can drive queue state without Pi SDK.
- `agentd/src/runtime/mock-runtime.ts:34-37` — `MockRuntimeSession.steer` currently appends to `this.steering`; PR2 adds `this.emit({ type: "queue_update", ... })` after each mutation.
- `agentd/node_modules/@mariozechner/pi-coding-agent/dist/core/agent-session.d.ts:40-44` — Pi SDK `queue_update` event shape: `{ type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }`.
- `agentd/node_modules/.../agent-session.d.ts:381-390` — `clearQueue()` returns `{ steering: string[]; followUp: string[] }` (drained items). Pi SDK does NOT support partial-kind clear, so the PR2 `kind="steering"` / `"followUp"` paths must drain both then re-enqueue the un-targeted half.

## Assumptions
- Re-enqueue order on partial `clearQueue` matches the order returned by `agentSession.clearQueue()` (Pi SDK preserves insertion order in the snapshot it returns).
- `seq` counters are session-scoped and reset only on supervisor restart. Stored in a `Map<string, number>` private to `SessionSupervisor`.
- `MockRuntimeSession.followUp` accepts the `BuiltPrompt` shape (already true at `mock-runtime.ts:30-34`); PR2 adds a queue_update emit after the push.
- `prepareSideSessionForUserInput` does not throw on non-side sessions (it just no-ops); both `followUp` and `steer` call it unconditionally for code clarity.
- Re-enqueue via `handle.steer(text)` / `handle.followUp({text, imagePaths: []})` is **synchronous-ish** (returns once Pi SDK accepts the prompt). The fact that text was already expanded once is acceptable per spec §3.4 NOTE.
- The new typed `queue_update` runtime event is delivered to the supervisor via `RuntimeEventHandler` (uniform with other runtime events) rather than a side-channel callback. RuntimeEventHandler gains a new dependency `applyQueueUpdate(sessionId, steering, followUp)`.

## Execution Strategy (Parallel Waves)

- **Wave 1** (independent foundation):
  - W1-A: Add `queue_update` variant to `RuntimeEvent` union (`runtime/types.ts`).
  - W1-B: Update Pi SDK runtime adapter (`pi-sdk-runtime.ts`) to emit the typed `queue_update` event from its existing `runtimeEventFromPiEvent` path.
  - W1-C: Update `MockRuntimeSession` to emit `queue_update` after `steer` / `followUp` / `clearQueue` mutations (`runtime/mock-runtime.ts`).
- **Wave 2** (depends on W1):
  - W2-A: Drop `pi-event-normalizer.ts` queue_update → log mapping (or just keep for observability — recommendation: remove, since it's noise).
  - W2-B: Add `applyQueueUpdate` dependency + handler in `RuntimeEventHandler` (`application/runtime-event-handler.ts`).
  - W2-C: Add `seq` map + `sessionQueueUpdated` emission + mode-change tracking + queue projection in `SessionSupervisor`.
  - W2-D: Add private helper `prepareSideSessionForUserInput(sessionId)` and refactor `followUp` / `steer` to use it; **remove the `if (isSideSession) return steerSideSession` shortcut** at `session-supervisor.ts:710`.
- **Wave 3** (depends on W2):
  - W3-A: Replace `server.ts` `clearQueue` stub with a real call to `supervisor.clearQueue(sessionId, kind)`. Add `clearQueue` method to `SessionSupervisor`.
  - W3-B: Update `agentd/src/server.test.ts` `notImplemented` test to assert real clearQueue behavior + a new test for the typed event flow end-to-end.
- **Wave 4** (tests):
  - Tests for queue mirror, mode change detection, partial clearQueue re-enqueue, side session followUp queueing, side session steer pinned-reset.

## Task Breakdown

### 1. Add `queue_update` variant to RuntimeEvent — Complexity: Low
- **What**: Extend the `RuntimeEvent` discriminated union with a `queue_update` variant carrying steering + followUp string arrays.
- **Where**: `agentd/src/runtime/types.ts:14-21` (insert after `extension_ui` line).
  ```ts
  | { type: "queue_update"; steering: readonly string[]; followUp: readonly string[] }
  ```
- **Depends on**: none.
- **Blocks**: tasks 2, 3, 4.
- **Risks**: existing `RuntimeEventHandler.handle()` switch is exhaustive on event.type — TypeScript will complain until task 4 adds a branch. Workaround: add the branch at the same time, or insert a `if (event.type === "queue_update") return this.applyQueueUpdate(...)` line in task 4.
- **Acceptance checks**:
  - `cd agentd && npm run build` → no TS errors after task 4 lands.

### 2. PiSdkRuntimeSession emits typed queue_update — Complexity: Low
- **What**: Replace lines 301-305 in `pi-sdk-runtime.ts` so `queue_update` is forwarded as a typed runtime event AND the internal counts are still updated (counts feed `pi-event-normalizer` context for `completionStatusFromContext`).
- **Where**: `agentd/src/runtime/pi-sdk-runtime.ts:299-313` (`runtimeEventFromPiEvent` body).
  - Detect `record.type === "queue_update"`, update `queuedSteeringCount` / `queuedFollowUpCount` (kept as today), and **return** the typed event directly:
    ```ts
    if (record.type === "queue_update") {
      this.queuedSteeringCount = Array.isArray(record.steering) ? record.steering.length : 0;
      this.queuedFollowUpCount = Array.isArray(record.followUp) ? record.followUp.length : 0;
      return {
        type: "queue_update",
        steering: Array.isArray(record.steering) ? (record.steering as readonly string[]) : [],
        followUp: Array.isArray(record.followUp) ? (record.followUp as readonly string[]) : [],
      };
    }
    ```
  - Continue calling `runtimeEventFromPiEvent` for non-queue events (refactor into early-return). The current `pi-event-normalizer.ts:80-83` mapping (queue_update → log) is now dead code; **delete those lines** in `domain/pi-event-normalizer.ts`.
- **Depends on**: task 1.
- **Blocks**: task 4.
- **Risks**:
  - `pi-event-normalizer.test.ts` may have a case asserting the log-line output for `queue_update` — `rg -n "queue_update\|queue update" agentd/src/pi-event-normalizer.test.ts` → expect 0 matches before/after PR2 (verify with grep). If matches exist, those tests must be updated to expect the typed event.
- **Acceptance checks**:
  - `cd agentd && npx vitest run src/pi-event-normalizer.test.ts src/runtime/pi-sdk-runtime.test.ts` → green.
  - Manual subscribe: stub a Pi event `{ type: "queue_update", steering: ["a"], followUp: [] }` → handle subscribers receive `RuntimeEvent` with `type: "queue_update"`.

### 3. MockRuntimeSession emits queue_update on mutations — Complexity: Low
- **What**: After `steer` / `followUp` / `clearQueue` mutate `this.steering` / `this.followUpQueue`, emit a `queue_update` event so supervisor tests can simulate queue dynamics without Pi SDK.
- **Where**: `agentd/src/runtime/mock-runtime.ts`:
  - `steer(...)` after `this.steering.push(text)` (line 33) → `this.emitQueueUpdate()`.
  - `followUp(...)` after `this.followUpQueue.push(prompt.text)` (line 30) → `this.emitQueueUpdate()`.
  - `clearQueue()` after the clear (line 53-58) → `this.emitQueueUpdate()`.
  - New private method:
    ```ts
    private emitQueueUpdate(): void {
      this.emit({ type: "queue_update", steering: [...this.steering], followUp: [...this.followUpQueue] });
    }
    ```
- **Depends on**: task 1.
- **Blocks**: task 5 supervisor tests.
- **Risks**: none — existing `mock-runtime.test.ts` does not subscribe to events.
- **Acceptance checks**:
  - `cd agentd && npx vitest run src/runtime/mock-runtime.test.ts` → green.

### 4. RuntimeEventHandler forwards queue_update — Complexity: Low
- **What**: Add a dependency callback `applyQueueUpdate(sessionId, steering, followUp): Promise<void>` and a switch branch in `RuntimeEventHandler.handle()`.
- **Where**: `agentd/src/application/runtime-event-handler.ts:12-22` (interface) and `34-43` (handle body).
  ```ts
  // interface
  applyQueueUpdate(sessionId: string, steering: readonly string[], followUp: readonly string[]): Promise<void>;
  // handle()
  if (event.type === "queue_update") return this.dependencies.applyQueueUpdate(sessionId, event.steering, event.followUp);
  ```
  Place the branch BEFORE the `return this.applyToolEvent(sessionId, event)` fallthrough so unknown future event variants still error.
- **Depends on**: tasks 1-3.
- **Blocks**: task 5.
- **Risks**: none — additive.
- **Acceptance checks**:
  - `cd agentd && npm run build` → green.

### 5. SessionSupervisor: queue projection, seq, mode mirror, sessionQueueUpdated emit — Complexity: Medium
- **What**:
  1. Add private state on `SessionSupervisor`:
     ```ts
     private sessionSeq = new Map<string, number>();          // monotonic per session, shared across queue/activity/message events
     private lastEmittedSteeringMode = new Map<string, PickyQueueMode>();
     private lastEmittedFollowUpMode = new Map<string, PickyQueueMode>();
     ```
  2. New `applyQueueUpdate(sessionId, steering, followUp)` method on `SessionSupervisor`:
     - Look up `RuntimeSessionHandle` via `this.runtimeHandles.get(sessionId)`.
     - Build `PickyQueueItem[]` for each kind: `{ text, enqueuedAt: now }` (use ISO string of receive time per spec §3.3).
     - Patch session: `queuedSteers`, `queuedFollowUps`, `steeringMode = handle.steeringMode`, `followUpMode = handle.followUpMode` (always patch session fields; emission filtering is separate).
     - Emit `sessionQueueUpdated` with:
       - `steering`, `followUp` populated.
       - `steeringMode` only if `handle.steeringMode !== this.lastEmittedSteeringMode.get(sessionId)`; analogous for follow-up.
       - On change, update the `lastEmittedX` map.
       - `seq = this.nextSeq(sessionId)`.
  3. Wire `applyQueueUpdate` into the `RuntimeEventHandler` deps in the constructor (`session-supervisor.ts:53-61`):
     ```ts
     applyQueueUpdate: (sessionId, steering, followUp) => this.applyQueueUpdate(sessionId, steering, followUp),
     ```
  4. New private `nextSeq(sessionId)`:
     ```ts
     private nextSeq(sessionId: string): number {
       const next = (this.sessionSeq.get(sessionId) ?? 0) + 1;
       this.sessionSeq.set(sessionId, next);
       return next;
     }
     ```
  5. Add a new server emit pipeline. In `agentd/src/server.ts`, add a supervisor event channel `queueUpdated`:
     - `agentd/src/server.ts:38-44` — currently lists `supervisor.on("session", ...)`, `"log"`, `"extensionUiRequest"` etc. Add:
       ```ts
       this.options.supervisor.on("queueUpdated", (sessionId, steering, followUp, steeringMode, followUpMode, seq) =>
         this.broadcast({ type: "sessionQueueUpdated", sessionId, steering, followUp, steeringMode, followUpMode, seq }));
       ```
     - In `SessionSupervisor.applyQueueUpdate`, call `this.emit("queueUpdated", sessionId, steering, followUp, steeringModeOrUndefined, followUpModeOrUndefined, seq)`.
- **Where**: `agentd/src/session-supervisor.ts` (top of class for state maps; new method anywhere; update constructor wiring at line 53).
- **Depends on**: tasks 1-4.
- **Blocks**: task 6 (clearQueue), tests.
- **Risks**:
  - Pinned sessions never get a `runtimeHandles` entry. If `applyQueueUpdate` is called for a pinned session (it shouldn't, since no Pi handle exists), guard with `if (!this.runtimeHandles.has(sessionId)) return;`.
  - Session may be unknown at the moment a stale queue_update arrives — guard with `this.sessions.has(sessionId)`.
- **Acceptance checks**:
  - New test in `session-supervisor.test.ts`: drive `MockRuntimeSession.followUp(...)` → expect `supervisor.get(id).queuedFollowUps[0].text === "..."` and `seq === 1`.
  - New test: change `(handle as any).steeringMode = "all"` between two queue_updates → assert second emission carries `steeringMode: "all"`, third emission with same mode does NOT include the field.

### 6. clearQueue RPC handler — Complexity: Medium
- **What**: Replace `agentd/src/server.ts:111` stub with a real `supervisor.clearQueue(sessionId, kind)` method, and emit a follow-up `sessionQueueUpdated` reflecting the post-clear state.
- **Where**:
  - `agentd/src/server.ts:111` →
    ```ts
    if (command.type === "clearQueue") await this.options.supervisor.clearQueue(command.sessionId, command.kind);
    ```
  - `agentd/src/session-supervisor.ts` new method:
    ```ts
    async clearQueue(sessionId: string, kind: "steering" | "followUp" | "all"): Promise<void> {
      const handle = this.runtimeHandles.get(sessionId);
      if (!handle) throw new Error(`Session has no attached runtime: ${sessionId}`);
      const drained = handle.clearQueue();          // sync per Pi SDK contract
      if (kind === "steering") {
        for (const text of drained.followUp) await handle.followUp({ text, imagePaths: [] });
      } else if (kind === "followUp") {
        for (const text of drained.steering) await handle.steer(text);
      }
      // Pi SDK's clearQueue / re-enqueue triggers `queue_update` events that drive
      // applyQueueUpdate; no manual emit needed. Verify in test.
    }
    ```
- **Depends on**: tasks 4, 5.
- **Blocks**: tests, server.test rewrite.
- **Risks**:
  - Re-enqueue races: between `clearQueue()` and the for-loop, an external Pi terminal could enqueue (won't happen in normal Picky-only flow). Acceptable per decision §7.13 (best-effort, no atomic guarantee).
  - `handle.followUp({ text, imagePaths: [] })` — confirm `BuiltPrompt` shape; from `prompt-builder.ts` this is the standard shape (verify at `rg -n "imagePaths" agentd/src/prompt-builder.ts`).
  - Re-enqueue text expansion: Pi SDK already expanded `/skill:` etc. on first enqueue; the text Pi gives back is the post-expansion text. Re-passing through `followUp` / `steer` will not double-expand because Pi only expands `/...` prefix patterns, which post-expansion text doesn't have. Add a unit test asserting that re-enqueued text equals the input text (no further expansion).
- **Acceptance checks**:
  - `agentd/src/session-supervisor.test.ts` new test: enqueue 2 steers + 2 follow-ups via mock, call `supervisor.clearQueue(id, "steering")`, expect mock's `getSteeringMessages()` empty + `getFollowUpMessages()` length 2.
  - `agentd/src/server.test.ts:62-68` rewrite: sending `clearQueue` no longer returns `notImplemented` error; instead expect the next event to be a `sessionQueueUpdated` reflecting drained queues.

### 7. Side session followUp/steer split — Complexity: Medium
- **What**:
  1. Remove `agentd/src/session-supervisor.ts:710` (`if (this.isSideSession(sessionId)) return this.steerSideSession(sessionId, text);`).
  2. Extract a private helper:
     ```ts
     private async prepareSideSessionForUserInput(sessionId: string): Promise<void> {
       if (!this.isSideSession(sessionId)) return;
       this.clearSideCompletionTracking(sessionId);
       const session = this.mustGet(sessionId);
       if (session.pinned) await this.patch(sessionId, { pinned: false });
     }
     ```
  3. In `followUp(...)` (lines 708-743), remove line 727 (`if (this.isSideSession(sessionId)) this.clearSideCompletionTracking(sessionId);`) and call `await this.prepareSideSessionForUserInput(sessionId)` near the top, **after** the `mustGet`/blocked-status checks but **before** runtime resume / log append.
  4. In `steer(...)` (lines 794-814), remove line 802 (`if (this.isSideSession(sessionId)) this.clearSideCompletionTracking(sessionId);`) and call `await this.prepareSideSessionForUserInput(sessionId)` at the analogous position.
  5. Keep `steerSideSession(...)` for backwards-compat (it's still called from `index.ts:51` `picky_side_steer` and from the legacy `followUpSideSession`). Internally `steerSideSession` becomes:
     ```ts
     async steerSideSession(sessionId: string, text: string): Promise<PickyAgentSession> {
       if (!this.isSideSession(sessionId)) throw new Error(`Session is not a Picky side agent: ${sessionId}`);
       return this.steer(sessionId, text);
     }
     ```
     The `prepareSideSessionForUserInput` invocation moves into `steer(...)` so it runs for both internal `steerSideSession` callers and direct `steer(...)` callers.
  6. Delete `followUpSideSession(...)` (lines 688-690) — no callers remain after the supervisor change. Verify with `rg -n "followUpSideSession" agentd Picky` — expect 0 matches outside the definition.
- **Where**: `agentd/src/session-supervisor.ts:688-696, 710, 727, 802`.
- **Depends on**: none structurally; can land independently of tasks 1-6 but must coexist (tested together).
- **Blocks**: PR4 message journal (which assumes that side session followUps emit `follow-up:` log entries from the same path as visible sessions).
- **Risks**:
  - Existing test `session-supervisor.test.ts:42-54` asserts `steerSideSession(...)` flows. After this change, `steerSideSession` still works (delegates to steer), but the test's expectations on `lastSummary === "Steering message sent"` should still pass.
  - **New scenario**: side session `followUp(...)` will now go through `tryResumeRuntimeHandle` if the handle isn't attached. For pinned sessions (no handle), this triggers `tryResumeRuntimeHandle` based on `piSessionFilePathFromLogs(session.logs)`. That branch is the §3.8 reattach behavior — but per §6 PR2 scope (pinned reattach is PR6), this is currently NOT desired.
    - **Mitigation**: in `followUp(...)` path, before `tryResumeRuntimeHandle`, add an early check: if `session.pinned`, throw `"Pinned sessions cannot accept follow-ups yet (PR6 reattach)"` to keep PR2 behavior identical to today's pinned UX. PR6 will replace this guard with the reattach flow.
- **Acceptance checks**:
  - New test: `supervisor.followUp(sideSessionId, "next step")` results in `mockHandle.followUpQueue` containing the prompt text (NOT `mockHandle.steering`).
  - Existing test `lists and resumes side sessions created from main-agent handoff` still passes (it uses `steerSideSession` directly).
  - `rg -n "followUpSideSession" agentd src Picky` → 0 matches.

### 8. Tests — Complexity: Medium
- **What**: Add focused tests covering each PR2 surface.
- **Where**: `agentd/src/session-supervisor.test.ts`, `agentd/src/server.test.ts`, `agentd/src/runtime/mock-runtime.test.ts`.
- **Cases** (one `it(...)` per case):
  1. **Queue mirror** — call `mockHandle.steer("a")` directly → supervisor emits `queueUpdated` with `steering = [{text:"a", enqueuedAt:<iso>}]`, `seq === 1`.
  2. **Sequence monotonic** — three rapid queue mutations → emitted seqs are 1,2,3 in order (capture via `supervisor.on("queueUpdated", ...)`).
  3. **Mode change detection** — patch `mockHandle.steeringMode` between events → first emission omits mode, second emission with new mode includes `steeringMode`, third emission with same mode omits again. (Mock currently has `readonly steeringMode`; update mock to allow test-only mutation.)
  4. **clearQueue=steering** — enqueue 2 steers + 2 follow-ups, call `supervisor.clearQueue(id, "steering")`, assert mock steering empty + follow-up retained.
  5. **clearQueue=followUp** — symmetric.
  6. **clearQueue=all** — both empty.
  7. **Server e2e clearQueue** — replace existing `notImplemented` test in `server.test.ts:62-68` with a real-flow test: enqueue via supervisor, send `{ type: "clearQueue", kind: "all" }`, assert `sessionQueueUpdated` emitted with empty queues.
  8. **Side followUp split** — `supervisor.followUp(sideId, "next")` → mock `followUpQueue.length === 1`, `steering.length === 0`. Confirms line-710 shortcut is gone.
  9. **Side steer pinned reset** — pinned side session, call `supervisor.steer(...)` → session.pinned becomes false, mock receives the steer.
  10. **Pinned followUp guard** — pinned session, `supervisor.followUp(...)` throws (PR2 guard until PR6 lands reattach).
- **Depends on**: tasks 1-7.
- **Blocks**: PR2 ship.
- **Acceptance checks**:
  - `cd agentd && npm test` → all green.
  - `cd agentd && npm run build` → green.

## Test & QA Scenarios

- [ ] Happy: side session followUp queues via `handle.followUp(...)` → expected: mock followUpQueue has the text, supervisor emits sessionQueueUpdated.
- [ ] Happy: clearQueue=steering preserves follow-ups via re-enqueue → expected: mock steering empty, followUp count unchanged.
- [ ] Happy: mode mirror only emits on change → expected: 3 events, only 1 carries the mode field.
- [ ] Edge: clearQueue with no attached handle → expected: throws `"Session has no attached runtime"`.
- [ ] Edge: pinned session followUp → expected: throws (PR6 will replace with reattach).
- [ ] Edge: rapid simultaneous queue_updates → expected: seqs are strictly increasing in emission order.
- [ ] Regression: `agentd/src/session-supervisor.test.ts` existing tests pass with no edits except optional mock mutability.
- [ ] Regression: `agentd/src/server.test.ts` rewritten clearQueue test passes; other server tests untouched.
- [ ] Regression: `xcodebuild test` Swift suite remains green (PR2 has no Swift changes).

## Edge Cases & Risks
- **Mode mirror state leaks across daemon restarts** — `lastEmittedX` maps reset on restart, so first post-restart emit will carry mode even if it hasn't changed. Acceptable: Swift side just sets the same value.
- **Pinned session followUp guard** — temporary; document with a `// TODO(PR6): replace with reattach` comment.
- **Re-enqueue race during partial clearQueue** — covered by spec §7.13 = B (best-effort).
- **`pi-event-normalizer.ts` queue_update log line removal** — verify no tests/grep depend on `"queue update: steering="` literal string. `rg -n 'queue update:' agentd` → expect only the soon-to-be-deleted line (and maybe a test). Update or remove that test.
- **Backwards-compat for `followUpSideSession` deletion** — verify `rg -n "followUpSideSession" .` returns 0 matches outside `session-supervisor.ts` definition before deleting.

## Decisions Needed
1. **Should `clearQueue` re-enqueue path use `await` (sequential) or `await Promise.all(...)` (parallel)?** The plan recommends sequential for stable order; parallel would be slightly faster but risk reordering. **Recommendation: sequential.**
2. **Should the `queue_update` runtime event also carry the modes (so RuntimeEventHandler doesn't need to call back into the handle)?** Plan keeps modes out of the runtime event and reads them from `handle.steeringMode` at supervisor-emit time (avoids stale snapshot). **Recommendation: keep modes off the runtime event.**

## Defaults Applied
- `enqueuedAt` = `new Date().toISOString()` at the moment supervisor receives the queue_update.
- Pinned-session followUp throws (`"Pinned sessions cannot accept follow-ups yet"`); PR6 replaces this.
- `pi-event-normalizer.ts` queue_update log mapping removed (the typed event supersedes it).

## Verification Checklist
```bash
cd /Users/creatrip/Documents/picky/agentd
npm run build
npm test
```
Expected:
- All existing tests pass.
- 10 new tests added under PR2 scope all pass.
- `rg -n "notImplemented" agentd/src/server.ts` → 0 matches.
- `rg -n "if (this.isSideSession(sessionId)) return this.steerSideSession" agentd/src/session-supervisor.ts` → 0 matches.
- `rg -n "followUpSideSession" agentd/src` → 0 matches (definition deleted).

## Worker Reporting Requirements
After implementation, worker MUST report:
- `git status --short` — confirm only PR2-scoped files touched.
- File-by-file change summary mapped back to tasks 1-8.
- Test counts (pass/fail) for `npm test`.
- Any deviation from the plan with rationale.
- **Do not commit.**

## Estimated Effort
Medium. Concentrated risk in the side-session split (test coverage matters) and `clearQueue` re-enqueue semantics. ~4-6 production source edits + 10 new tests.

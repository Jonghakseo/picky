# PR4 — Message journal + builder + emit Plan

**Status**: planning only — do NOT modify source code in this task.
**SoT spec**: `docs/refactoring/side-card-conversation-redesign.md` §1.8, §3.5, §3.6.
**Context handoff**: `/tmp/picky-pr2-5-context.md`.
**Base**: `main` @ commit `7a33393` + PR2 + PR3.
**Sequential dependency**: PR2 (queue + side split + `nextSeq`), PR3 (activity counter, doesn't conflict).
**Largest PR in the chain.** Worker may need to chunk; if context limited, prioritize: append-only journal → 6 source mappings → assistant/thinking boundaries → emission. Defer reducer-edge tests to a follow-up if needed.

## Goal
Build the live append-only message journal that powers the new conversation card. Six input sources flatten into a typed `PickySessionMessage[]` per session, exposed via `session.messages` and three event types (`sessionMessageAppended`, `sessionMessageReplaced`, `sessionMessageRemoved`) with monotonic `seq`. The journal is the live SoT; existing `logs` are kept as restart-recovery fallback only.

## Intent Type
Build (the largest module of the redesign — append-only journal + 6 source mapping + boundary-aware assistant_text + thinking lifecycle).

## Scope

- **In** (PR4):
  1. New `agentd/src/session-message-builder.ts` module that maintains a per-session journal and converts 6 input sources to journal entries.
  2. Wire builder into `SessionSupervisor` for **all 6 sources**:
     - composer steer (`STEER_PREFIX` log) → `user_text {originatedBy: "user"}`
     - composer follow-up (`FOLLOWUP_PREFIX` log) → `user_text {originatedBy: "user"}`
     - extension UI answer (`EXTENSION_ANSWER_PREFIX` log) → `user_text {originatedBy: "user"}`
     - main-agent handoff/steer (`HANDOFF_PREFIX` log) → `user_text {originatedBy: "main_agent"}`
     - `pinSideSession` synthetic 3-message intro (`user_text {originatedBy: "pi_extension"}` + `system` + `agent_text` for finalAnswer)
     - runtime events: `assistant_delta` (boundary-buffered → `agent_text`), `thinking_delta` (replace+remove → `agent_thinking`), `extensionUiRequest` (waiting → `agent_question`), runtime error / `failed` status (→ `agent_error`), `cancelled` status (→ `system`).
  3. Three new emission paths on `SessionSupervisor`:
     - `messageAppended(sessionId, message, seq)`
     - `messageReplaced(sessionId, messageId, message, seq)`
     - `messageRemoved(sessionId, messageId, seq)`
  4. `session.messages` field (already in PR1 schema) kept in sync with the journal so `sessionSnapshot` carries the full history to new clients.
  5. `submit_final_report` integration **stub only**: builder accepts a `recordFinalReport(sessionId, report)` API that creates an `agent_report` journal entry; PR5 will call it from the tool's execute body. PR4 leaves the API in place but unused.
  6. Reducer invariant on the server side: removed messageId can never be replaced (drop replace events for removed IDs in the builder before emitting).
  7. Tests covering all 6 sources, assistant_delta turn-boundary commits, thinking lifecycle (append → replace ×N → remove), unknown messageId remove no-op, sessionSnapshot reconciliation.

- **Out**:
  - `submit_final_report` tool definition, customTools registration, system-prompt injection, status patch on turn-end → PR5.
  - Disk persistence of the journal — in-memory only per spec §7.12.
  - Best-effort reconstruction of journal from `logs` after daemon restart (logs already remain; reconstruction is acknowledged as a future task per §3.5).
  - Swift / SwiftUI changes; activity strip rendering.
  - Removing `lastSummary` / `thinkingPreview` / `finalAnswer` / `tools` (kept; spec Step 3).
  - waiting_for_input auto-cancel + question `cancelledAt` flow → PR6.

- **Must Have**:
  - Each journal entry has a stable `id`, monotonic `seq` (uses PR2's `nextSeq(sessionId)`), `kind`, `createdAt` ISO timestamp, and kind-appropriate payload.
  - `assistant_delta` text is buffered per session and committed as a **single** `agent_text` message at the next boundary (status terminal/`waiting_for_input`/next user_text/tool_call_start). Multiple text segments per turn are allowed (tool→text→tool).
  - `agent_thinking` uses **one** stable id per "thinking phase" (between non-thinking boundaries — same boundaries used by PR3 thinking step counter). Each `thinking_delta` emits a `sessionMessageReplaced` with the accumulated thinking text. On boundary, emit `sessionMessageRemoved` for that id.
  - On `pinSideSession`, the journal is seeded with 3 entries:
    1. `user_text {originatedBy: "pi_extension", text: <transcript first non-empty trimmed line>}`
    2. `system {text: "Pinned from idle Pi session"}`
    3. `agent_text {text: <session.finalAnswer ?? "Pinned from an idle Pi session. ..."> }`
  - Server emits each event with `seq = nextSeq(sessionId)` from the same shared session counter as queue/activity.
  - `session.messages` updated atomically with each journal change.

- **Must NOT Have**:
  - Any change to existing `appendLog(...)` API or log strings (PR4 LISTENS to log writes, doesn't replace them).
  - Any change to message contents beyond what spec dictates.
  - Any client-side reducer code (Swift PR is Step 2).
  - Any retroactive replay of historical sessions on PR4 deploy — only sessions created **after** the journal init produce messages live; existing sessions show `messages: []` until an event fires.

## Context (Evidence)

- `agentd/src/protocol.ts:138-147` — `PickySessionMessageSchema` already in PR1.
- `agentd/src/protocol.ts:163` — `PickyAgentSessionSchema.messages` field already in PR1 with default `[]`.
- `agentd/src/protocol.ts:217-219` — `sessionMessageAppended/Replaced/Removed` events already in PR1.
- `agentd/src/domain/log-prefixes.ts` — exports `STEER_PREFIX`, `FOLLOWUP_PREFIX`, `HANDOFF_PREFIX`, `EXTENSION_ANSWER_PREFIX` (PR1).
- `agentd/src/session-supervisor.ts:309-311` — `createSideFromHandoff` emits `${HANDOFF_PREFIX}${handoff.instructions}` and optionally `main-agent handoff cwd: ...`.
- `agentd/src/session-supervisor.ts:343-344` — `createEmptySideSession` emits `manual side agent: waiting for first instruction` (NOT a HANDOFF_PREFIX, so does NOT generate a journal entry — desired; the empty side session has no initial user_text until the user types one).
- `agentd/src/session-supervisor.ts:368-378` — `pinSideSession` constructs synthetic logs via `buildPinnedSideSessionLogs` and a `finalAnswer = "Pinned from an idle Pi session..."`. PR4 builder uses these to seed the 3 journal entries at session creation.
- `agentd/src/session-supervisor.ts:731` — `await this.appendLog(sessionId, \`${FOLLOWUP_PREFIX}${text}\`)` — composer follow-up.
- `agentd/src/session-supervisor.ts:806` — `await this.appendLog(sessionId, \`${STEER_PREFIX}${text}\`)` — composer steer.
- `agentd/src/session-supervisor.ts:838` — `await this.appendLog(sessionId, \`${EXTENSION_ANSWER_PREFIX}${summary}\`)` — extension UI answer.
- `agentd/src/application/runtime-event-handler.ts:43-49` — assistant_delta accumulator (`assistantDrafts`).
- `agentd/src/application/runtime-event-handler.ts:55-89` — terminal status flushes `assistantDrafts.set(sessionId, "")` (line 80). PR4 hooks into this flush to commit a final agent_text message.
- `agentd/src/application/runtime-event-handler.ts:91-104` — thinking_delta accumulator (`thinkingDrafts`).
- `agentd/src/application/runtime-event-handler.ts:109-117` — extension UI request → `pendingExtensionUiRequest` patch (waiting_for_input).
- `agentd/src/runtime/types.ts:14-21` — RuntimeEvent types: `assistant_delta`, `thinking_delta`, `status`, `tool`, `extension_ui`, `log`. PR2 adds `queue_update`. PR4 introduces no new runtime event variants — it consumes what already flows.
- `agentd/src/server.ts:38-44` — supervisor event channel wiring. PR4 adds three `messageAppended`, `messageReplaced`, `messageRemoved` channels mirroring queue / activity.

## Assumptions
- `appendLog(...)` is the single funnel for log emission inside supervisor. PR4 hooks **inside** `appendLog(...)` AFTER persistence: detect known prefixes and emit a builder action. **Alternative considered**: explicit `recordUserMessage(...)` call at each callsite. Chosen: prefix-detection inside `appendLog` for minimal churn and maximum coverage (any future code path that uses one of the 4 prefixes automatically becomes a journal source).
- The journal is keyed solely by session id. Cross-session ordering is not preserved (out of scope; spec is per-card).
- Stable id strategy:
  - User-text messages → `msg-${randomUUID()}`.
  - Pin-side seed messages → `msg-pin-user`, `msg-pin-system`, `msg-pin-agent` (deterministic per session).
  - assistant_text turn boundary → `msg-agent-text-${turnIndex}-${randomUUID()}` (or just random — boundary semantics make the id non-deterministic by design).
  - agent_thinking → one id per thinking phase, regenerated each boundary entry.
  - agent_question → use `request.id` from `PickyExtensionUiRequest`.
  - agent_report → caller (PR5) provides id (or builder generates).
  - agent_error / system → randomUUID.
- Shared `seq` counter (PR2): every emission of message OR queue OR activity event uses `this.nextSeq(sessionId)`. The counter is monotonic across event types so stale-event detection works on the client.
- For pinned sessions, no runtime events ever arrive. The 3 seed entries are inserted synchronously inside `pinSideSession(...)` after `await this.upsert(session)` and before `materializeTerminalArtifacts`.
- The "transcript first line" used for the pinned `user_text` content is: take `context.transcript`, split on `/\r?\n/`, find the **first non-empty trimmed line**, trim it. Fallback if transcript is empty: `"(no goal supplied)"` or `session.title`.

## Execution Strategy (Parallel Waves)

- **Wave 1 (foundation)**:
  - W1-A: New `session-message-builder.ts` module with internal Map state + emission interface. No supervisor wiring yet.
  - W1-B: `SessionMessageBuilder` deps interface (`emitAppended`, `emitReplaced`, `emitRemoved`, `nextSeq`, `now`).
- **Wave 2 (wiring)** — depends on W1:
  - W2-A: SessionSupervisor instantiates builder; passes `nextSeq` + emit callbacks; wires builder into RuntimeEventHandler boundary signals.
  - W2-B: server.ts adds three channel forwards.
- **Wave 3 (sources)** — depends on W2 (each can be a sub-PR but plan is sequential):
  - W3-A: User-text from log prefixes (steer/followUp/handoff/extension answer).
  - W3-B: Pin-side seed entries.
  - W3-C: assistant_delta turn-boundary commit.
  - W3-D: thinking_delta replace + boundary remove.
  - W3-E: extensionUiRequest → agent_question.
  - W3-F: cancelled / failed status → system / agent_error.
  - W3-G: `recordFinalReport(sessionId, report)` API stub (no caller in PR4; PR5 wires it).
- **Wave 4** (tests).

## Task Breakdown

### 1. SessionMessageBuilder module — Complexity: High
- **What**: Self-contained class managing one journal per session.
- **Where**: New file `agentd/src/session-message-builder.ts`.
- **Public API**:
  ```ts
  export interface SessionMessageBuilderDeps {
    emitAppended(sessionId: string, message: PickySessionMessage, seq: number): Promise<void>;
    emitReplaced(sessionId: string, messageId: string, message: PickySessionMessage, seq: number): Promise<void>;
    emitRemoved(sessionId: string, messageId: string, seq: number): Promise<void>;
    nextSeq(sessionId: string): number;
    now(): string;     // ISO timestamp; injectable for tests
    syncSessionMessages(sessionId: string, messages: readonly PickySessionMessage[]): Promise<void>;
  }

  export class SessionMessageBuilder {
    constructor(private readonly deps: SessionMessageBuilderDeps);

    // User-text inputs (from log prefix detection in appendLog).
    async recordUserText(sessionId: string, text: string, originatedBy: PickyMessageOrigin): Promise<void>;

    // Pin-side: 3-entry seed; only call once per session.
    async seedPinnedSession(sessionId: string, transcript: string | undefined, finalAnswer: string | undefined, title: string): Promise<void>;

    // Question events.
    async recordExtensionQuestion(sessionId: string, request: PickyExtensionUiRequest): Promise<void>;
    async cancelExtensionQuestion(sessionId: string, requestId: string): Promise<void>;  // adds cancelledAt; stays in journal as replaced

    // Final report (called from PR5).
    async recordFinalReport(sessionId: string, report: PickyFinalReport): Promise<string /* messageId */>;

    // Error / system.
    async recordError(sessionId: string, errorMessage: string, errorContext?: string): Promise<void>;
    async recordSystemMessage(sessionId: string, text: string): Promise<void>;

    // Runtime stream signals (called from RuntimeEventHandler).
    appendAssistantDelta(sessionId: string, delta: string): void;        // synchronous buffer
    flushAssistantText(sessionId: string): Promise<void>;                // commits buffer at boundary
    appendThinkingDelta(sessionId: string, delta: string): Promise<void>;
    flushThinking(sessionId: string): Promise<void>;                     // remove agent_thinking message

    // Session lifecycle.
    onSessionRemoved(sessionId: string): void;                            // GC internal state
  }
  ```
- **Internal state per session**:
  ```ts
  interface JournalEntry {
    seq: number;
    message: PickySessionMessage;
  }
  interface SessionState {
    journal: JournalEntry[];                       // chronological
    removedIds: Set<string>;                        // ids that were removed; future replace ignored
    assistantDraft: string;                         // accumulated for next flush
    thinkingDraft: string;
    activeThinkingId?: string;
  }
  ```
- **Boundary commit invariant**:
  - `flushAssistantText` no-ops if `assistantDraft === ""`.
  - On commit: generate id, push entry, emit `appended`, `syncSessionMessages`, clear draft.
- **Thinking invariant**:
  - First `appendThinkingDelta` for a session-with-no-active-thinking: generate id, append entry with text=delta, emit `appended`, set `activeThinkingId`.
  - Subsequent appendThinkingDelta: accumulate, replace entry payload, emit `replaced`.
  - `flushThinking`: emit `removed`, add to `removedIds`, clear `activeThinkingId`.
- **Removed-id replace dropping** (invariant):
  - All `replace` paths must check `if (state.removedIds.has(messageId)) return;` before emitting.
- **Why a separate module?** Isolates ~250 LOC of state machine, enables focused unit tests independent of supervisor.
- **Depends on**: PR1 schemas, PR2 `nextSeq`.
- **Blocks**: tasks 2-9.
- **Risks**:
  - Circular dependency between SessionMessageBuilder and SessionSupervisor — solved by passing `deps` (callback bag) at construction time.
  - Memory growth for very long sessions — acceptable in PR4; spec §7.4 acknowledges pagination is future.
- **Acceptance checks**:
  - `cd agentd && npm run build` → green.
  - Unit tests for module in `agentd/src/session-message-builder.test.ts` (new) — see task 9.

### 2. SessionSupervisor wiring — Complexity: Medium
- **What**:
  1. Instantiate `SessionMessageBuilder` in supervisor constructor:
     ```ts
     this.messageBuilder = new SessionMessageBuilder({
       emitAppended: async (sessionId, message, seq) => { this.emit("messageAppended", sessionId, message, seq); },
       emitReplaced: async (sessionId, messageId, message, seq) => { this.emit("messageReplaced", sessionId, messageId, message, seq); },
       emitRemoved: async (sessionId, messageId, seq) => { this.emit("messageRemoved", sessionId, messageId, seq); },
       nextSeq: (sessionId) => this.nextSeq(sessionId),
       now: () => new Date().toISOString(),
       syncSessionMessages: async (sessionId, messages) => { await this.patch(sessionId, { messages: [...messages] }); },
     });
     ```
  2. Pass builder to `RuntimeEventHandler` deps so it can call `appendAssistantDelta`, `flushAssistantText`, `appendThinkingDelta`, `flushThinking`, `recordExtensionQuestion`, `recordError`, `recordSystemMessage`. Extend the deps interface accordingly.
  3. Wire server.ts to forward the three new emit channels (mirroring `queueUpdated` / `activityUpdated` from PR2/PR3):
     ```ts
     this.options.supervisor.on("messageAppended", (sessionId, message, seq) =>
       this.broadcast({ type: "sessionMessageAppended", sessionId, message, seq }));
     this.options.supervisor.on("messageReplaced", (sessionId, messageId, message, seq) =>
       this.broadcast({ type: "sessionMessageReplaced", sessionId, messageId, message, seq }));
     this.options.supervisor.on("messageRemoved", (sessionId, messageId, seq) =>
       this.broadcast({ type: "sessionMessageRemoved", sessionId, messageId, seq }));
     ```
- **Where**: `agentd/src/session-supervisor.ts` (constructor + class field), `agentd/src/server.ts:38-44`.
- **Depends on**: task 1.
- **Blocks**: tasks 3-9.
- **Acceptance checks**: typecheck, no behavior change yet.

### 3. User-text source: log-prefix detection inside appendLog — Complexity: Low
- **What**: Hook builder calls inside `SessionSupervisor.appendLog(...)` (lines 855-862).
- **Where**: `agentd/src/session-supervisor.ts:855-862`.
  ```ts
  private async appendLog(sessionId: string, line: string): Promise<void> {
    const session = this.mustGet(sessionId);
    const changedFiles = mergeChangedFiles(session.changedFiles, extractChangedFilesFromExplicitText(line));
    const linkArtifacts = extractSessionLinkArtifacts(line).filter((artifact) => !session.artifacts.some((existing) => existing.url === artifact.url));
    const artifacts = mergeArtifacts(session.artifacts, linkArtifacts);
    await this.patch(sessionId, { logs: [...session.logs, line], changedFiles, artifacts });
    this.emit("log", sessionId, line);

    // PR4: detect user-text prefixes and seed journal entries
    if (line.startsWith(STEER_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(STEER_PREFIX.length), "user");
    } else if (line.startsWith(FOLLOWUP_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(FOLLOWUP_PREFIX.length), "user");
    } else if (line.startsWith(EXTENSION_ANSWER_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(EXTENSION_ANSWER_PREFIX.length), "user");
    } else if (line.startsWith(HANDOFF_PREFIX)) {
      await this.messageBuilder.recordUserText(sessionId, line.slice(HANDOFF_PREFIX.length), "main_agent");
    }
  }
  ```
- **Depends on**: task 2.
- **Blocks**: tests.
- **Risks**:
  - Replay on session load: when `SessionSupervisor.load()` parses persisted sessions, it does NOT re-call `appendLog` — historical logs are loaded as part of the session record. This means **historical user-text entries from before PR4 will NOT appear in the journal**, only new ones after PR4 deploy. Acceptable per spec §3.5 ("daemon restart 시점의 best-effort 복원").
  - **Potential issue**: spec §1.8 lists Pinned messages with `originatedBy: "pi_extension"` — handled in task 4 (pin-side seed), not in `appendLog` since `pinSideSession` doesn't use `HANDOFF_PREFIX`.
- **Acceptance checks**:
  - Test: call `supervisor.steer(id, "hello")` → builder receives `recordUserText(id, "hello", "user")` → emits `messageAppended` with `kind: "user_text", originatedBy: "user", text: "hello"`.

### 4. Pin-side seed source — Complexity: Low
- **What**: After `pinSideSession` upserts the session (line 376), seed the 3-entry journal.
- **Where**: `agentd/src/session-supervisor.ts:367-379`.
  ```ts
  await this.upsert(session);
  await this.messageBuilder.seedPinnedSession(id, context.transcript, session.finalAnswer, session.title);
  await this.materializeTerminalArtifacts(id);
  ```
  Inside `SessionMessageBuilder.seedPinnedSession`:
  ```ts
  const goal = firstNonEmptyLine(transcript) ?? title ?? "(no goal supplied)";
  await this.appendInternal(sessionId, { kind: "user_text", text: goal, originatedBy: "pi_extension", id: `msg-pin-user-${sessionId}` });
  await this.appendInternal(sessionId, { kind: "system", text: "Pinned from idle Pi session", id: `msg-pin-system-${sessionId}` });
  if (finalAnswer) {
    await this.appendInternal(sessionId, { kind: "agent_text", text: finalAnswer, id: `msg-pin-agent-${sessionId}` });
  }
  ```
- **Depends on**: tasks 1-2.
- **Blocks**: tests.
- **Risks**:
  - Pinned session reattach (PR6) will spawn additional message events — those use the random-id path. The deterministic `msg-pin-*` ids won't collide.
- **Acceptance checks**:
  - Test: pinSideSession with non-empty transcript → 3 messages appended in order with the right ids and originatedBy.
  - Test: pinSideSession with empty transcript → `text` falls back to `title` or `"(no goal supplied)"`.

### 5. assistant_delta turn-boundary commit — Complexity: Medium
- **What**: Buffer assistant_delta in builder, commit on boundary.
- **Where**: `agentd/src/application/runtime-event-handler.ts`.
  - In `applyStatusEvent` terminal block (line 80-87, after clearing drafts):
    ```ts
    if (terminal) {
      // Flush any buffered assistant_text BEFORE clearing local drafts.
      await this.dependencies.messageBuilder.flushAssistantText(sessionId);
      await this.dependencies.messageBuilder.flushThinking(sessionId);
      // ...
    }
    ```
  - In the assistant_delta branch (line 35-37):
    ```ts
    if (event.type === "assistant_delta") {
      this.assistantDrafts.set(sessionId, `${this.assistantDrafts.get(sessionId) ?? ""}${event.delta}`);
      this.dependencies.messageBuilder.appendAssistantDelta(sessionId, event.delta);
      return;
    }
    ```
  - In `applyToolEvent` (line 121, after the activity-counter increment from PR3):
    ```ts
    // Tool start = boundary for assistant_text and thinking
    if (event.status === "running") {
      await this.dependencies.messageBuilder.flushAssistantText(sessionId);
      await this.dependencies.messageBuilder.flushThinking(sessionId);
    }
    ```
  - In `applyExtensionUiEvent` waiting branch:
    ```ts
    await this.dependencies.messageBuilder.flushAssistantText(sessionId);
    await this.dependencies.messageBuilder.flushThinking(sessionId);
    await this.dependencies.messageBuilder.recordExtensionQuestion(sessionId, request);
    ```
  - On user_text arrival (the `appendLog` prefix-detect path in task 3): also flush prior assistant_text (an open assistant turn ending). Add to `recordUserText` first lines:
    ```ts
    async recordUserText(...) {
      await this.flushAssistantText(sessionId);
      await this.flushThinking(sessionId);
      // ...
    }
    ```
- **Depends on**: tasks 1-2.
- **Blocks**: tests.
- **Risks**:
  - **Boundary order**: status terminal must flush BEFORE the `assistantDrafts.set(sessionId, "")` clear at line 80, otherwise builder's draft is also lost (builder maintains its own copy, so this is defensive only).
  - Multiple consecutive `tool` running events for the same call (e.g. update events) — the dedup map from PR3 handles activity, but `flushAssistantText` would no-op on second call (empty buffer). Safe.
- **Acceptance checks**:
  - Test: 3 assistant_deltas + status terminal → 1 messageAppended with concatenated text.
  - Test: assistant_delta + tool_start + assistant_delta + tool_start + status → 2 messageAppended (one per text segment).
  - Test: assistant_delta + status:waiting_for_input → 1 messageAppended (text up to that point).

### 6. thinking_delta replace + boundary remove — Complexity: Medium
- **What**: Each thinking_delta updates a single agent_thinking message; boundary removes it.
- **Where**: `agentd/src/application/runtime-event-handler.ts:91-104`.
  ```ts
  private async applyThinkingEvent(sessionId: string, event: Extract<RuntimeEvent, { type: "thinking_delta" }>): Promise<void> {
    if (!event.delta) return;
    // PR3 increment-on-boundary already handled at start of this method.
    await this.dependencies.messageBuilder.appendThinkingDelta(sessionId, event.delta);
    // Existing thinkingPreview update logic stays.
    // ...
  }
  ```
- Boundary triggers (re-using same code paths as assistant_delta flush in task 5):
  - status terminal → `flushThinking`
  - status `waiting_for_input` → `flushThinking`
  - tool start → `flushThinking`
  - user_text → `flushThinking`
  - assistant_delta → `flushThinking` (signals the thinking phase ended even within a turn)
- Inside builder:
  ```ts
  async appendThinkingDelta(sessionId, delta) {
    const state = this.states.get(sessionId)!;
    state.thinkingDraft += delta;
    if (!state.activeThinkingId) {
      const id = `msg-thinking-${randomUUID()}`;
      state.activeThinkingId = id;
      await this.appendInternal(sessionId, { id, kind: "agent_thinking", text: state.thinkingDraft });
      // appendInternal -> emit appended + sync session.messages
    } else {
      const seq = this.deps.nextSeq(sessionId);
      const message = { ...findEntry(state.activeThinkingId).message, text: state.thinkingDraft, createdAt: this.deps.now() };
      replaceEntry(state, state.activeThinkingId, message);
      await this.deps.emitReplaced(sessionId, state.activeThinkingId, message, seq);
      await this.deps.syncSessionMessages(sessionId, journalToMessages(state));
    }
  }

  async flushThinking(sessionId) {
    const state = this.states.get(sessionId);
    if (!state?.activeThinkingId) return;
    const id = state.activeThinkingId;
    const seq = this.deps.nextSeq(sessionId);
    removeEntry(state, id);
    state.removedIds.add(id);
    state.activeThinkingId = undefined;
    state.thinkingDraft = "";
    await this.deps.emitRemoved(sessionId, id, seq);
    await this.deps.syncSessionMessages(sessionId, journalToMessages(state));
  }
  ```
- **Depends on**: tasks 1-2, 5.
- **Blocks**: tests.
- **Risks**: Per spec, removed thinking IDs cannot be replaced. Enforced by `removedIds.has(...)` guard in any future replace path; thinking_delta arriving after `flushThinking` starts a NEW activeThinkingId (because `state.activeThinkingId === undefined` at that point).
- **Acceptance checks**:
  - Test: 5 thinking_deltas → 1 appended + 4 replaced (or 5 replaced, depending on whether first delta does append or replace; per pseudocode above: 1 append + 4 replace).
  - Test: 5 thinking_deltas + status terminal → +1 removed.
  - Test: thinking → assistant_delta → thinking → 2 separate (append+removed) cycles with different ids.

### 7. extensionUiRequest → agent_question — Complexity: Low
- **What**: When `RuntimeEventHandler.applyExtensionUiEvent` waiting path fires, builder records an `agent_question` with `id = request.id`.
- **Where**: task 5 wiring already includes the `recordExtensionQuestion` call.
- **Builder**:
  ```ts
  async recordExtensionQuestion(sessionId, request) {
    await this.appendInternal(sessionId, { id: request.id, kind: "agent_question", question: request });
  }
  ```
- **Cancellation** (PR6 scope, but stub the API now):
  ```ts
  async cancelExtensionQuestion(sessionId, requestId) {
    const state = this.states.get(sessionId);
    const entry = state?.journal.find(e => e.message.id === requestId);
    if (!entry || state!.removedIds.has(requestId)) return;
    const seq = this.deps.nextSeq(sessionId);
    const updated = { ...entry.message, cancelledAt: this.deps.now() };
    replaceEntry(state!, requestId, updated);
    await this.deps.emitReplaced(sessionId, requestId, updated, seq);
    await this.deps.syncSessionMessages(sessionId, journalToMessages(state!));
  }
  ```
  PR4 ships the API; PR6 wires the call from supervisor when steer/followUp interrupts a waiting question.
- **Depends on**: tasks 1-2, 5.
- **Risks**: If the same `request.id` reappears (shouldn't), `appendInternal` should treat as no-op (idempotency).
- **Acceptance checks**:
  - Test: extensionUiRequest event with `waitsForInput: true` → messageAppended with `kind: "agent_question"` and id matching request.id.

### 8. Failed / cancelled status → agent_error / system — Complexity: Low
- **What**: Hook in `applyStatusEvent` terminal branch:
  ```ts
  if (terminal) {
    await this.dependencies.messageBuilder.flushAssistantText(sessionId);
    await this.dependencies.messageBuilder.flushThinking(sessionId);
    if (event.status === "failed") {
      await this.dependencies.messageBuilder.recordError(sessionId, event.summary ?? "Agent failed", undefined);
    } else if (event.status === "cancelled") {
      await this.dependencies.messageBuilder.recordSystemMessage(sessionId, "Cancelled by user");
    }
    // existing logic ...
  }
  ```
- **Builder**:
  ```ts
  async recordError(sessionId, errorMessage, errorContext) {
    await this.appendInternal(sessionId, { id: `msg-err-${randomUUID()}`, kind: "agent_error", errorMessage, errorContext });
  }
  async recordSystemMessage(sessionId, text) {
    await this.appendInternal(sessionId, { id: `msg-sys-${randomUUID()}`, kind: "system", text });
  }
  ```
- **Depends on**: tasks 1-2, 5.
- **Risks**: Be careful with `noTurnRan: true` synthesized completions — those flip to "completed" but the spec doesn't want a system message there. Skip both error and system message when `event.noTurnRan === true`.
- **Acceptance checks**:
  - Test: status=failed → messageAppended with kind=agent_error, errorMessage matches summary.
  - Test: status=cancelled → messageAppended with kind=system, text="Cancelled by user".
  - Test: status=completed (normal) → no error/system message.
  - Test: status=completed with noTurnRan → no error/system, no agent_text flush either (buffer was empty).

### 9. recordFinalReport API stub — Complexity: Low
- **What**: Public API on builder; PR5 calls it from `submit_final_report.execute`.
- **Where**: `agentd/src/session-message-builder.ts`:
  ```ts
  async recordFinalReport(sessionId, report): Promise<string> {
    const id = `msg-report-${randomUUID()}`;
    await this.appendInternal(sessionId, { id, kind: "agent_report", report });
    return id;
  }
  ```
- No supervisor hook in PR4 (PR5 wires it).
- **Depends on**: tasks 1-2.
- **Risks**: none.
- **Acceptance checks**:
  - Test: direct call to builder → messageAppended with kind=agent_report.

### 10. Tests — Complexity: High
- **Where**:
  - `agentd/src/session-message-builder.test.ts` (new) — module-level tests.
  - `agentd/src/session-supervisor.test.ts` — integration tests.
- **Module tests**:
  1. recordUserText user → appended with originatedBy=user.
  2. recordUserText main_agent → appended with originatedBy=main_agent.
  3. seedPinnedSession with full transcript → 3 entries in order, deterministic ids.
  4. seedPinnedSession without transcript → fallback uses title.
  5. seedPinnedSession without finalAnswer → 2 entries (user_text + system).
  6. appendThinkingDelta single → 1 appended.
  7. appendThinkingDelta ×3 → 1 appended + 2 replaced (or 1 + 3? clarify: implementation does "append on first, replace on subsequent", so 5 deltas = 1 append + 4 replace).
  8. flushThinking → removed; subsequent appendThinkingDelta starts new id.
  9. flushThinking on no-active → no-op.
  10. removed id replaced → no-op (verify removedIds guard).
  11. cancelExtensionQuestion → replaced with cancelledAt; subsequent cancel → no-op.
  12. recordError → appended with kind=agent_error.
  13. recordSystemMessage → appended with kind=system.
  14. recordFinalReport → appended with kind=agent_report.
  15. seq monotonic across all emit paths.
- **Integration tests** (in supervisor test file, using `MockRuntime`):
  16. composer steer → user_text appended.
  17. composer follow-up → user_text appended.
  18. extension answer log → user_text appended.
  19. main-agent handoff (`createSideFromHandoff`) → user_text with originatedBy=main_agent.
  20. assistant_delta + status terminal → agent_text appended at terminal.
  21. tool_start during assistant_delta accumulation → agent_text flushed before tool call.
  22. status=cancelled → system "Cancelled by user".
  23. status=failed → agent_error.
  24. session.messages reflected in `supervisor.get(id).messages`.
  25. Pinned session creation → 3 messages in session.messages immediately.
- **Depends on**: tasks 1-9.
- **Blocks**: PR4 ship.
- **Acceptance checks**:
  - `cd agentd && npm test` → all green.

## Test & QA Scenarios

- [ ] Happy: new visible session, single turn with thinking + 1 tool + final text → events `[append(thinking)→replace(thinking)…→remove(thinking)→append(tool flush no-op)→append(text)]` at terminal.
- [ ] Happy: pinned session created → 3 messages immediately, no further events.
- [ ] Edge: thinking_delta → tool → thinking_delta → tool → text → status terminal: 2 thinking phases (separate ids), 1 final agent_text.
- [ ] Edge: removed messageId can never be replaced (verified by builder unit test 10).
- [ ] Edge: noTurnRan completion → no error/system/agent_text (empty buffers, skip flushes).
- [ ] Edge: appendLog with unknown prefix → no journal entry (only known 4 prefixes).
- [ ] Regression: existing log emission unchanged (other tests still pass).
- [ ] Regression: existing session-supervisor tests pass.

## Edge Cases & Risks

- **Empty assistant draft on terminal** — `flushAssistantText` no-ops on empty draft. Test 5 covers this implicitly.
- **Unicode handling** — assistant_delta accumulator already uses simple string concatenation; same here. No surrogate splitting expected because Pi SDK delivers complete UTF-16 chunks.
- **Concurrency** — `appendLog` and runtime events serialize through the same supervisor instance (single-threaded Node). No locking needed.
- **Pinned session reattach (PR6)** — when reattach lands, the deterministic `msg-pin-*` ids will coexist with new random ids. No conflict.
- **Daemon restart loses journal** — explicit per spec §3.5. Logs preserved; future task can backfill.
- **Builder memory** — long sessions accumulate. Acceptable for v1; pagination is §7.4 future work.
- **`syncSessionMessages` write amplification** — every emit writes session.messages to disk via `patch`. For very long sessions this could be slow. Consider in-memory-only sync + disk write at debounce; out of scope for PR4 (spec §7.12).

## Decisions Needed
1. **Should `recordUserText` for main-agent handoff (`HANDOFF_PREFIX`) include the main-agent's `userMessage` field too?** Plan: NO — only `instructions` portion is logged with `HANDOFF_PREFIX` and that becomes the user_text content. `userMessage` is a separate side-channel between main agent and user (per spec §1.8 NOTE). Worker should verify nothing else logs userMessage with HANDOFF_PREFIX.
2. **Should `appendInternal` itself sync `session.messages` synchronously, or batch?** Plan: sync (simpler, slower). If perf becomes an issue Step 3 can add debouncing.
3. **Should `seedPinnedSession` emit individual `messageAppended` events or just patch session.messages once?** Plan: emit individual events for consistency (clients see messages flow in like any other session). Worker: confirm Swift side's reducer handles this idempotently (it should — session field carries current state too).

## Defaults Applied
- Stable id strategy: deterministic for pin-side seeds (`msg-pin-*-${sessionId}`); random UUID for everything else.
- Boundary set: status terminal | status waiting_for_input | tool_start | user_text | extension_ui waiting | assistant_delta (for thinking only).
- session.messages synced on every emit.
- Builder is the live SoT; logs are restart-fallback only (no replay in PR4).

## Verification Checklist
```bash
cd /Users/creatrip/Documents/picky/agentd
npm run build
npm test
```
Expected:
- All existing tests pass.
- ~25 new tests added under PR4 scope all pass.
- `rg -n "messageBuilder" agentd/src` → finds wiring in supervisor + RuntimeEventHandler.
- Manual trace on a session: drive a turn through MockRuntime, assert journal in `supervisor.get(id).messages` matches expected order.

## Worker Reporting Requirements
After implementation, worker MUST report:
- `git status --short` — confirm only PR4-scoped files touched.
- File-by-file change summary mapped back to tasks 1-10.
- Test counts (pass/fail) for `npm test`.
- If context limit hit before all tasks: report which tasks are complete and which remain (priority order: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10).
- **Do not commit.**

## Estimated Effort
High — largest module of the PR2~5 chain. ~250 LOC builder + ~80 LOC supervisor wiring + ~30 LOC server wiring + ~25 tests. Risk concentrated in boundary semantics (assistant_delta + thinking) and seq ordering. Worker should plan for ~2x effort vs PR2/PR3.

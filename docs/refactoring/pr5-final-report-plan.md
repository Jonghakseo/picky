# PR5 — submit_final_report tool Plan

**Status**: planning only — do NOT modify source code in this task.
**SoT spec**: `docs/refactoring/side-card-conversation-redesign.md` §1.7, §3.1, §7.15.
**Context handoff**: `/tmp/picky-pr2-5-context.md`.
**Base**: `main` @ commit `7a33393` + PR2 + PR3 + PR4.
**Sequential dependency**: PR4 (calls `messageBuilder.recordFinalReport(...)`) and PR2 (`nextSeq`).

## Goal
Define and inject the `submit_final_report` tool for Picky-started side sessions. Tool execution patches `session.finalReport`, fires the PR4 message builder to insert an `agent_report` journal entry, sets `finalAnswer = report.summary` for backwards compat, and defers status patch to turn-end (per decision §7.15 = C). Pinned sessions remain excluded.

## Intent Type
Build (one new tool definition + injection point + supervisor lifecycle hook).

## Scope

- **In** (PR5):
  1. New `agentd/src/application/submit-final-report-tool.ts` exporting `createPickySubmitFinalReportTool(onSubmit)`. Mirrors the structure of `agentd/src/application/handoff-tool.ts`.
  2. Tool injects into Picky-started side sessions only. Specifically:
     - Modify `agentd/src/index.ts:32` so the **side-session runtime** (the one passed to `SessionSupervisor` via the `runtime` constructor parameter) gets `submit_final_report` added to its `customTools`.
     - Main-agent runtime (line 33-66) does NOT receive this tool.
     - Pinned sessions (created by `pinSideSession`) never get a runtime handle, so injection is moot — but document the exclusion.
  3. New `SessionSupervisor.submitFinalReport(sessionId, report)`:
     - Patches `finalReport`.
     - Patches `finalAnswer = report.summary` (backwards-compat per spec §3.1 NOTE).
     - Calls `messageBuilder.recordFinalReport(sessionId, report)`.
     - Stores the report on a per-session "pending status patch" map. The actual `status` patch (`completed` vs `blocked`) happens on turn-end.
  4. Turn-end status patch hook in `RuntimeEventHandler.applyStatusEvent` terminal branch: if a `pendingFinalReport[sessionId]` exists when status terminal arrives, patch status as:
     - `report.status === "blocked"` → session status `"blocked"`
     - else → session status `"completed"` (overrides whatever the runtime emitted).
     - Then clear the pending entry.
  5. Last-wins-within-turn: if `submit_final_report` is called twice in the same turn, the second call replaces `pendingFinalReport[sessionId]` and overwrites the journal's `agent_report` message via builder's `recordFinalReport` returning the same id (or a new id; spec is OK with append-twice but recommend last-wins replace).
  6. Tests covering all the above.

- **Out**:
  - System-prompt strict instruction to call `submit_final_report` (decision §3.1 = "Step 2 시스템 프롬프트 강제"). PR5 only registers the tool; PR6 / Step 2 work activates the system prompt.
  - Step 1 fallback warning ("submit_final_report 호출 없이 종료됨") — open question §7.3, not in PR5.
  - UI rendering of the report — Swift / SwiftUI Step 2.
  - Pinned reattach changes — PR6.

- **Must Have**:
  - Tool definition validates payload via TypeBox schema mirroring `PickyFinalReportSchema` (summary/body/status required, artifacts optional).
  - Tool execute returns `"Final report recorded"` ack so the model can continue.
  - `finalReport` field populated immediately on execute; status patch deferred to turn-end.
  - `finalAnswer = report.summary` patched on execute (NOT on turn-end) — keeps existing UI consistent.
  - Pinned sessions never see this tool in their `customTools`.
  - Existing tests continue to pass.

- **Must NOT Have**:
  - Any system-prompt change.
  - Any UI changes.
  - Force-success: status patch must reflect `report.status`, not always "completed".
  - Any retroactive backfill on existing sessions.

## Context (Evidence)

- `agentd/src/protocol.ts:128-136` — `PickyFinalReportSchema` already in PR1.
- `agentd/src/protocol.ts:163` — `PickyAgentSession.finalReport` field already in PR1 with `optional()`.
- `agentd/src/application/handoff-tool.ts:1-6` — pattern for `defineTool` + `Type.Object(...)` schema. Use as template.
- `agentd/src/application/handoff-tool.ts:38-71` — `createPickyHandoffTool` structure to mirror: defineTool with name, label, description, promptSnippet, promptGuidelines, parameters, execute.
- `agentd/src/index.ts:32` — `const runtime = useMockRuntime ? new MockRuntime() : new PiSdkRuntime({ customTools: [askUserQuestionTool] });` — side-session runtime customTools array. PR5 adds `submitFinalReportTool` here.
- `agentd/src/index.ts:33-66` — main-agent runtime customTools (handoff, side_sessions, side_steer, pointer). PR5 does NOT modify this.
- `agentd/src/application/runtime-event-handler.ts:55-89` — `applyStatusEvent` terminal block. PR5 adds final-report status override before existing patch logic.
- `agentd/src/session-supervisor.ts:368-378` — `pinSideSession` creates session with `status: "completed"` and no runtime handle. No tool injection happens for pinned sessions.
- `agentd/src/session-supervisor.ts:373` — `pinned: true` — useful for future skip-checks.
- `agentd/src/application/handoff-tool.ts:11-15, 17-21` — TypeScript types for tool requests; use similar pattern for `PickySubmitFinalReportRequest`.
- PR1 `PickyFinalReportSchema`: `{ summary: string, body: string, status: "success"|"partial"|"blocked", artifacts: { kind, title, url? }[] }`.
- PR4 `messageBuilder.recordFinalReport(sessionId, report) -> Promise<string>` API stub already exists.

## Assumptions
- `customTools` is a per-`PiSdkRuntime` config (from `index.ts:32`), so injecting into the side-session runtime automatically applies to ALL side sessions started via `createTask` / `createEmptySideSession` / `createSideFromHandoff` / handoff-tool.onHandoff. Pinned sessions don't go through `runtime.create()` / `prewarm()`, so they don't receive the tool — verified by reading `pinSideSession` in supervisor (line 350-379).
- The Pi SDK `defineTool` `execute` callback receives `(_toolCallId, params)`. The `params` are validated against the TypeBox schema. We DO NOT receive `sessionId` directly — it must be inferred from the runtime's session context. **Solution**: the tool definition is constructed dynamically per side session at handle-creation time, OR a wrapper function handles the lookup. Looking at `handoff-tool.ts`, the tool is constructed once at `index.ts` time and uses an `onHandoff(request)` callback that looks up `supervisor.currentMainContext()` for context. For PR5 we need a similar pattern: an `onSubmit` callback that needs `sessionId`. **Approach**: pass `sessionId` via a closure stored in `PiSdkRuntimeSession` — but the tool is shared across runtimes. **Better approach**: query the active session via `getCurrentSessionId()` callback that `PiSdkRuntime` exposes, OR use the Pi SDK's tool execution context. **Simplest approach**: the `onSubmit` callback receives `(toolCallId, request)` and the tool lookup happens via `supervisor.getSessionByActiveRuntimeHandle()` — but this is fragile.

  **Decision**: PR5 takes the cleanest approach — **register customTools per-session** by introducing a new `customToolsFactory` option on `PiSdkRuntimeOptions` that produces tools per `createHandle(sessionId)` invocation. The factory closure captures the sessionId and forwards to `supervisor.submitFinalReport(sessionId, params)`.

  Alternative if factory approach is too invasive: a **module-level "active side-session id stack"** maintained by `PiSdkRuntimeSession` (push on prompt(), pop on idle). The tool calls `popActiveSessionId()` on execute. **The factory approach is preferred** — see Task 2 for the wiring detail.

- The tool's `finalAnswer` patch overrides any existing `finalAnswer` set by the runtime's normal terminal flow. `applyStatusEvent` terminal block computes `finalAnswer` from the assistant draft; if `pendingFinalReport[sessionId]` exists, the supervisor's overriding `finalAnswer = report.summary` patch comes from the tool execute, which runs BEFORE turn-end. Order: tool execute → finalAnswer=summary patch → … → turn-end → applyStatusEvent computes its own finalAnswer (may overwrite). **Mitigation**: in `applyStatusEvent`, if `pendingFinalReport[sessionId]` exists, skip the draft-derived `finalAnswer` calculation — keep the report-derived one.

## Execution Strategy (Parallel Waves)

- **Wave 1**: Tool definition module (independent).
- **Wave 2** (depends on Wave 1):
  - W2-A: `PiSdkRuntimeOptions.customToolsFactory` plumbing (or: simpler closure-based registration in `index.ts`).
  - W2-B: SessionSupervisor `submitFinalReport(sessionId, report)` method.
- **Wave 3** (depends on Wave 2):
  - W3-A: `RuntimeEventHandler.applyStatusEvent` terminal patch override.
  - W3-B: `pendingFinalReport` map management.
- **Wave 4** (tests).

## Task Breakdown

### 1. submit-final-report-tool module — Complexity: Low
- **What**: Define the Pi SDK tool.
- **Where**: New file `agentd/src/application/submit-final-report-tool.ts`.
  ```ts
  import { defineTool, type ToolDefinition } from "@mariozechner/pi-coding-agent";
  import { Type } from "typebox";
  import type { PickyFinalReport } from "../protocol.js";

  export interface PickySubmitFinalReportRequest {
    summary: string;
    body: string;
    status: "success" | "partial" | "blocked";
    artifacts?: Array<{ kind: string; title: string; url?: string }>;
  }

  export function createPickySubmitFinalReportTool(
    onSubmit: (report: PickyFinalReport) => Promise<void>,
  ): ToolDefinition {
    return defineTool({
      name: "submit_final_report",
      label: "Submit final report",
      description: "Picky 사이드 에이전트 작업 완료 시 호출하는 최종 보고 도구. summary/body/status 필수, artifacts optional. 호출 후 자동으로 세션이 종료됨.",
      promptSnippet: "submit_final_report: 작업 완료 시 한 번 호출. summary 1-2문장, body는 markdown.",
      promptGuidelines: [
        "Picky가 시작한 사이드 에이전트는 작업이 끝나면 반드시 submit_final_report 를 호출해야 한다.",
        "status는 success | partial | blocked 중 하나. 미완료 상태로 종료되면 partial 또는 blocked.",
        "artifacts에는 변경 파일·생성 PR·관련 링크 등을 포함.",
      ],
      parameters: Type.Object({
        summary: Type.String({ description: "1-2문장 헤드라인 요약." }),
        body: Type.String({ description: "Markdown body — 변경 사항, 검증, 다음 단계 등 자유 형식." }),
        status: Type.Union(
          [Type.Literal("success"), Type.Literal("partial"), Type.Literal("blocked")],
          { description: "작업 결과 상태." },
        ),
        artifacts: Type.Optional(Type.Array(Type.Object({
          kind: Type.String(),
          title: Type.String(),
          url: Type.Optional(Type.String({ format: "uri" })),
        }))),
      }),
      execute: async (_toolCallId, params) => {
        const report: PickyFinalReport = {
          summary: params.summary,
          body: params.body,
          status: params.status,
          artifacts: params.artifacts ?? [],
        };
        await onSubmit(report);
        return {
          content: [{ type: "text", text: "Final report recorded." }],
          details: { report },
        };
      },
    });
  }
  ```
- **Depends on**: PR1 schemas.
- **Blocks**: tasks 2, 3.
- **Risks**:
  - TypeBox schema for `status` union — verify the typebox version in agentd; alternative is `Type.String({ enum: ["success", "partial", "blocked"] })`. Worker checks `node_modules/typebox` capabilities.
  - `params.artifacts ?? []` ensures the supervisor never sees `undefined`.
- **Acceptance checks**:
  - Unit test: TypeBox validation rejects missing `summary`.
  - Unit test: `execute` calls `onSubmit` with the parsed report and returns the ack.

### 2. PiSdkRuntime customToolsFactory wiring — Complexity: Medium
- **What**: Allow per-session customTools (so the tool's `onSubmit` closure has the right sessionId).
- **Where**:
  - `agentd/src/runtime/pi-sdk-runtime.ts:23-34` — extend `PiSdkRuntimeOptions`:
    ```ts
    export interface PiSdkRuntimeOptions {
      // ...existing...
      customTools?: ToolDefinition[];                                  // shared, applied to every session
      customToolsFactory?: (sessionId: string) => ToolDefinition[];    // per-session, called at createHandle time
      thinkingLevel?: ThinkingLevel;
    }
    ```
  - `agentd/src/runtime/pi-sdk-runtime.ts:71-91` — inside `createHandle(options)`:
    ```ts
    const factoryTools = this.options.customToolsFactory?.(sessionId) ?? [];
    const allCustomTools = [...(this.options.customTools ?? []), ...factoryTools];
    ```
    Pass `customTools: allCustomTools` to `createSessionFromServices`. (Currently line 86 passes `this.options.customTools` directly.)
  - `agentd/src/index.ts:32` — replace:
    ```ts
    const runtime = useMockRuntime
      ? new MockRuntime()
      : new PiSdkRuntime({
          customTools: [askUserQuestionTool],
          customToolsFactory: (sessionId) => [
            createPickySubmitFinalReportTool(async (report) => {
              await supervisor.submitFinalReport(sessionId, report);
            }),
          ],
        });
    ```
- **Depends on**: task 1.
- **Blocks**: tasks 3, 4.
- **Risks**:
  - **Pinned sessions** never trigger `createHandle`, so the factory is not invoked — confirms exclusion.
  - **Mock runtime** ignores customTools/factory — for tests we'll call `supervisor.submitFinalReport(...)` directly to simulate tool execution.
- **Acceptance checks**:
  - `cd agentd && npm run build` → green.
  - Trace inspection: a created side session's Pi runtime has `submit_final_report` in its tool registry.

### 3. SessionSupervisor.submitFinalReport — Complexity: Medium
- **What**: New method that orchestrates the patch + journal entry + pending-status setup.
- **Where**: `agentd/src/session-supervisor.ts`:
  ```ts
  private pendingFinalReports = new Map<string, PickyFinalReport>();

  async submitFinalReport(sessionId: string, report: PickyFinalReport): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      logAgentd("submit final report dropped (unknown session)", { sessionId });
      return;
    }
    logAgentd("submit final report received", { sessionId, status: report.status, summaryChars: report.summary.length });
    this.pendingFinalReports.set(sessionId, report);
    // Patch finalReport + finalAnswer immediately for live-snapshot consistency.
    await this.patch(sessionId, {
      finalReport: report,
      finalAnswer: report.summary,
    });
    // Add agent_report journal entry. If a previous report exists in this turn,
    // last-wins-within-turn: builder appends a new agent_report (clients see both;
    // the latest one is what session.finalReport points at).
    await this.messageBuilder.recordFinalReport(sessionId, report);
  }
  ```
- **Depends on**: tasks 1, 2.
- **Blocks**: task 4.
- **Risks**:
  - Race between tool execute and turn-end: `submitFinalReport` is awaited inside `tool execute`, then the model continues, possibly more tool calls or text. PR4's flushAssistantText etc. handle remaining text correctly. The pending entry sits in the map until terminal status arrives.
  - If the same sessionId calls submitFinalReport twice in a single turn → last-wins (map.set replaces; second `recordFinalReport` adds a second journal entry — clients see both, latest one is "the truth"). Acceptable per §7.15.
- **Acceptance checks**:
  - Unit test: call `supervisor.submitFinalReport(id, report)` → `supervisor.get(id).finalReport === report`, `finalAnswer === report.summary`, `messageBuilder` got the call, `pendingFinalReports.has(id) === true`.

### 4. RuntimeEventHandler turn-end status override — Complexity: Low
- **What**: At terminal status (success path), if `pendingFinalReports[sessionId]` exists, override the patch.
- **Where**: `agentd/src/application/runtime-event-handler.ts:55-89`. Add to deps:
  ```ts
  consumePendingFinalReport(sessionId: string): PickyFinalReport | undefined;
  ```
  In supervisor wiring (`session-supervisor.ts:53-61`):
  ```ts
  consumePendingFinalReport: (sessionId) => {
    const report = this.pendingFinalReports.get(sessionId);
    if (report) this.pendingFinalReports.delete(sessionId);
    return report;
  },
  ```
  In `applyStatusEvent` terminal branch (line 56-89):
  ```ts
  const pendingReport = terminal ? this.dependencies.consumePendingFinalReport(sessionId) : undefined;
  if (pendingReport) {
    // Override status & finalAnswer derived from draft.
    patch.status = pendingReport.status === "blocked" ? "blocked" : "completed";
    patch.finalAnswer = pendingReport.summary;
    patch.finalReport = pendingReport;
    patch.lastSummary = summaryFromFinalAnswer(pendingReport.summary);
  }
  ```
  Place this BEFORE `await this.dependencies.patchSession(sessionId, patch);` so the override takes effect.
- **Depends on**: tasks 1-3.
- **Blocks**: tests.
- **Risks**:
  - If runtime emits `failed` (e.g. SDK error) but a pending report exists with `status: "success"` — should we trust the pending report or the runtime? **Decision**: trust the pending report for reported status, but if the runtime status is `cancelled`, that means user pressed Stop — keep cancelled and discard the pending report. Add a guard:
    ```ts
    if (pendingReport && event.status === "cancelled") {
      // User aborted; report was set but cancelled supersedes.
      // Still patch finalReport so artifacts survive, but status stays cancelled.
      patch.status = "cancelled";
      patch.finalReport = pendingReport;
    } else if (pendingReport) {
      patch.status = pendingReport.status === "blocked" ? "blocked" : "completed";
      // ...
    }
    ```
  - `noTurnRan: true` synthesized completions: probably should NOT override (the tool wasn't called from a real turn — but if it was, the report is valid). Worker can handle by `if (event.noTurnRan && pendingReport === undefined) skip...`. **Conservative**: always honor pendingReport regardless of `noTurnRan`.
- **Acceptance checks**:
  - Test: tool execute → `pendingFinalReports.has` true → status terminal completed → `session.status === "completed"`, `finalReport` set, pending cleared.
  - Test: report.status = "blocked" → session.status = "blocked".
  - Test: report.status = "partial" → session.status = "completed" (partial not in SessionStatusSchema; map to completed).

### 5. Tests — Complexity: Medium
- **Where**:
  - `agentd/src/application/submit-final-report-tool.test.ts` (new) — module-level.
  - `agentd/src/session-supervisor.test.ts` — integration.
- **Cases**:
  1. Tool defineTool registration round-trips (TypeBox schema validates).
  2. `execute` with valid params → `onSubmit` called with normalized report (artifacts default `[]`), returns ack.
  3. TypeBox rejection: missing `summary` → execute throws or schema fails parse.
  4. supervisor.submitFinalReport sets finalReport/finalAnswer and records agent_report journal entry.
  5. submitFinalReport twice in same turn (no terminal between) → last-wins on `pendingFinalReports`, two journal entries (or one replace if implemented; spec accepts either, plan recommends two-append).
  6. Turn-end after submitFinalReport (status=success in report) → session.status=completed.
  7. Turn-end after submitFinalReport (status=blocked) → session.status=blocked.
  8. Turn-end with no pending report → existing logic preserved (regression test).
  9. abort → status=cancelled even with pending report; finalReport persisted but status=cancelled.
  10. Pinned session: customToolsFactory not invoked because pinSideSession bypasses runtime.create. Verify by inspecting that pinSideSession-created sessions don't have a runtime handle.
- **Depends on**: tasks 1-4.
- **Blocks**: PR5 ship.
- **Acceptance checks**:
  - `cd agentd && npm test` → all green.

## Test & QA Scenarios

- [ ] Happy: side session calls `submit_final_report({summary, body, status:"success"})` then turn ends → status=completed, finalReport populated, agent_report journal entry, finalAnswer = summary.
- [ ] Happy: status="blocked" → session status=blocked.
- [ ] Edge: tool called twice → last-wins; both entries appear in journal.
- [ ] Edge: tool followed by abort → status=cancelled, finalReport still saved.
- [ ] Edge: pinned session has no runtime → tool never reaches it (verified by the customToolsFactory call site).
- [ ] Regression: existing handoff-tool tests pass.
- [ ] Regression: existing session-supervisor tests pass (turn-end without report still patches as before).

## Edge Cases & Risks

- **TypeBox `Type.Union` of literals** — confirm syntax in current typebox version. Fallback: `Type.String({ enum: [...] })`.
- **Tool registration ordering** — `customToolsFactory` runs at `createHandle` time; the side runtime is shared but each session gets a fresh tool instance with a session-bound `onSubmit`. Verify Pi SDK accepts customTools per-session (the factory pattern requires re-instantiation).
- **Tool execution context unavailable** — if Pi SDK doesn't pass per-session context to `execute`, the closure-captured sessionId is the only way. Mitigation: factory pattern (chosen).
- **Force-completed during cancel** — guarded explicitly; avoid spurious "completed" carded after user aborts.
- **`finalAnswer` collision** — supervisor's own `applyStatusEvent` derives finalAnswer from the assistant draft. PR5 ensures the report-derived `finalAnswer` wins by overriding in the patch.
- **`partial` status** — `PickyFinalReportSchema` allows `partial` but `SessionStatusSchema` doesn't. Map `partial` → session.status = "completed" (model can communicate partial-ness via `report.status` itself; client decides UI).

## Decisions Needed
1. **TypeBox `status` schema syntax** — `Type.Union` vs `Type.String({ enum: [...] })`. Worker confirms which Pi SDK accepts and uses that. **Recommendation: `Type.Union([Type.Literal(...), ...])`.**
2. **Twice-call within turn semantics** — append two journal entries vs replace last. Plan recommends append (simpler, transparent to user). Worker may pick either; document choice.
3. **Cancelled vs report status** — plan: cancelled wins. Worker can change if user prefers report status to win during cancel (less common).

## Defaults Applied
- Tool registered only on side-session runtime, not main-agent runtime, not pinned sessions.
- `submit_final_report` execute returns short ack so the model can wrap up.
- `partial` report.status maps to session.status = "completed".
- Cancelled overrides report.status.

## Verification Checklist
```bash
cd /Users/creatrip/Documents/picky/agentd
npm run build
npm test
```
Expected:
- All existing tests pass.
- ~10 new tests added under PR5 scope all pass.
- `rg -n "submit_final_report" agentd/src` → finds tool def + index.ts wiring + supervisor method.

## Worker Reporting Requirements
After implementation, worker MUST report:
- `git status --short` — confirm only PR5-scoped files touched.
- File-by-file change summary mapped back to tasks 1-5.
- Test counts (pass/fail) for `npm test`.
- Any deviation from the customToolsFactory pattern (e.g. fallback to module-level closure) with rationale.
- **Do not commit.**

## Estimated Effort
Medium-Low. New tool module (~70 LOC) + customToolsFactory plumbing (~10 LOC) + supervisor method (~30 LOC) + RuntimeEventHandler override (~10 LOC) + ~10 tests. Risk concentrated in the customToolsFactory wiring; if Pi SDK constrains tool registration per-session in unexpected ways, fall back to module-level closure with `currentActiveSessionId` tracker.

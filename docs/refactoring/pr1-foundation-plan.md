# PR1 — Foundation Plan (Side-Card Conversation Redesign)

**Status**: planning only — do NOT modify source code in this task.
**SoT spec**: `docs/refactoring/side-card-conversation-redesign.md` §2, §3.3, §6 Step 1.
**Context handoff**: `/tmp/picky-pr1-foundation-context.md`.
**Base**: `main` @ commit `23a6c65`.

## Goal
Add the schema / type / interface foundation for the conversation-card redesign without changing any business logic, event emission, or UI. After this PR all new RPC commands and events parse on both sides; runtime adapter exposes queue/mode getters; Swift mirrors all new types with default-tolerant decoding; existing UI is untouched and existing tests still pass.

## Intent Type
Build (schema + interface scaffolding only, no behavior).

## Scope
- **In** (PR1):
  - `agentd/src/protocol.ts` — 5 new schemas, `PickyAgentSessionSchema` extension, `clearQueue` command, 5 new events, `PROTOCOL_VERSION` bump.
  - `agentd/src/domain/log-prefixes.ts` (new) — shared 4-prefix constant module.
  - All existing `appendLog("steer: …")` / `"follow-up: …"` / `"main-agent handoff: …"` / `"extension ui answer: …"` writers + readers (TS + Swift) refactored to import the constant. **Literal output strings must not change** so existing tests keep passing.
  - `agentd/src/runtime/types.ts` — extend `RuntimeSessionHandle`.
  - `agentd/src/runtime/pi-sdk-runtime.ts` — delegate new members to `this.runtime.session`.
  - `agentd/src/runtime/mock-runtime.ts` — in-memory stub of new members.
  - `Picky/PickyAgentProtocol.swift` — Swift mirrors of all new types + bumped `pickyAgentProtocolVersion` + new `PickyEvent` cases + new `PickyCommandType` case + extended `PickyAgentSession` with explicit `init(from:)`.
  - `Picky/Domain/PickyLogPrefixes.swift` (new) — Swift mirror of constants.
  - All contract fixture JSONs in `contracts/protocol/*.json` — bump `protocolVersion` literal.
  - All test JSON literals that hardcode `"2026-05-01"` — bump.
  - New round-trip / decoding tests for new schemas, new envelope cases, runtime adapter delegation.
- **Out** (later PRs, do not start in PR1):
  - supervisor queue tracking, `queue_update` subscription, `sessionQueueUpdated` emit → PR2.
  - activity counter classifier, `sessionActivityUpdated` emit → PR3.
  - append-only journal, `session-message-builder`, message event emission, reducer wiring → PR4.
  - `submit_final_report` tool definition + injection + turn-end lifecycle → PR5.
  - `waiting_for_input` auto-cancel, pinned reattach, Picky-side `protocolVersion` mismatch relaunch behavior → PR6.
  - `clearQueue` RPC handler implementation in `server.ts` / supervisor (only the schema entry is added in PR1; the actual handler is part of PR2 along with queue tracking).
  - follow-up vs steer split inside `steerSideSession` → PR2.
  - Any `Picky/HUD/Conversation/*` SwiftUI work → Step 2.

- **Must Have**:
  - All five new Zod schemas exported with stable type aliases.
  - `PROTOCOL_VERSION` bumped to a new ISO-style date string and propagated to: `agentd/src/protocol.ts`, `Picky/PickyAgentProtocol.swift`, every fixture under `contracts/protocol/`, every inline JSON in `agentd/src/**/*.test.ts`, every inline JSON / `protocolVersion` literal under `PickyTests/**/*.swift`, and `agentd/src/__tests__/smoke.test.ts`.
  - `PickyAgentSessionSchema` defaults populate empty arrays / `"one-at-a-time"` / `{ edit:0, bash:0, thinking:0, other:0 }` so existing `sessionSnapshot` fixtures and old daemon snapshots parse cleanly.
  - Swift `PickyAgentSession` decodes legacy JSON (no new fields) with empty / default values.
  - `clearQueue` command parses on both sides; no handler logic added to `server.ts` yet (a stub that returns `error("not_implemented", commandId)` is acceptable to keep the discriminated-union switch exhaustive — see Task 4 acceptance check).
  - Existing `npm test` / `xcodebuild test` suites pass with zero behavior changes.
- **Must NOT Have**:
  - Any change to runtime event handling, supervisor patch flow, message journal, or activity counters.
  - Any deletion of `lastSummary` / `thinkingPreview` / `finalAnswer` / `tools` fields (preserved for PR4 message builder).
  - Any UI / SwiftUI changes beyond the protocol type file.
  - `popLatestQueueItem` / `removeQueueItem` RPCs (decision §7.13/§7.16 = B).
  - Capability-list mechanism (decision §7.17 = A).

## Context (Evidence)

- `agentd/src/protocol.ts:3` — `export const PROTOCOL_VERSION = "2026-05-01";`
- `agentd/src/protocol.ts:104-128` — `PickyAgentSessionSchema` definition (insertion target for new fields).
- `agentd/src/protocol.ts:148-167` — `CommandEnvelopeSchema` discriminated union (insert `clearQueue` entry here, alphabetical w/ existing entries is fine).
- `agentd/src/protocol.ts:171-185` — `EventEnvelopeSchema` (append five new entries before final `error`).
- `agentd/src/runtime/types.ts:30-49` — `RuntimeSessionHandle` interface (extend here).
- `agentd/src/runtime/pi-sdk-runtime.ts:99-104` — `PiSdkRuntimeSession` class declaration; `this.runtime.session` is the Pi SDK `AgentSession`. Pi SDK already exposes `clearQueue()`, `getSteeringMessages()`, `getFollowUpMessages()`, `steeringMode`, `followUpMode` (verified in `node_modules/.pnpm/@mariozechner+pi-coding-agent@0.71.0_*/dist/core/agent-session.d.ts:286,288,381,388,390`). PR1 just delegates.
- `agentd/src/runtime/mock-runtime.ts:25-58` — `MockRuntimeSession`; queue stub state and mode field need to be added here.
- `agentd/src/session-supervisor.ts:309,310,342-343,723,730,747,805,837,1063` — log-prefix writers and the `manual side agent: ...` / `pi-extension handoff pin:` adjacent strings (the latter two are NOT in scope; only the four canonical prefixes from §2.1 are extracted).
- `agentd/src/server.ts:282-287` — `isImportantSnapshotLog` reader that filters by prefix (must use the constants).
- `agentd/src/runtime/mock-runtime.ts:34` — `\`steer: ${text}\`` (literal log used in tests; keep literal output identical, just import the constant for the prefix portion).
- `agentd/src/artifact-store.ts:202` — `(?:^|\n)(?:follow-up:\s*)?Changed file:\s*…` regex; the `follow-up:` token here is NOT a log prefix but an embedded pattern in tool output. **Do not change this file** in PR1.
- `agentd/src/application/handoff-tool.ts:116` — `"picky_side_steer: steer …"` is documentation of a tool name, not the log prefix. **Do not change.**
- `Picky/PickyAgentProtocol.swift:10` — `let pickyAgentProtocolVersion = "2026-05-01"`.
- `Picky/PickyAgentProtocol.swift:53-71` — `PickyCommandType` enum (add `clearQueue`).
- `Picky/PickyAgentProtocol.swift:73-99` — `PickyEventEnvelope` w/ private `init(from:)` calling `PickyEvent(type:decoder:)`.
- `Picky/PickyAgentProtocol.swift:101-167` — `PickyEvent` enum + `CodingKeys` + dispatch switch (add five new cases + new keys: `messageId`, `seq`, `steering`, `followUp`, `steeringMode`, `followUpMode`, `activitySummary`, `kind`).
- `Picky/PickyAgentProtocol.swift:208-225` — `PickyAgentSession` struct (synthesized Codable today; rewrite with explicit `init(from:)` to add `decodeIfPresent` + defaults for new fields).
- `Picky/PickySessionViewModel.swift:933,942` — Swift readers using the four log prefixes (replace with `PickyLogPrefixes.steer` etc.).
- `Picky/PickyAgentClient.swift` — does not currently inspect `protocolVersion` for mismatch; PR1 leaves the field untouched (mismatch handling is PR6, decision §7.17 = A).
- `contracts/protocol/*.json` (27 files) — every fixture has `"protocolVersion":"2026-05-01"`. Bump them all.
- `agentd/src/__tests__/smoke.test.ts:6` — `expect(PROTOCOL_VERSION).toBe("2026-05-01")` — bump.
- `agentd/src/protocol.test.ts:35,54` — inline `protocolVersion: "2026-05-01"` — bump.
- `PickyTests/PickyAgentClientTests.swift:42,120,133` and `PickyTests/PickySettingsPolishTests.swift:314` and `PickyTests/ProtocolContractTests.swift:30,31,47,48,85,86,…` — inline JSON strings — bump (`grep -RIl "2026-05-01" PickyTests` to enumerate completely).
- Pi SDK queue API signature (verified in `agent-session.d.ts:381-390`):
  ```ts
  clearQueue(): { steering: string[]; followUp: string[] };       // sync
  get steeringMode(): "all" | "one-at-a-time";
  get followUpMode(): "all" | "one-at-a-time";
  getSteeringMessages(): readonly string[];
  getFollowUpMessages(): readonly string[];
  ```
  These match the PR1 interface exactly.

## Assumptions
- Bumped value: `PROTOCOL_VERSION = "2026-05-05"`. (Worker may pick a different ISO date if `2026-05-05` collides with anything else, but must keep the value identical across `protocol.ts`, Swift, contract fixtures, and test fixtures.)
- `clearQueue` command discriminator literal is `"clearQueue"` (camelCase, matches existing convention `routeTask`, `createTask`, `setNotifyMainOnCompletion`).
- New events are emitted with the same `EventBaseSchema` shape (`id`, `protocolVersion`, `timestamp`); per-message `seq` is a session-monotonic integer added at PR4 emission time. PR1 only adds the schema field, no emission.
- `PickyAgentSession` Swift struct switches from synthesized Codable to explicit `init(from:)`; `Equatable` synthesis still works because all members remain `Equatable`. (If property-list ordering matters anywhere, `encode(to:)` should also be explicit, mirroring `init`.)
- `clearQueue` command currently lands in `server.ts` switch with no handler — to keep the discriminated-union exhaustive **without** implementing PR2 logic, the handler should respond with `error` envelope `{ code: "notImplemented", message: "clearQueue handled in PR2" }` and the regression test must assert that exact behavior. (Decision: this is the minimum to compile; the PR1 commit message must call this out explicitly.)
- Pi SDK `getSteeringMessages()` / `getFollowUpMessages()` return type `readonly string[]` is structurally compatible with our interface declaration; no `as` casts needed.

## Execution Strategy (Parallel Waves)

- **Wave 1 (independent foundation, can run in parallel)**:
  - W1-A: log-prefix constant modules (TS + Swift) + replace literals.
  - W1-B: agentd protocol schema additions (no command/event entries yet — just the 5 new schemas + session field extension).
- **Wave 2 (depends on Wave 1-B)**:
  - W2-A: Add `clearQueue` command + 5 new events to discriminated unions; bump `PROTOCOL_VERSION`; update all fixture / inline JSON literals.
  - W2-B: `RuntimeSessionHandle` extension + `PiSdkRuntimeSession` delegation + `MockRuntime` stub.
  - W2-C: `server.ts` exhaustive-switch stub for `clearQueue` returning `notImplemented` error.
- **Wave 3 (depends on Wave 2-A)**:
  - W3-A: Swift mirror types + explicit `init(from:)` + `PickyEvent` cases + `PickyCommandType` case + bumped version constant + extra `CodingKeys`.
- **Wave 4 (depends on all above)**:
  - W4-A: New / updated unit tests (TS + Swift).
  - W4-B: Run full `npm test`, `npm run build`, `xcodebuild build`, `xcodebuild test`. Fix only fixture / decoding issues; no behavioral fixes (those would be out of scope).

## Task Breakdown

### 1. Shared log-prefix constants — Complexity: Low
- **What**: Extract the four canonical log prefix strings into shared modules so PR4's message builder can match without duplicating literals. Output strings remain byte-identical.
- **Where**:
  - New: `agentd/src/domain/log-prefixes.ts` — exports `STEER_PREFIX = "steer: "`, `FOLLOWUP_PREFIX = "follow-up: "`, `HANDOFF_PREFIX = "main-agent handoff: "`, `EXTENSION_ANSWER_PREFIX = "extension ui answer: "`.
  - New: `Picky/Domain/PickyLogPrefixes.swift` — Swift `enum PickyLogPrefixes { static let steer = "steer: "; … }`. Place file under `Picky/Domain/` (new directory; ensure it joins the `Picky` Xcode target — confirm via `Picky.xcodeproj/project.pbxproj` after `xcodebuild build`).
  - Edit: `agentd/src/session-supervisor.ts:309,310,730,805,837` — replace literal prefixes with constants. Lines 342-343 (`"manual side agent: ..."`, `"manual side agent cwd:"`) and 309-310's `main-agent handoff cwd:` are NOT in the four-prefix scope; leave untouched.
  - Edit: `agentd/src/server.ts:283-286` — replace four `trimmed.startsWith("…: ")` calls with the constant references.
  - Edit: `agentd/src/runtime/mock-runtime.ts:34` — replace `\`steer: ${text}\`` with `\`${STEER_PREFIX}${text}\``.
  - Edit: `Picky/PickySessionViewModel.swift:933,942` — replace inline prefix literals with `PickyLogPrefixes.handoff`, `[PickyLogPrefixes.steer, .followUp, .handoff, .extensionAnswer]`.
- **Depends on**: none.
- **Blocks**: PR4 (message builder will reuse the same constants).
- **Risks**: A typo in any constant changes existing log output and breaks downstream regex / tests. Mitigation: assert constants equal the legacy literals in a one-line test (`expect(STEER_PREFIX).toBe("steer: ")`).
- **Acceptance checks**:
  - `cd agentd && rg -n "\"steer: \"|\"follow-up: \"|\"main-agent handoff: \"|\"extension ui answer: \"" src --type ts` → only matches inside `domain/log-prefixes.ts` and existing `*.test.ts` files (test fixtures keep literals).
  - `rg -n "\"steer: \"|\"follow-up: \"|\"main-agent handoff: \"|\"extension ui answer: \"" Picky --type swift` → only matches inside `Domain/PickyLogPrefixes.swift`.
  - `cd agentd && npm test` → all green.
  - `xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test` → all green.

### 2. agentd protocol schemas (5 new + session extension) — Complexity: Medium
- **What**: Add the five new Zod schemas verbatim from spec §2.1 + extend `PickyAgentSessionSchema` per §2.2 with `.default(...)` on every new field. Do NOT add command/event union entries yet (Task 4).
- **Where**: `agentd/src/protocol.ts` — insert new schemas immediately after `PickyExtensionUiRequestSchema` (line ~108) and before `PickyAgentSessionSchema` (line ~108-128). Add fields to `PickyAgentSessionSchema`. Re-export every schema and `type ` alias.
- **Depends on**: none.
- **Blocks**: Task 4 (commands/events reference these), Task 6 (Swift mirror), Task 7 (tests).
- **Risks**:
  - `default(...)` on `messages: z.array(...)` is fine, but Zod `.default` makes the parsed value required — confirm `z.infer<typeof PickyAgentSessionSchema>` does not now require these fields at construction sites. Mitigation: grep all callers (`rg -n "PickyAgentSessionSchema|PickyAgentSession\b" agentd/src`) and confirm they construct sessions either via `parse()` (defaults applied) or by passing literals — for literal sites, add the new fields explicitly with empty defaults.
  - `PickyFinalReportSchema.artifacts` is `.default([])` per spec, but inside the schema declaration the `artifacts` array is also `.default([])` — keep the spec exactly as-is.
- **Acceptance checks**:
  - `cd agentd && npm run build` → no TS errors.
  - `cd agentd && npx vitest run src/protocol.test.ts` → existing fixture parses (Task 4 hasn't changed `protocolVersion` yet, so the existing fixtures still parse against the old literal — Task 4 does the bump).
  - `node -e "const {PickyAgentSessionSchema}=require('./agentd/dist/protocol.js'); console.log(PickyAgentSessionSchema.parse({id:'x',title:'t',status:'running',createdAt:'2026-05-01T00:00:00.000Z',updatedAt:'2026-05-01T00:00:00.000Z',logs:[],tools:[],artifacts:[],changedFiles:[]}).queuedSteers)"` → `[]` (default applied).

### 3. Runtime adapter extensions — Complexity: Low
- **What**: Add new methods + readonly modes to `RuntimeSessionHandle`; delegate from `PiSdkRuntimeSession`; stub in `MockRuntime`.
- **Where**:
  - `agentd/src/runtime/types.ts` — interface extension. Use `PickyQueueMode` from `../protocol.js` (do not re-define `"one-at-a-time" | "all"` here).
  - `agentd/src/runtime/pi-sdk-runtime.ts` — new methods inside `class PiSdkRuntimeSession`:
    ```ts
    clearQueue(): { steering: string[]; followUp: string[] } {
      return this.runtime.session.clearQueue();
    }
    getSteeringMessages(): readonly string[] { return this.runtime.session.getSteeringMessages(); }
    getFollowUpMessages(): readonly string[] { return this.runtime.session.getFollowUpMessages(); }
    get steeringMode(): PickyQueueMode { return this.runtime.session.steeringMode; }
    get followUpMode(): PickyQueueMode { return this.runtime.session.followUpMode; }
    ```
    Place after `listSlashCommands` (line ~177) for proximity with other delegation methods.
  - `agentd/src/runtime/mock-runtime.ts` — add private fields:
    ```ts
    private steering: string[] = [];
    private followUp: string[] = [];
    readonly steeringMode: PickyQueueMode = "one-at-a-time";
    readonly followUpMode: PickyQueueMode = "one-at-a-time";
    clearQueue() { const r = { steering: [...this.steering], followUp: [...this.followUp] }; this.steering = []; this.followUp = []; return r; }
    getSteeringMessages() { return this.steering; }
    getFollowUpMessages() { return this.followUp; }
    ```
- **Depends on**: Task 2 (imports `PickyQueueMode`).
- **Blocks**: PR2 (supervisor will call these).
- **Risks**: Pi SDK return type `readonly string[]` vs our declared `readonly string[]` — confirm structural match; if TS complains use the same type literal. Pi SDK signature already uses `readonly string[]`.
- **Acceptance checks**:
  - `cd agentd && npm run build` → green.
  - `cd agentd && npx vitest run src/runtime/pi-sdk-runtime.test.ts` → unchanged passes.

### 4. Command + event discriminated-union additions and PROTOCOL_VERSION bump — Complexity: Medium
- **What**: (a) Add `clearQueue` command entry. (b) Add five event entries with `seq: z.number().int()` where required. (c) Bump `PROTOCOL_VERSION` to `"2026-05-05"` and propagate to Swift + every fixture / inline literal. (d) Add a stub branch in `server.ts` command switch returning `error` envelope `{ code: "notImplemented", message: "clearQueue handled in PR2" }` so the union remains exhaustive.
- **Where**:
  - `agentd/src/protocol.ts:3` → `export const PROTOCOL_VERSION = "2026-05-05";`
  - `agentd/src/protocol.ts` `CommandEnvelopeSchema` → append `CommandBaseSchema.extend({ type: z.literal("clearQueue"), sessionId: z.string(), kind: z.enum(["steering", "followUp", "all"]) })`.
  - `agentd/src/protocol.ts` `EventEnvelopeSchema` → append five entries before the final `"error"` entry, exactly per spec §2.4 (note `sessionMessageRemoved` has only `messageId` payload + `seq`; `sessionQueueUpdated` has optional `steeringMode` / `followUpMode`).
  - `agentd/src/server.ts` — locate the existing `case "..."` switch over command types (search `parseCommand` or where each `command.type` is dispatched). Add `case "clearQueue": send(makeError(commandId, "notImplemented", "clearQueue handled in PR2")); return;` (use existing error helper / shape from neighboring branches — `error` event already exists in `EventEnvelopeSchema`).
  - `Picky/PickyAgentProtocol.swift:10` → `let pickyAgentProtocolVersion = "2026-05-05"`.
  - `contracts/protocol/*.json` → 27 files, replace `"protocolVersion": "2026-05-01"` with `"protocolVersion": "2026-05-05"`. Use `sed -i '' 's/"protocolVersion": "2026-05-01"/"protocolVersion": "2026-05-05"/' contracts/protocol/*.json` then verify with `rg -l "2026-05-01" contracts/protocol` → empty.
  - `agentd/src/__tests__/smoke.test.ts:6` → `expect(PROTOCOL_VERSION).toBe("2026-05-05")`.
  - `agentd/src/protocol.test.ts:35,54` → inline `"2026-05-01"` → `"2026-05-05"`.
  - `agentd/src/server.test.ts` and other test files: `rg -l "2026-05-01" agentd/src` → bump every match. Note `timestamp` values that happen to start with `"2026-05-01T..."` are ISO timestamps, not version literals — only replace `protocolVersion: "2026-05-01"` and `"supportedProtocolVersions":["2026-05-01"]`. Keep timestamps untouched.
  - `PickyTests/**/*.swift` — `rg -l "2026-05-01" PickyTests` → bump only `protocolVersion` and `supportedProtocolVersions` literals; preserve timestamp date strings (decoded as `Date`, not version-checked).
- **Depends on**: Task 2.
- **Blocks**: Task 6 (Swift mirror needs the discriminator names).
- **Risks**:
  - Forgetting one fixture or inline JSON → `protocol.test.ts` fixture loop fails. Mitigation: run `rg -l '"protocolVersion": "2026-05-01"' contracts/ agentd/ PickyTests/` after edit; expect zero output.
  - The fixture-loop test in `protocol.test.ts` parses every `contracts/protocol/*.json` against the bumped schema; `z.literal(PROTOCOL_VERSION)` will reject any missed file.
  - Swift `ProtocolContractTests.decodesEveryProtocolFixture()` (PickyTests/ProtocolContractTests.swift:8) iterates every fixture; `protocolVersion` is decoded as `String` so version check is just a string compare done implicitly through round-trip — the Swift test is more lenient. Still, keep them consistent for clarity.
  - `commandId` field shape for the `notImplemented` error: existing `EventBaseSchema.extend({ type: z.literal("error"), code, message, commandId? })` — pass the inbound `command.id`. Worker should locate the existing error helper (`rg -n "type: \"error\"" agentd/src/server.ts`) and reuse it.
- **Acceptance checks**:
  - `cd agentd && npm test` → all suites green.
  - `cd agentd && rg -l '"protocolVersion": "2026-05-01"' .` → empty.
  - `rg -l 'protocolVersion.*"2026-05-01"' Picky PickyTests contracts` → empty.
  - `cd agentd && npx tsc --noEmit` → 0 errors.
  - Manually parse a `clearQueue` command (vitest):
    ```ts
    CommandEnvelopeSchema.parse({ id: "x", protocolVersion: "2026-05-05", type: "clearQueue", sessionId: "s", kind: "steering" });
    ```
    Expected: succeeds.

### 5. Test fixtures for new envelope shapes — Complexity: Low
- **What**: Add fixture JSONs and tests so the new union members are exercised end-to-end.
- **Where**:
  - New: `contracts/protocol/clear-queue.request.json` (one per `kind` is overkill — one fixture with `"kind": "all"` is sufficient for round-trip check; spec consistency is verified inside `agentd/src/protocol.test.ts` via Zod parse).
  - New: `contracts/protocol/session-message-appended.event.json`, `session-message-replaced.event.json`, `session-message-removed.event.json`, `session-queue-updated.event.json`, `session-activity-updated.event.json`.
    - `sessionMessageAppended` fixture: include a fully-populated `agent_text` message with `id`, `kind`, `createdAt`, `text`, `seq`.
    - `sessionMessageReplaced` fixture: same shape with `messageId` + `message` + `seq`.
    - `sessionMessageRemoved` fixture: `{ sessionId, messageId, seq }`.
    - `sessionQueueUpdated` fixture: include both `steering` and `followUp` arrays + `steeringMode: "one-at-a-time"` to exercise optional-mode branch.
    - `sessionActivityUpdated` fixture: full `activitySummary` payload.
- **Depends on**: Task 4.
- **Blocks**: Task 7 Swift contract test (also iterates all fixtures).
- **Risks**: Fixture timestamps must satisfy `z.string().datetime({ offset: true })` — use `"2026-05-05T00:00:00.000Z"`.
- **Acceptance checks**:
  - `cd agentd && npx vitest run src/protocol.test.ts` → all 33+ fixture iterations pass.
  - `xcodebuild test -only-testing:PickyTests/ProtocolContractTests` → `decodesEveryProtocolFixture` passes.

### 6. Swift mirror types and decoding — Complexity: Medium
- **What**: Mirror all new types in `Picky/PickyAgentProtocol.swift`, extend `PickyAgentSession` with explicit `init(from:)` (and matching `encode(to:)` if encoder usage exists; check `JSONEncoder.pickyAgentProtocolEncoder()` callsites — Codable conformance must be symmetric), add new `PickyEvent` cases + dispatch + new `CodingKeys`, add `PickyCommandType.clearQueue` + envelope encoding for the `kind` field.
- **Where**: `Picky/PickyAgentProtocol.swift`.
  - **New types** (add after `PickyExtensionUiQuestionOption`):
    ```swift
    enum PickyQueueMode: String, Codable, Equatable { case oneAtATime = "one-at-a-time", all }
    struct PickyQueueItem: Codable, Equatable { let text: String; let enqueuedAt: Date }
    struct PickyActivitySummary: Codable, Equatable { var edit: Int; var bash: Int; var thinking: Int; var other: Int; static let zero = PickyActivitySummary(edit: 0, bash: 0, thinking: 0, other: 0) }
    struct PickyFinalReport: Codable, Equatable {
        let summary: String; let body: String
        let status: Status; let artifacts: [Artifact]
        enum Status: String, Codable, Equatable { case success, partial, blocked }
        struct Artifact: Codable, Equatable { let kind: String; let title: String; let url: URL? }
        // explicit init(from:) to default `artifacts` to []
    }
    enum PickyMessageOrigin: String, Codable, Equatable { case user, mainAgent = "main_agent", piExtension = "pi_extension" }
    enum PickySessionMessageKind: String, Codable, Equatable {
        case userText = "user_text", agentText = "agent_text", agentThinking = "agent_thinking",
             agentQuestion = "agent_question", agentReport = "agent_report",
             agentError = "agent_error", system
    }
    struct PickySessionMessage: Codable, Equatable, Identifiable {
        let id: String; let kind: PickySessionMessageKind; let createdAt: Date
        let originatedBy: PickyMessageOrigin?
        let text: String?; let question: PickyExtensionUiRequest?
        let cancelledAt: Date?; let report: PickyFinalReport?
        let errorContext: String?; let errorMessage: String?
    }
    ```
  - **Extend `PickyAgentSession`**: add fields with explicit defaults (`messages: [PickySessionMessage] = []`, `queuedSteers: [PickyQueueItem] = []`, `queuedFollowUps: [PickyQueueItem] = []`, `steeringMode: PickyQueueMode = .oneAtATime`, `followUpMode: PickyQueueMode = .oneAtATime`, `activitySummary: PickyActivitySummary = .zero`, `finalReport: PickyFinalReport? = nil`). Replace synthesized Codable with explicit `init(from:)` using `decodeIfPresent` and Swift defaults; also write explicit `encode(to:)` that emits these fields (preserve current encoding for existing fields exactly — write the encoder by enumerating every property key).
    - Verify after the rewrite: `grep -n "PickyAgentSession(" Picky` should not break — every callsite must still type-check (the new properties have defaults, so initializer ordering matters; use `var` with defaults so memberwise init still works in tests / fixture builders).
  - **Extend `PickyCommandType`**: append `case clearQueue`. Add `kind: PickyQueueClearKind?` to `PickyCommandEnvelope` + initializer parameter; `PickyQueueClearKind: String, Codable { case steering, followUp, all }`.
  - **Extend `PickyEvent` enum**: add five cases:
    ```swift
    case sessionMessageAppended(sessionId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageReplaced(sessionId: String, messageId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageRemoved(sessionId: String, messageId: String, seq: Int)
    case sessionQueueUpdated(sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int)
    case sessionActivityUpdated(sessionId: String, activitySummary: PickyActivitySummary, seq: Int)
    ```
  - **Extend `PickyEvent.CodingKeys`**: add `messageId, seq, steering, followUp, steeringMode, followUpMode, activitySummary, kind` (the latter only used for command, but keeping all in one enum is fine; CodingKeys is event-side only — `kind` is used in `PickyCommandEnvelope`'s memberwise Codable, which already has its own synthesized Codable spanning all optional fields).
  - **Extend `PickyEvent.init(type:decoder:)`** with five `case "sessionMessageAppended": …` branches mirroring the existing `c.decode(...)` pattern. For optional `steeringMode` / `followUpMode`, use `decodeIfPresent`.
- **Depends on**: Task 4.
- **Blocks**: Task 7.
- **Risks**:
  - Switching `PickyAgentSession` from synthesized to explicit Codable can change encoded output ordering. Mitigation: only encoding sites we control are tests; verify `xcodebuild test` covers any round-trip encoder path.
  - `PickyAgentSession` is referenced via memberwise init in tests (`PickySessionViewModelTests` etc.) — adding stored properties with defaults keeps memberwise init compatible.
  - `kind` codingKey collision: `PickyExtensionUiQuestionType` has its own `case kind`? Re-check — current `PickyEvent.CodingKeys` already has `path` and `text`, and adding `kind` as a CodingKey is fine because it lives inside `PickyEvent.CodingKeys` namespace.
- **Acceptance checks**:
  - `xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build` → green.
  - `xcodebuild ... test` → all green.
  - Manually decode a `sessionMessageAppended` event JSON via `JSONDecoder.pickyAgentProtocolDecoder()` in a new test (Task 7) → expected equality with a hand-built struct.
  - Old `sessionSnapshot` JSON without new fields decodes — verify in Task 7 backwards-compat test.

### 7. Test additions (TS + Swift) — Complexity: Medium
- **What**: Add narrowly-scoped tests to lock the foundation in.
- **Where**:
  - `agentd/src/protocol.test.ts` (extend): three new `it(...)` cases:
    1. `clearQueue` command parses with each `kind` value (`"steering"`, `"followUp"`, `"all"`).
    2. `sessionMessageAppended` event parses with full message payload incl. `originatedBy`.
    3. `sessionQueueUpdated` event parses with mode fields omitted (mode-unchanged emission case) and with both modes present.
  - New: `agentd/src/runtime/mock-runtime.test.ts` — lightweight test that asserts `clearQueue` returns drained arrays, getters mirror queue state, and `steeringMode` / `followUpMode` default to `"one-at-a-time"`. Pattern mirrors existing `runtime/pi-sdk-runtime.test.ts:144` style.
  - `PickyTests/ProtocolContractTests.swift` (extend):
    1. `decodesSessionWithoutNewFields` — feed an inline JSON with only legacy `PickyAgentSession` fields; assert `messages.isEmpty`, `steeringMode == .oneAtATime`, `activitySummary == .zero`, `finalReport == nil`.
    2. `decodesSessionMessageAppendedEvent` — round-trip a `sessionMessageAppended` event; assert `event == .sessionMessageAppended(...)`.
    3. `decodesSessionQueueUpdatedWithoutModes` — assert `steeringMode == nil`, `followUpMode == nil`.
    4. `encodesClearQueueCommand` — encode a `PickyCommandEnvelope(type: .clearQueue, sessionId: "s", kind: .steering)` and round-trip.
- **Depends on**: Tasks 4, 5, 6.
- **Blocks**: PR1 ship.
- **Risks**: TS / Swift round-trip edge cases for `Date` decoding when fixtures use `Z` vs offset.
- **Acceptance checks**:
  - `cd agentd && npx vitest run` → green.
  - `xcodebuild ... test -only-testing:PickyTests/ProtocolContractTests` → all four new tests green.
  - `xcodebuild ... test` (full suite) → green.

## Test & QA Scenarios

- [x] **Happy: existing daemon snapshot decodes** — feed a real daemon `sessionSnapshot` JSON captured today (legacy shape, no new fields) into bumped `PickyAgentSessionSchema.parse(...)` and Swift decoder. Expected: parses, defaults applied.
- [x] **Happy: `clearQueue` command round-trips** TS+Swift with `kind ∈ {steering, followUp, all}`.
- [x] **Happy: 5 new event fixtures parse** in both TS Zod and Swift `PickyEventEnvelope`.
- [x] **Edge: `sessionQueueUpdated` without modes** — both runtimes accept; Swift maps to `nil`.
- [x] **Edge: stale `protocolVersion` rejected** — TS `CommandEnvelopeSchema.parse({...protocolVersion:"2026-05-01"...})` throws `Invalid literal value`.
- [x] **Edge: `clearQueue` server stub** — sending `clearQueue` to daemon yields `error` envelope `{ code: "notImplemented", commandId }` (regression-asserted via `agentd/src/server.test.ts` new case so PR2 implementer knows to remove the stub).
- [x] **Regression: existing test suites** — `npm test` and `xcodebuild test` pass with zero behavior changes.
- [x] **Regression: log prefix output unchanged** — `agentd/src/session-supervisor.test.ts:201,272,309,326,401,422,...` continues to match literal `"steer: ..."` / `"main-agent handoff: ..."` strings without modification.
- [x] **Failure path: missing fixture bump** — running `npm test` after a forgotten fixture will fail `protocol contract fixtures` test loop with `Invalid literal value`. Use as a self-checking guard.

## Edge Cases & Risks
- **Fixture sprawl** — 27 contract fixtures + many inline JSONs need version bumps. Risk: easy to miss one. **Mitigation**: post-edit grep `rg -l '"protocolVersion": "2026-05-01"'` returns empty across `contracts/`, `agentd/`, `Picky/`, `PickyTests/`.
- **Synthesized Codable swap on `PickyAgentSession`** — explicit `init(from:)` and `encode(to:)` must list every property in CodingKeys. Risk: forgetting an existing property silently drops it on decode. **Mitigation**: verify with one decode-encode-decode round-trip test using a snapshot fixture; assert structural equality.
- **Pi SDK return type covariance** — `readonly string[]` vs `string[]` — TS structural typing handles this; just avoid declaring `string[]` in our interface.
- **`MockRuntime` getters using `readonly` field** — TS class field `readonly steeringMode: PickyQueueMode = "one-at-a-time"` works; tests in PR2 may want to mutate it, but that's PR2 scope.
- **`error` envelope for `clearQueue` stub** — must reuse existing error shape; do NOT introduce a separate `notImplemented` event. Worker should `rg -n '"error"' agentd/src/server.ts` to find the existing helper.
- **Swift `PickyAgentSession` memberwise initializer compatibility** — adding stored properties with defaults preserves existing `PickyAgentSession(id:, title:, ...)` callers. **Mitigation**: search `rg -n "PickyAgentSession(" Picky PickyTests` and confirm all callsites either use synthesized memberwise init (still fine because new properties have defaults) or explicit decoder paths (covered).
- **`PickyEvent.unknown(type:)` fallthrough** — existing tests expect unknown future event types to map to `.unknown`. New cases must be added BEFORE the `default:` branch in the switch.

## Decisions Needed
1. Worker should confirm the bumped version string (`"2026-05-05"` is the assumption; if the worker discovers a calendar collision or a project convention reason to differ, surface that before editing 27+ files).
2. Whether the `clearQueue` server stub should respond with `error` envelope or simply log + drop. The plan recommends `error { code: "notImplemented", commandId }` so PR2 has a clear regression to flip; the alternative (silent drop) hides the wiring gap. **Recommendation: error envelope.**

## Defaults Applied
- `PROTOCOL_VERSION = "2026-05-05"` (`+4` days from current; ISO-style consistent with existing convention).
- `clearQueue` command stub returns `error` envelope `{ code: "notImplemented", message: "clearQueue handled in PR2", commandId }`.
- New file location for shared TS log-prefix module: `agentd/src/domain/log-prefixes.ts` (matches existing `agentd/src/domain/` directory used for `pi-event-normalizer.ts`).
- New file location for Swift mirror: `Picky/Domain/PickyLogPrefixes.swift` (new `Domain/` directory; ensure it joins the `Picky` Xcode target — verify with `xcodebuild build`).
- Swift `PickyAgentSession` keeps memberwise initializer auto-synthesis by giving every new stored property a default value.

## Verification Checklist (run in order)
```bash
# 1. Static checks
cd /Users/creatrip/Documents/picky/agentd && npm run build
cd /Users/creatrip/Documents/picky/agentd && npx tsc --noEmit

# 2. agentd unit tests
cd /Users/creatrip/Documents/picky/agentd && npm test

# 3. Swift build + tests
cd /Users/creatrip/Documents/picky
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test

# 4. Targeted regression (faster iteration):
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test \
  -only-testing:PickyTests/ProtocolContractTests \
  -only-testing:PickyTests/PickyAgentClientTests

# 5. Self-checks
cd /Users/creatrip/Documents/picky
rg -l '"protocolVersion": "2026-05-01"' contracts agentd Picky PickyTests   # expect empty
rg -n '"steer: "|"follow-up: "|"main-agent handoff: "|"extension ui answer: "' \
   agentd/src/session-supervisor.ts agentd/src/server.ts \
   Picky/PickySessionViewModel.swift                                        # expect 0 results (constants only)
```

## Worker Reporting Requirements (from context handoff)
After implementation, worker MUST report:
- `git status --short` — confirms only PR1-scoped files touched.
- File-by-file change summary mapped back to Tasks 1-7.
- Exact verifier-runnable commands (the block above).
- **Do not commit.** User reviews before commit.

## Estimated Total Effort
Medium. Largest line counts are: (a) Swift `PickyAgentProtocol.swift` rewrite (~150 lines added including explicit Codable), (b) 27 fixture file edits (mechanical), (c) 5 new fixture files. No business logic, so verifier round-trip is fast; risk concentrated in fixture-bump completeness and Swift Codable rewrite symmetry.

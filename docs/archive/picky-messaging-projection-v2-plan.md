# Picky Messaging & Projection v2 — Dynamic Implementation Workflow (Revised)

Status: implemented; retained as the completed implementation workflow (2026-08-30)
Prerequisite merged: `964ba658 fix: bound app session snapshot frames`

This document records the approved implementation scope, sequencing, validation gates, and dynamic subagent orchestration used to ship Projection v2. It is no longer the source of truth for current runtime behavior; use `ARCHITECTURE.md`, the projection v2 application modules, protocol schemas, and current tests.

## 1. Locked objective and boundaries

Objective:
- live terminal transition: durable save 1, revision +1, app frame 1.
- bootstrap/live session projection cost becomes O(changed session/field), not O(all sessions/full transcript).
- message-only mutation wakes only message consumers.

Explicit non-goals:
- SessionStore JSON persistence byte cost is not O(delta); full-file atomic rename remains acceptable.
- P0 bounded snapshot implementation is not rewritten. v2 extends its app-capability/frame-budget helpers.
- no running-app restart, package/release/push, real Application Support/`~/.pi`/port tests.

Hard invariants:
- one mutable owner per persisted and transient state cluster.
- socket receives exactly one projection dialect: v1(seq) or v2(revision), never both.
- protocol version bump, Swift capability registration, server dialect lock, and v2 emission are one atomic cutover packet.
- P0 lightweight snapshot + N hydration events is the new v1 baseline.
- snapshot/recovery omissions clear or mark unavailable; they never silently retain stale data.
- persisted state + in-memory journal/drafts + projection publication are commit-ordered; a failed durable save changes none of them.
- completion notification is a post-commit best-effort/idempotent side effect. Durable exactly-once notification/outbox is explicitly outside this performance refactor.

## 2. Historical verified baseline before Projection v2

- P0 commit changes only `agentd/src/server.ts`, `agentd/src/server.test.ts`.
- P0 app path: one lightweight `sessionSnapshot`, then N bounded `sessionUpdated` frames.
- P0 server test: 77/77 pass.
- agentd typecheck: pass.
- architecture guard currently has exactly:
  - error: `Picky/CompanionManager.swift` 2680 > ratchet 2671 (unrelated)
  - error: `agentd/src/server.ts` 1586 > 1500 (P0 growth)
  - 4 existing warnings.
- Current Swift hydration path runs broad `upsert()` for every `sessionUpdated`; active/archived hydration can cause roughly 6–7 global ObservableObject publishes each plus sorting/selection/dock work. Exact count must be captured, not assumed.

## 3. Dynamic orchestration

Pattern per implementation packet:
1. `worker --main`: RED test → minimal implementation → targeted GREEN. No commit/push/restart.
2. `verifier --main`: inspect diff + run exact commands.
3. `reviewer --main`: correctness/regression/maintainability.
4. P0/P1 → same worker fixes only findings → verifier → reviewer.

Loop policy:
- max 2 repair cycles is escalation timing, not acceptance. Any remaining P0/P1 continues to block.
- if a unit cannot converge in one repair, split it before cycle 2.

Parallelism:
- code-changing packets are sequential.
- read-only research/challenge may fan out.
- no two workers touch `session-supervisor.ts`, `server.ts`, `PickyAgentProtocol.swift`, or `PickySessionViewModel.swift` concurrently.

Human gates:
- H1 after v1 quick wins: priority/scope review only; it cannot cancel structural work unless *all* bootstrap, terminal, steady-state, and observation budgets pass.
- H2 before v2 socket cutover/protocol bump.
- H3 before any live running-app profile/restart.

## 4. Test Plan Card

Contracts:
- P0 bootstrap remains frame-bounded and ordered.
- terminal finalization is all-or-nothing for persisted state, transient in-memory synchronization, and projection publication; completion notification is ordered last as a post-commit best-effort/idempotent side effect.
- stale/duplicate/gap/epoch recovery is per session.
- v1 sockets retain seq behavior; v2 sockets use revision only.
- session field ownership is mechanically exhaustive.
- registry/store is sole mutable owner after storage cutover.

Test layers:
- pure: patch equality, ownership parity, revision cursor, terminal planner.
- agentd integration: save failure/concurrency, server dialect routing, P0 bootstrap.
- cross-language: DTO/mutations/recovery/capability fixtures.
- Swift orchestration: storage/coordinator/recovery.
- Observation: dependency isolation with positive controls.
- mounted host/perf: supplementary evidence only; never sole CI oracle.

# 5. Work units

Each numbered subtask is one narrow RED/GREEN checkpoint. A worker prompt groups at most 3 adjacent subtasks.

---

## W0 — Rebase guards and baseline P0 bootstrap + terminal

### W0.1 Extract P0 frame policy without behavior change
Files:
- Create: `agentd/src/application/app-session-snapshot-policy.ts`
- Create: `agentd/src/application/app-session-snapshot-policy.test.ts`
- Modify: `agentd/src/server.ts`

Steps:
1. Move byte-budget constants and pure compact/minimal/bounded hydration functions out of `server.ts`.
2. RED parity tests use P0 fixtures: normal, aggregate-large, single-message-large, metadata-too-large.
3. Keep event ordering/send ownership in `AgentdServer`.
4. Require `server.ts <= 1500` or pin a temporary no-growth ratchet only if extraction cannot achieve it; do not raise global threshold.

Verify:
```bash
pnpm --dir agentd exec vitest run src/application/app-session-snapshot-policy.test.ts src/server.test.ts
pnpm --dir agentd run typecheck
wc -l agentd/src/server.ts
```

### W0.2 Add scoped architecture-guard self-test mode
File: `scripts/check-architecture-rules.js`

Steps:
1. Add blocked/allowed fixtures for observation/store rules.
2. Add a scoped `--self-test=session-projection` mode that runs only new fixtures/checkers.
3. Normal guard diagnostics must not grow beyond the recorded baseline; unrelated Companion error remains reported.

Verify:
```bash
node scripts/check-architecture-rules.js --self-test=session-projection
node scripts/check-architecture-rules.js 2>&1 | tee /tmp/picky-arch-baseline.txt
```
Expected normal baseline after W0.1: only existing unrelated diagnostics; no new errors.

### W0.3 Capture P0 server bootstrap budgets
File: `agentd/src/server.test.ts` or new `agentd/src/application/app-session-bootstrap-replay.test.ts`

RED/baseline cases:
1. registered app + 94 sessions.
2. one shell snapshot before all hydrations.
3. record exact frame count, total/max encoded bytes, omitted-field counts.
4. delete/reconnect uses same bounded route.
5. CLI/unregistered client stays v1 legacy.

Verify:
```bash
pnpm --dir agentd exec vitest run src/server.test.ts
```

### W0.4 Capture Swift P0 hydration fan-out
Create: `PickyTests/PickySessionBootstrapReplayBudgetTests.swift`

Steps:
1. Synthesize 94-session lightweight snapshot + 94 full `sessionUpdated` events.
2. Subscribe to façade `objectWillChange`; record exact baseline count.
3. Inject notification spy; historical terminal hydration must deliver 0 user notifications/flashes/unread transitions.
4. Assert selection/archive/order/session count parity.
5. Include oversized `messageJournalAvailable=false` hydration and assert unavailable/empty semantics are explicit.

Verify:
```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickySessionBootstrapReplayBudgetTests
```

### W0.5 Capture terminal baseline
Create:
- `contracts/perf/terminal-completion.runtime.json`
- `agentd/src/application/terminal-completion-replay.test.ts`
- `PickyTests/PickyTerminalCompletionReplayBudgetTests.swift`

Steps:
1. Capture artifact/no-artifact event counts and bytes from ManualRuntime.
2. Swift replay records global publish count and final projection parity.
3. Do not assert wall-clock or OSLog delivery.

Verify:
```bash
pnpm --dir agentd exec vitest run src/application/terminal-completion-replay.test.ts
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickyTerminalCompletionReplayBudgetTests
```

W0 gate: two repeated runs produce identical count budgets; actual user directories/processes untouched.

---

## W1 — v1-compatible quick wins

### W1.1 Pure semantic patch equality
Create:
- `agentd/src/domain/session-patch-policy.ts`
- `agentd/src/domain/session-patch-policy.test.ts`

RED: same scalar/nested patch no-op; absent vs own-property undefined semantics; changed value detected; `updatedAt` excluded.

Verify:
```bash
pnpm --dir agentd exec vitest run src/domain/session-patch-policy.test.ts
```

### W1.2 Integrate no-op before timestamp/save/emit
Modify:
- `agentd/src/session-supervisor.ts`
- `agentd/src/session-supervisor.test.ts`

RED: second identical patch changes neither updatedAt, save count, nor meta emit.

Verify:
```bash
pnpm --dir agentd exec vitest run src/session-supervisor.test.ts -t "semantic no-op"
pnpm --dir agentd run typecheck
```

### W1.3 Remove redundant artifact meta
Modify:
- `agentd/src/session-supervisor.ts:materializeTerminalArtifacts`
- `agentd/src/application/runtime-event-handler.test.ts`

RED: artifact terminal emits completed meta once, each new artifact once, persisted snapshot has full artifacts.

Verify:
```bash
pnpm --dir agentd exec vitest run src/application/runtime-event-handler.test.ts src/session-supervisor.test.ts
```

### W1.4 Ratchet W0 terminal budgets
Verify bootstrap P0 budgets unchanged and terminal counts reduced.

Carry-over P2s recorded at W0 review (fold in here or during W0 hardening):
- guard: detect access-modified/static observable array declarations (`internal var`, `public private(set) var`, `static var`), distinguishing exact `private` storage from `private(set)`, with blocked fixtures.
- guard: count HUD `PickySessionListViewModel` baseline on comment/string-stripped Swift source and repin (current raw baseline 63 includes 5 comment hits); document the lower-only repin procedure.
- W0.3: pin exact/narrow bootstrap byte budgets from the deterministic fixture (current 50–250KB range is too loose for the W1.4 ratchet); keep the separate 8MiB transport assertion.
- W0.3: add reconnect case — close registered app socket, register a replacement, assert the same 1+94 bounded route.

H1: reprioritize only. Structural work stops only if all final goals already pass, including unrelated observer callback 0.

---

## W2 — Exhaustive ownership manifest and dormant v2 contracts

No production v2 emission. No protocol-version bump. No app capability registration change yet.

### W2.1 Exhaustive persisted + transient ownership manifests
Create:
- `contracts/projection/session-field-ownership.json`
- `contracts/projection/session-transient-ownership.json`
- `agentd/src/domain/session-projection-ownership.ts`
- `agentd/src/domain/session-projection-ownership.test.ts`

Persisted manifest row for every `PickyAgentSessionSchema` key:
- persistence owner
- v1 event owner
- v2 mutation owner
- Swift child store
- snapshot merge/clear semantics
- P0 omission behavior
- consuming views/effects.

Required explicit owners: messages, logs, tools, todoState, subagentRuns, artifacts, changedFiles, queue+modes, activitySummary, finalAnswer, pendingExtensionUiRequest, messageJournalAvailable, archive fields, scalar meta.

Transient manifest must enumerate at least:
- `SessionMessageBuilder.states` journal/drafts/removed/cancelled IDs
- `SessionMessageBuilder.operationChains`
- `RuntimeEventHandler.assistantDrafts/thinkingDrafts/thinkingActive/pendingThinkingFlushes/processedTerminalRuns`
- `SessionSupervisor.patchChains/runSessionWrite`
- completion tracking sets/in-flight state.

Each transient row defines owner, serializer, terminal snapshot source, staged mutation rule, post-commit reset/rehydrate rule, and save-failure rollback rule. `runSessionWrite` is the outer terminal serializer; terminal finalization may not enter a nested message-builder operation chain that persists independently.

Compile/static requirement:
```ts
const ownership = { ... } satisfies Record<keyof PickyAgentSessionParsed, ProjectionOwnership>;
```
Transient tests assert the fixed list of required owner IDs so adding a new terminal-relevant map requires an explicit manifest update.

Verify:
```bash
pnpm --dir agentd exec vitest run src/domain/session-projection-ownership.test.ts
pnpm --dir agentd run typecheck
```

### W2.2 TS patch/mutation schemas
Modify: `agentd/src/protocol.ts`, `agentd/src/protocol.test.ts`
Create fixtures under `contracts/protocol/`:
- `session-projection-transaction.event.json`
- `session-projection-snapshot.event.json`

Steps:
1. metaPatch absent/null/value semantics.
2. explicit mutation for every non-meta owner from W2.1.
3. transaction: sessionId/epoch/baseRevision/revision/ordered mutations.
4. recovery snapshot: requestId/sessionId/epoch/revision/completeness/omittedFields/bounded projection.
5. transaction/recovery events remain dormant.

Verify:
```bash
pnpm --dir agentd exec vitest run src/protocol.test.ts src/domain/session-projection-ownership.test.ts
```

### W2.3 Swift codecs and ownership parity
Modify:
- `Picky/PickyAgentProtocol.swift`
- `PickyTests/ProtocolContractTests.swift`

Steps:
1. tri-state patch decoder using keyed-container `contains`.
2. exhaustive mutation enum.
3. transaction/recovery snapshot decode fixtures.
4. no reducer route yet; explicit dormant event handling test.
5. load ownership manifest and assert expected Swift store names/clear semantics are represented.

Verify:
```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/ProtocolContractTests
pnpm --dir agentd run test:contracts
```

### W2.4 Add dormant capability enum only
Modify TS capability schema/tests. Do not make Swift app send it yet. Constants/version unchanged.

---

## W3 — Centralize persistence, then add revision

Legacy v1 seq remains unchanged and is the only live cursor until W6 cutover.

### W3.1 Introduce behavior-preserving commit API
Modify: `agentd/src/session-supervisor.ts`
Tests: `agentd/src/session-supervisor.test.ts`

Create one internal serialized commit API that:
- receives current session inside `runSessionWrite` boundary
- builds next state
- atomically `store.save(next)`
- updates in-memory map only after save
- returns before/after/changed
- does not broadcast.

### W3.2 Route direct save families one at a time
Separate checkpoints, targeted test + typecheck after each:
1. generic `patch`
2. `syncSessionMessages`
3. `upsert`
4. todo/subagent/activity/queue helpers
5. startup/recovery/direct call sites

Gate:
```bash
! rg -n 'this\.store\.save\(' agentd/src/session-supervisor.ts
pnpm --dir agentd run typecheck
pnpm --dir agentd exec vitest run src/session-supervisor.test.ts src/session-message-builder.test.ts src/session-store.test.ts
```
Only the centralized helper may call `store.save` (allow exact helper line in the grep check if kept in same file).

### W3.3 Persisted revision migration
Modify:
- `agentd/src/protocol.ts`
- `agentd/src/session-store.ts`
- all session construction policies surfaced by typecheck
- `agentd/src/session-store.test.ts`

RED:
- old JSON normalizes revision 0
- safe nonnegative integer only
- save/reload preserves
- constructors compile.

Verify immediately:
```bash
pnpm --dir agentd exec vitest run src/session-store.test.ts src/protocol.test.ts
pnpm --dir agentd run typecheck
```

### W3.4 Revision commit policy
Create `agentd/src/domain/session-revision-policy.ts` + test.
Changed commit increments exactly once; no-op unchanged.
Integrate into centralized commit result.

Important: v1 events still emit existing seq and ignore revision. No socket consumes both.

### W3.5 Swift revision cursor policy
Create:
- `Picky/Sessions/PickySessionRevisionCursor.swift`
- `PickyTests/PickySessionRevisionCursorTests.swift`

RED cases:
- stale/duplicate revision drops;
- contiguous transaction applies;
- gap requests one per-session recovery;
- epoch change blocks until snapshot;
- matching snapshot installs cursor and stale buffered transactions drop.

Keep the policy dormant until W6; current v1 seq handling remains unchanged.

Verify:
```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickySessionRevisionCursorTests
```

---

## W4 — Compile-safe Swift storage and registry cutover

### W4.1 Centralize existing array writes while arrays remain sole owner
Modify `Picky/PickySessionViewModel.swift` in separate checkpoints:
1. snapshot replace-all method
2. upsert/remove method
3. message update method
4. todo/subagent/activity/queue/tool/artifact method
5. archive/order method
6. optimistic command method

Each checkpoint only redirects direct mutation; behavior unchanged.

Verify each family:
```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickySessionViewModelTests
```

### W4.2 Replace direct `$archivedSessions` dependency
Modify:
- `Picky/Companion/Onboarding/OnboardingFlowController.swift`
- `Picky/PickySessionViewModel.swift`
- Create: `PickyTests/OnboardingFlowControllerArchiveProjectionTests.swift`

Expose a narrow archive-membership publisher/query not tied to property-wrapper storage. Characterize initial archived IDs, later archive/unarchive updates, and cancellation/deallocation of the subscription.

Verify:
```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/OnboardingFlowControllerArchiveProjectionTests
```

### W4.3 Extract legacy storage owner
Create:
- `Picky/Sessions/PickySessionProjectionStorage.swift`
- `Picky/Sessions/PickyLegacySessionProjectionStorage.swift`
- tests.

Move stored arrays from façade into legacy storage once all writers use the boundary. Façade exposes read-only computed snapshots and relays storage change once per storage operation. This is a single compile-green cut.

Verify ViewModel + onboarding + build:
```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickySessionViewModelTests
```

### W4.4 Implement exact child stores
Create:
- `PickyMessageStore.swift`, `PickyConversationStore.swift`
- meta/log/tool/todo/subagent/artifact/changed-files/queue/activity/extension-UI stores per W2 ownership manifest
- `PickySessionStore.swift`, `PickySessionRegistry.swift`
- matching tests.

Rules:
- backing maps private + `@ObservationIgnored`.
- only ordered ID arrays observable.
- stable store identity per session/message.
- P0 omitted sections explicitly unavailable, never stale-retained.

Observation tests include negative + positive re-registration controls.

### W4.5 Registry-backed storage implementation
Create `PickyRegistrySessionProjectionStorage` behind W4.3 protocol.
RED:
- same v1 fixture yields same read-only SessionCard snapshot.
- one v1 input operation relays once.
- archive preference is policy input; registry is effective membership owner.

### W4.6 Atomic backend switch
Switch injected default from legacy storage to registry storage. Do not hot-migrate a running process; new ViewModel initializes one backend at construction.
Run build + ViewModel/bootstrap/Observation suites.

Gate: there is never a checkpoint with two writable copies.

---

## W5 — Durable terminal operation (P0 correctness gate)

Definition: terminal transaction means staged state + **one atomic SessionStore save + revision +1 + one v2 frame + notification after commit**. Projection batching without durable atomicity is forbidden.

### W5.1 Failure/concurrency RED tests
Modify/create terminal integration tests.
Cases:
- injected save failure leaves persisted session, supervisor map, message-builder state, runtime drafts, revision, frames, and notification calls unchanged.
- concurrent follow-up/archive/queue waits behind terminal operation and is not captured inside it.
- crash boundary is before or after one atomic rename; no partial session JSON.

### W5.2 Pure terminal finalization planner
Create:
- `agentd/src/domain/terminal-session-finalization.ts`
- test.

Input: immutable snapshots of current session + message-builder state + runtime drafts + runtime terminal event + prepared activity/artifact data.
Output: complete next session + ordered exhaustive mutations + explicit post-commit transient resets.
No I/O/emits/time except injected now. The planner cannot mutate `SessionMessageBuilder.states` or `RuntimeEventHandler` maps.

### W5.3 Snapshot transient state without saving
Add read-only terminal snapshot APIs to message builder/runtime handler one family at a time. Stage final message/thinking/activity/artifacts against the immutable operation draft. Non-terminal behavior stays unchanged. Terminal path must not call existing flush methods that enter `operationChains` and persist independently.

### W5.4 One serialized durable commit
Hold the supervisor per-session write boundary for the entire operation. Run planner, call SessionStore.save once, then update supervisor map. Revision +1. On save failure, discard the operation draft and leave all transient owners untouched.

### W5.5 Post-commit transient synchronization and publication
Only after successful commit:
1. rehydrate/reset `SessionMessageBuilder.states` from the committed journal;
2. clear committed runtime drafts/thinking state;
3. v1 mode emits legacy compatibility sequence while v2 is dormant, or later v2 mode emits one transaction;
4. invoke completion notification last.

Notification contract: save failure means notification 0. A post-commit notification failure does not roll back committed state; it follows current best-effort/in-process dedupe behavior and must log observably. Durable outbox/exactly-once delivery is a separate feature, not a blocker for messaging atomicity.

Verify:
```bash
pnpm --dir agentd exec vitest run src/domain/terminal-session-finalization.test.ts src/application/runtime-event-handler.test.ts src/session-supervisor.test.ts
pnpm --dir agentd run typecheck
```
Required assertions: save=1, revision delta=1, failed save frames=0, failed save notifications=0, failed save transient snapshots unchanged, post-commit notification failure leaves committed state intact.

---

## W6 — Per-session recovery and socket-exclusive v2 cutover

Human gate H2 before W6.5.

### W6.1 Recovery command/response contract
Define `getSessionProjectionSnapshot` command and dormant response already modeled in W2.
Fields: requestId/sessionId/epoch/revision/completeness/omittedFields/projection.
Reuse P0 byte-budget policy for one session.

### W6.2 Server unicast recovery
One in-flight response per request; same serialized projection barrier as commit publication.
Tests: bounded, revision-bearing, stale request correlation, omitted fields explicit.

### W6.3 Swift per-session recovery coordinator
- one in-flight request per session
- only affected session blocks
- session B continues while A recovers
- stale response ignored
- matching response installs cursor, applies bounded projection, then resumes buffered contiguous transactions
- omitted sections clear/mark unavailable.

### W6.4 Immutable socket dialect state
Server socket state: `negotiating | v1 | v2`.
- pending sockets receive hello/control but no session projection broadcasts.
- existing app capability registration without `sessionProjectionV2` locks v1.
- capability with v2 locks v2.
- first legacy projection command from non-registering CLI locks v1.
- mode cannot change on same socket.
- v1: P0 bounded snapshot + legacy seq only.
- v2: revision index/recovery snapshot + transactions only.

CLI/no-capability tests and old app capability tests mandatory.

### W6.5 Atomic capability + protocol + emission cutover
This is one indivisible implementation/release checkpoint; there is no compile-green/releasable intermediate where a socket locks v2 without projection output.

In the same packet:
- server dialect state/routing from W6.4 becomes active;
- Swift app starts registering `sessionProjectionV2`;
- ordinary commit emits one transaction to v2 sockets;
- terminal commit emits one transaction to v2 sockets;
- v1 events are disabled only for v2 sockets;
- a fresh revision-bearing v2 index snapshot installs cursors before live transactions;
- TS and Swift protocol versions bump;
- all fixtures, hard-coded envelopes, `pi-extensions/picky-handoff/index.ts`, connection-info/smoke assertions update.

Compatibility/rollback matrix gate:
1. new app + new bundled daemon → v2;
2. same-version CLI/no capability + new daemon → v1 dialect with P0 bounded snapshot;
3. same-version legacy-app capability set without v2 → v1 dialect;
4. old protocol client + new daemon and new client + old daemon → fail fast on version mismatch before projection, never mixed mode;
5. old persisted JSON → new daemon revision migration;
6. rollback is app+bundled-daemon as one unit; persisted unknown revision fields must not corrupt legacy session loading, and returning forward must force a new epoch snapshot.

Verify:
```bash
pnpm --dir agentd exec vitest run src/server.test.ts src/protocol.test.ts src/application/runtime-event-handler.test.ts src/session-supervisor.test.ts
pnpm --dir agentd run test:contracts
pnpm --dir agentd run typecheck
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/ProtocolContractTests
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickyAgentClientRouterTests
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickySessionRevisionCursorTests
```
P0/P1 blockers: mixed dialect, snapshot/replay mismatch, terminal rollback, recovery duplication, CLI wait regression.

---

## W7 — Bootstrap/terminal/steady-state gate on registry

Rerun W0 fixtures through v2 registry.
Deterministic budgets:
- P0 v1 path unchanged for v1 sockets.
- v2 bootstrap registry operations do not create O(N) global façade publishes; target legacy bridge <=1 for bootstrap, then 0 after view migration.
- terminal frame=1, save=1, revision+1.
- message-only unrelated child-store callbacks=0.
- dock projection recompute/transaction=1.
- metaPatch fixture <4KiB excluding owned large mutations.

H1 equivalent: scope reduction only if all user-visible root metrics pass. Otherwise continue W8.

---

## W8 — One measured Conversation vertical slice, then generalize

### W8.1 Conversation resolver/card
Pass stable session store + narrow commands, not concrete façade.

### W8.2 List/bubbles
ForEach orderedMessageIDs; stable PickyMessageStore per bubble; replace does not change list IDs/other identities.

### W8.3 Header/composer/context
Each receives exact child store. Header never reads conversation; composer never reads full session list.

Per slice gate:
1. owner inventory
2. writer/dependency removal
3. architecture ratchet decrease
4. Observation dependency tests
5. mounted-host positive control (supplementary)
6. PickyPerf signpost comparison (manual/profile evidence; ask before live app use)

If Conversation slice does not reduce measured fan-out/work, stop generalization and investigate body/layout cost.

---

## W9 — Dock, archive, Companion, Quick Input, cleanup

Sequential slices:
1. dock lightweight projection + target icon store
2. archive/settings/onboarding membership
3. Companion running count
4. Quick Input/voice command dispatcher
5. remove concrete façade from HUD/Conversation
6. remove legacy storage and SessionCard compatibility projection
7. tighten architecture ratchets to 0 allowlist.

Each slice uses exact targeted tests and full xcodebuild command; no generic “targeted suite” placeholder.

Final validation:
```bash
node scripts/check-architecture-rules.js --self-test=session-projection
node scripts/check-architecture-rules.js
pnpm --dir agentd run typecheck
pnpm --dir agentd run lint
pnpm --dir agentd run test:contracts
pnpm --dir agentd run test:serial
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" -parallel-testing-enabled NO test
```
Unrelated baseline failures are reported, not silently fixed or used to hide new diagnostics.

## 6. Performance evidence policy

CI gates deterministic work counts, identity, ownership, revision, event/save/publish counts.
It does not claim `withObservationTracking` proves SwiftUI rendering or that NSHostingView exact body counts are stable across OS.

Manual/profile acceptance:
- same fixture main-thread work >=80% reduction
- receive→apply p90 target <50ms
- completion max hang target <100ms
- minimum OS 14.2 evidence only if a real runner is available; otherwise record as manual/blocked
- running app profile requires explicit user approval.

## 7. Dynamic run template

For each packet (max 3 adjacent subtasks):
```text
subagent run worker --main -- "Read this plan. Implement only W?.?-W?.?. RED first. Run exact tests. No commit/push/restart."
# wait for completion
subagent run verifier --main -- "Verify W?.?-W?.? diff and exact commands; inspect ownership and unrelated changes."
# wait
subagent run reviewer --main -- "Review W?.?-W?.? for P0/P1 correctness/regression/maintainability."
```

At W6 and final W9, run stress-interview. Any unresolved P0/P1 blocks continuation regardless of repair count.

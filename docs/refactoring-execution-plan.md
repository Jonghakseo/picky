# Picky Refactoring Execution Plan

_Last updated: 2026-06-03_

This document is the source-of-truth plan for the maintainability/refactoring initiative discussed in the 2026-06-02 Pi session. It is intentionally self-contained so a future Pi/Picky session can resume the work from this document alone, even if the original conversation context is unavailable.

## 0. Executive summary

The goal is to raise Picky's maintainability, bug resilience, fail-safety, and readability to a very high standard without destabilizing the app. The key decision is:

> Do not start by splitting large files. First preserve runtime/state invariants with tests, then extract pure policies/reducers/projectors, while keeping existing facades stable.

The current macro risk is not file size by itself. The risk is that state invariants, event ordering, side effects, and UI projection rules are concentrated in a few large facades:

- `Picky/PickySessionViewModel.swift`
- `Picky/HUD/PickyHUDView.swift`
- `Picky/CompanionManager.swift`
- `agentd/src/session-supervisor.ts`

Refactoring must therefore proceed in this order:

1. Establish baseline tests and characterization tests for each target module.
2. Add static rules and a local pre-push quality gate to prevent regressions before sharing changes.
3. Document the mental-model rules and link them from `AGENTS.md`.
4. Extract only pure policies/reducers/projectors/mappers first.
5. Keep public/app-facing facade entrypoints stable until enough tests cover ordering, persistence, and UI identity.

## 1. Non-negotiables

These constraints come from `AGENTS.md`, `ARCHITECTURE.md`, and the stress-review findings.

1. **Local-first stays intact.** No SaaS backend, auth system, billing, remote analytics, or mandatory remote STT/TTS.
2. **Picky remains thin.** Picky captures neutral context and manages session UX; Pi interprets intent and chooses skills/tools/MCPs.
3. **Do not hard-code workflow routing in Picky.** No app-name/URL routing like “Sentry URL -> Sentry flow”.
4. **Do not restart the running Picky app unless explicitly asked.** UI smoke/manual runs require user approval.
5. **Do not change Xcode defaults to always sign.** Use `./scripts/package-signed-app.sh` only when a signed app bundle is needed.
6. **Do not let line-count rules block hotfixes.** File-size checks must start as warning/ratchet rules, not hard blockers.
7. **Do not split facades just to reduce line count.** Split only where an invariant boundary becomes clearer and better tested.
8. **Protocol changes are product changes.** Swift, TypeScript, and `contracts/protocol` fixtures must move together.

## 2. Evidence from the initial audit

These observations were cross-checked by the main session plus `verifier`, `reviewer`, and `challenger` subagents.

### 2.1 Size and concentration

- Swift files: 314 total, ~93,783 Swift lines.
- Production Swift under `Picky/`: 208 files, ~66,018 lines.
- agentd TypeScript: 92 TS files, ~31,261 lines.

Largest production files:

- `Picky/HUD/PickyHUDView.swift`: 4,190 lines.
- `Picky/PickySessionViewModel.swift`: 3,081 lines.
- `Picky/CompanionManager.swift`: 2,963 lines.
- `Picky/Companion/CompanionPanelSettingsView.swift`: 2,194 lines.
- `Picky/Overlay/BlueCursorView.swift`: 1,706 lines.
- `Picky/App/Settings/PickySettings.swift`: 1,499 lines.
- `Picky/PickyAgentDaemonLauncher.swift`: 1,394 lines.
- `Picky/PickyAgentProtocol.swift`: 1,229 lines.
- `agentd/src/session-supervisor.ts`: 3,647 lines.
- `agentd/src/runtime/openai-realtime-main-runtime.ts`: 2,090 lines.
- `agentd/src/runtime/pi-sdk-runtime.ts`: 1,447 lines.

Large tests also exist:

- `PickyTests/PickySessionViewModelTests.swift`: 4,539 lines.
- `agentd/src/session-supervisor.test.ts`: 6,521 lines.

### 2.2 Current strengths to preserve

- `agentd` has strict TypeScript and test coverage.
- `cd agentd && pnpm run typecheck` passed during audit.
- `cd agentd && pnpm test` passed during audit: 703 tests.
- Protocol fixtures are tested in both languages:
  - `agentd/src/protocol.test.ts`
  - `PickyTests/ProtocolContractTests.swift`
  - `contracts/protocol/*.json`
- `Picky/Interaction/PickyInteractionReducer.swift` is a good internal pattern: pure state transition + explicit effects.
- `docs/swift-concurrency.md` and `docs/perf-profiling.md` already encode important guardrails.

### 2.3 Current weaknesses to address

- No local quality gate existed before this initiative; release automation is packaging/notarization focused, while refactoring checks now belong in the local pre-push hook.
- No `.swiftlint.yml` in the project.
- No ESLint/Biome config for `agentd`.
- Swift production code has many `try?` and raw `print(` call sites.
- `PickySettingsStore` persists one JSON model that contains API-key-like fields.
- Swift `Domain/` is almost empty; many policies live in UI/view model/manager files.
- `agentd/src/domain` exists, but `session-supervisor.ts` still owns many pure policies and runtime invariants.

## 3. Stress-review findings to keep in mind

The `challenger` subagent marked the plan as **QUESTIONABLE unless refactoring is framed as invariant preservation first**.

### 3.1 Main challenge

Do not assume that large files are the primary risk. Large files are a symptom. The real risks are:

1. Event-ordering/concurrency regressions in `session-supervisor.ts`.
2. SwiftUI/AppKit identity/performance regressions in HUD refactors.
3. Superficial decomposition that increases cross-file coupling.
4. Over-strict static rules that block legitimate hotfix work.

### 3.2 Questions every refactor must answer

Before splitting `session-supervisor.ts`, `PickySessionViewModel.swift`, `PickyHUDView.swift`, or `CompanionManager.swift`, answer:

1. What exact runtime/state invariants must survive?
2. Which tests prove those invariants before and after the split?
3. Does this extraction reduce an invariant boundary, or only reduce file length?

### 3.3 Guardrails

- Write invariant/characterization tests before any split.
- Keep line-count checks warning-first and ratcheted.
- Require protocol fixture updates in Swift + TS for every protocol change.
- For HUD changes, compare signpost counts/durations before and after using `docs/perf-profiling.md`.

## 4. Definition of done for this initiative

This initiative is complete when the repository has:

1. **Baseline and module-specific characterization tests** for the high-risk facades.
2. **Static rules** via SwiftLint, ESLint/typescript-eslint, and custom architecture checks.
3. **A local pre-push quality gate** that runs the lightweight checks previously planned for CI before changes leave the workstation.
4. **A mental-model document** referenced from `AGENTS.md`.
5. **At least one successful pilot extraction** from `agentd/src/session-supervisor.ts` into pure `domain/` modules.
6. **At least one successful Swift pilot extraction** from `PickySessionListViewModel` or a HUD policy into a pure/policy module.
7. No regression in targeted tests, protocol contract tests, agentd tests, and relevant HUD performance checks.

## 5. Execution protocol for future sessions

Every future session that continues this work should start here.

### 5.1 Start-of-session checklist

Run:

```bash
git status --short
```

Then read:

```text
docs/refactoring-execution-plan.md
AGENTS.md
ARCHITECTURE.md
docs/swift-concurrency.md
docs/perf-profiling.md
```

Rules:

- Protect unrelated user changes.
- Do not restart Picky unless the user explicitly asks.
- For code changes, use characterization tests before refactoring.
- Keep one responsibility per PR/change.
- Do not combine static-rule setup, CI setup, and large code refactors in one undifferentiated change.

### 5.2 Recommended subagent usage

Use `stress-interview` after each meaningful design or code change.

Recommended prompts:

- `verifier`: “Verify this refactor with reproducible evidence: tests, typecheck, contract fixtures, and static checks. Mention skipped checks.”
- `reviewer`: “Review correctness, regressions, maintainability, and whether this split reduces an invariant boundary.”
- `challenger`: “Challenge hidden assumptions, failure scenarios, and whether this change is optimizing file size instead of user-visible failure modes.”

### 5.3 Stop/resume checklist

Before stopping a session, update the relevant section of this document or leave a concise handoff note containing:

- Current phase and task.
- Files changed.
- Tests added/changed.
- Validation commands run and results.
- Known skipped checks.
- Next exact command or file to inspect.

## 6. Phase 0 — Baseline validation

Purpose: know whether current HEAD is green before adding guards or refactoring.

### 6.1 agentd baseline

Run:

```bash
cd agentd
pnpm run typecheck
pnpm test
pnpm run test:contracts
```

Expected:

- TypeScript compile/typecheck passes.
- Vitest suite passes.
- Contract tests pass.

If any fail:

- Do not start refactoring.
- Record the failure as baseline failure.
- Fix only if the failure blocks this initiative and is clearly related.

### 6.2 Swift targeted baseline

Run at least:

```bash
xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test -only-testing:PickyTests/ProtocolContractTests
```

Then run targeted suites before touching each module:

```bash
xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickySessionViewModelTests

xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickyCompanionManagerTests

xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickyInteractionReducerTests
```

Full Swift suite is preferred before broad refactoring:

```bash
xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test
```

Note: use `-parallel-testing-enabled NO` because existing project notes mention occasional Speech/Audio framework runner instability with parallel test sharding.

## 7. Phase 1 — Test-first module safety nets

This phase adds or strengthens tests before structural extraction.

### 7.1 `agentd/src/session-supervisor.ts` invariants

Do not split `SessionSupervisor` until the relevant invariant tests exist.

#### Invariants to preserve

1. **Patch serialization**
   - Concurrent session patches must not overwrite each other.
   - `patchChains` behavior must survive extraction.

2. **Runtime event ordering**
   - Late `running`, `waiting_for_input`, or terminal events after cancellation must not resurrect cancelled/failed sessions.

3. **Duplicate quick reply/TTS prevention**
   - `turn_end` + `agent_end` pairs must not emit duplicate quick replies.
   - Duplicate event/listener paths must be deduped.

4. **Queue ordering and identity**
   - Steer/follow-up queue items preserve identity across duplicate text entries.
   - Removed queue items are diffed correctly.

5. **Abort semantics**
   - Abort during pending runtime handle creation must settle cleanly.
   - Late runtime handle resolution must not reattach cancelled sessions.

6. **Extension UI**
   - Waiting-for-input state enters and exits predictably.
   - Answer/cancel paths resume or clear pending requests exactly once.

7. **Terminal tail sync**
   - Terminal-tail-derived status transitions do not conflict with runtime-driven state.

8. **Pickle completion notification**
   - Main-agent completion notification is deduped and survives child/primary routing.

#### Suggested tests

Create or extend:

```text
agentd/src/session-supervisor.invariants.test.ts
agentd/src/domain/queue-policy.test.ts
agentd/src/domain/pointer-validation.test.ts
agentd/src/domain/image-size.test.ts
```

If adding a new large scenario test, prefer fixture builders/helpers so `session-supervisor.test.ts` does not grow indefinitely.

#### First extraction candidates

Extract only pure helpers first:

1. `agentd/src/domain/image-size.ts`
   - `readImageSize`
   - `readPngSize`
   - `readJpegSize`
   - `isJpegStartOfFrameMarker`

2. `agentd/src/domain/pointer-validation.ts`
   - screenshot selection
   - pointer coordinate clamp
   - pointer coordinate clamped flag

3. `agentd/src/domain/queue-policy.ts`
   - `matchPreviousQueueItems`
   - `queueItems`
   - `sameQueueItems`
   - `diffQueueRemovedItems`

4. `agentd/src/domain/activity-summary.ts`
   - zero/total activity summary helpers, if useful.

Validation after each extraction:

```bash
cd agentd
pnpm run typecheck
pnpm test
```

### 7.2 `Picky/PickySessionViewModel.swift` invariants

Do not split the view model until the relevant tests exist.

#### Invariants to preserve

1. Session list ordering and HUD sorting.
2. Dock layout projection, grouping, reordering, collapse state.
3. Archive/unarchive/delete behavior.
4. Unread/read state transitions.
5. Selected session sync after list changes.
6. Active voice follow-up target sync after list changes.
7. Screen-context target sync after list changes.
8. Composer draft and attachment persistence.
9. Inline terminal and shell terminal attachment lifecycle.
10. Terminal sync outcome display and dismissal.
11. Notification delivery dedupe.
12. Protocol event application order and sequence handling.

#### Suggested tests

Add focused tests rather than only expanding the already-large test file:

```text
PickyTests/PickySessionDockLayoutControllerTests.swift
PickyTests/PickySessionComposerDraftStoreTests.swift
PickyTests/PickySessionArchivePolicyTests.swift
PickyTests/PickySessionTerminalAttachmentTests.swift
PickyTests/PickySessionProjectionStoreTests.swift
```

If a new type is not extracted yet, tests may first target pure functions or a small internal policy introduced under test.

#### First extraction candidates

1. `DockLayoutController`
   - grouping/order mutation
   - persistence boundary
   - projection reconciliation

2. `ComposerDraftStore`
   - draft text
   - attachment paths
   - append/replace/clear behavior

3. `TerminalAttachmentCoordinator`
   - inline/shell active attachment state
   - promote/release behavior

4. `NotificationPolicy`
   - completion/blocked notification eligibility and dedupe key generation

Keep `PickySessionListViewModel` as the public `ObservableObject` facade while these collaborators are introduced.

### 7.3 `Picky/HUD/PickyHUDView.swift` invariants

HUD refactors are high risk because SwiftUI view identity and AppKit layout cycles can regress silently.

#### Invariants to preserve

1. Held/open/hover state does not reset unexpectedly.
2. Manual open request routes only to the intended display when `targetDisplayID` is set.
3. Dock shortcut resolution remains stable.
4. Dock group collapse closes cards only when appropriate.
5. Card resize start/end/reset behavior remains stable.
6. Add-slot expansion does not change dock order.
7. No implicit animation regression causing dock slot jumps.
8. No performance regression in message-heavy HUD activation.

#### Suggested tests/checks

- Add pure policy tests for any extracted HUD policy.
- Before/after manual or instrumented checks must follow `docs/perf-profiling.md`.
- Use signpost counts/durations for conversation card/list/bubble work when a HUD refactor touches identity or rendering.

#### First extraction candidates

1. Keyboard shortcut policy.
2. Held/open/hover transition policy.
3. Resize interaction policy.
4. Dock group collapse behavior.

Do not start with a broad `PickyHUDView` split.

### 7.4 `Picky/CompanionManager.swift` invariants

This should come after Session/HUD pilot work unless a voice bug demands it.

#### Invariants to preserve

1. Push-to-talk press/release routing.
2. Voice follow-up target snapshot semantics.
3. Realtime vs non-realtime routing.
4. Quick Input submission path.
5. TTS duplicate suppression.
6. Pointer overlay request handling.
7. Speech interruption on new voice input.
8. Overlay visibility reasons and cursor visibility behavior.

#### Suggested tests

- Expand `PickyInteractionReducerTests` for state-machine behavior.
- Keep `CompanionManager` effect-heavy paths covered by focused integration tests.
- Prefer extracting reducer/effect boundaries over directly splitting the whole manager.

## 8. Phase 2 — Static rules

Purpose: encode the most important maintainability rules so regressions are caught automatically.

### 8.1 SwiftLint

Add:

```text
.swiftlint.yml
```

Initial mode: warning-first and ratcheted, not hotfix-blocking.

Recommended built-in rules:

- `file_length`
- `type_body_length`
- `function_body_length`
- `cyclomatic_complexity`
- `force_try`
- `force_cast`
- `empty_count`
- `redundant_optional_initialization`

Recommended custom rules:

1. Raw print rule
   - Flag `print(` in production code.
   - Allow `Picky/Feedback/PickyLogger.swift` and possibly tests.
   - Preferred path: `PickyLog.notice(...)` or `OSLog`/`Logger` helpers.

2. Silent async action failure rule
   - Flag `Task { try? await ... }` for side-effecting user actions.
   - Sleep/cancellation patterns can be allowlisted.

3. Concurrency escape hatch rule
   - Flag `Task.detached` and `DispatchSemaphore` unless allowlisted with a clear comment.
   - Follow `docs/swift-concurrency.md`.

4. Domain import rule
   - Flag `import SwiftUI`, `import AppKit`, `import Combine`, `import AVFoundation`, `import ScreenCaptureKit` inside future pure domain/policy directories, unless explicitly allowlisted.

Reference: SwiftLint rule directory — https://realm.github.io/SwiftLint/rule-directory.html

### 8.2 TypeScript ESLint

Add ESLint/typescript-eslint to `agentd`.

Recommended config targets:

- `@typescript-eslint/no-explicit-any`
- `@typescript-eslint/no-floating-promises`
- `@typescript-eslint/switch-exhaustiveness-check`
- `@typescript-eslint/consistent-type-imports`
- `no-console` with allowlist for `agentd/src/local-log.ts`, entrypoint startup lines, and tests.

Add scripts to `agentd/package.json`:

```json
{
  "scripts": {
    "lint": "eslint src --ext .ts",
    "lint:fix": "eslint src --ext .ts --fix"
  }
}
```

Reference: typescript-eslint rules — https://typescript-eslint.io/rules/

### 8.3 Architecture guard script

SwiftLint/ESLint will not catch every architectural rule. Add a custom script, for example:

```text
scripts/check-architecture-rules.sh
```

or:

```text
scripts/check-architecture-rules.ts
```

Recommended checks:

1. Protocol version parity
   - `Picky/PickyAgentProtocol.swift` `pickyAgentProtocolVersion`
   - `agentd/src/protocol.ts` `PROTOCOL_VERSION`
   - `contracts/protocol/*.json`

2. Protocol fixture coverage
   - New command/event cases should have matching fixtures.
   - If full case matching is difficult initially, start with version parity and fixture decode checks.

3. Secret persistence lint
   - Flag `PickySettings.CodingKeys` entries matching `apiKey|token|secret`.
   - Existing keys should be allowlisted only until migration is implemented.

4. Boundary import lint
   - Swift pure domain/policy directories cannot import UI or system side-effect frameworks.
   - agentd `domain/` cannot import `server`, `ws`, `fs`, runtime adapters, or application services unless explicitly justified.

5. File-size ratchet
   - Existing large files are allowlisted.
   - New files above threshold or large growth emit warning/annotation first.

## 9. Phase 3 — Local pre-push quality gate

Use the repository's local hooks path for this initiative. The project already configures hooks through:

```json
{
  "scripts": {
    "prepare": "git config core.hooksPath .githooks || true"
  }
}
```

The pre-push hook should delegate to a reusable script:

```text
.githooks/pre-push
scripts/pre-push-checks.sh
```

Default pre-push checks:

1. `agentd` quality
   - `pnpm --dir agentd run typecheck`
   - `pnpm --dir agentd run lint`
   - `pnpm --dir agentd run test:serial`

2. Architecture guard
   - `pnpm run check:architecture`

3. Swift lightweight checks
   - `swiftlint lint --config .swiftlint.yml --quiet`
   - `xcodebuild ... test -only-testing:PickyTests/ProtocolContractTests`

Full Swift suite remains opt-in so unrelated or long-running Swift failures do not block every push during the refactoring initiative:

```bash
PICKY_PRE_PUSH_FULL_SWIFT=1 pnpm run check:pre-push
```

Reference: Git hooks — https://git-scm.com/docs/githooks

## 10. Phase 4 — Mental-model documentation and `AGENTS.md` link

Create:

```text
docs/refactoring-principles.md
```

Then add a link in `AGENTS.md`, likely under “Implementation guidance” or “Code navigation index”.

Suggested `AGENTS.md` insertion:

```md
- Refactoring principles and safety gates: `docs/refactoring-principles.md` (follow this before structural splits; write characterization tests first, extract pure policies before splitting facades, keep line-count checks warning-first, and preserve the Picky neutral-context / Pi-intent boundary).
```

### 10.1 Contents of `docs/refactoring-principles.md`

Include these mental-model rules:

1. **Reducers decide; managers execute effects.**
   - State transitions live in pure reducers/policies.
   - Network/file/UI actions live in effect runners/adapters.

2. **Adapters translate; domain owns invariants.**
   - Pi SDK/OpenAI/WebSocket/AppKit adapters should translate external APIs.
   - Queue ordering, status transitions, dedupe, archive/unread, and projection rules belong in domain/application policies.

3. **Split by invariant, not by line count.**
   - A split is valid only if it clarifies ownership and reduces the scope of an invariant.

4. **One mutable state owner per cluster.**
   - Session projection, dock layout, composer drafts, terminal attachments, voice input, and pointer overlay each need a clear owner.

5. **Every async user action must fail visibly or observably.**
   - Avoid silent `try?` for side-effecting actions.
   - Failure should surface via UI error, log, retry affordance, or test-observable state.

6. **Protocol changes are product changes.**
   - Swift, TS, and fixtures move together.

7. **HUD optimization requires measurement.**
   - Follow `docs/perf-profiling.md`.

8. **Swift concurrency stays MainActor-first.**
   - Follow `docs/swift-concurrency.md`.

9. **Picky captures neutral context; Pi interprets intent.**
   - Do not move Pi skill/tool policy into Picky.

## 11. Phase 5 — First agentd pilot extraction

This is the recommended first code refactor because it is pure, testable, and low risk.

### 11.1 Candidate A: image size parsing

Create:

```text
agentd/src/domain/image-size.ts
agentd/src/domain/image-size.test.ts
```

Move only pure Buffer parsing from `agentd/src/session-supervisor.ts` into domain:

- `readImageSizeFromBuffer`
- `readPngSize`
- `readJpegSize`
- `isJpegStartOfFrameMarker`

Keep file IO wrappers such as `readImageSize(path)` in the facade/adapter layer, because `agentd/src/domain` must not import `node:fs`.

Test cases:

- valid PNG dimensions
- invalid PNG header
- valid JPEG SOF dimensions
- truncated JPEG
- JPEG scan-data stop before SOF
- non-image buffer

Validation:

```bash
cd agentd
pnpm run typecheck
pnpm test
```

### 11.2 Candidate B: pointer validation

Create:

```text
agentd/src/domain/pointer-validation.ts
agentd/src/domain/pointer-validation.test.ts
```

Move or wrap:

- screenshot selection by requested `screenId`
- cursor/primary/focus fallback selection
- coordinate clamping
- clamped flag behavior

Test cases:

- empty screenshots throws
- explicit screen ID match by `screenId`
- explicit screen ID match by screenshot `id`
- unknown screen ID throws
- cursor screen preferred
- label fallback with `cursor|primary|focus`
- first screenshot fallback
- clamping x/y below/above bounds

### 11.3 Candidate C: queue policy

Create:

```text
agentd/src/domain/queue-policy.ts
agentd/src/domain/queue-policy.test.ts
```

Move:

- `matchPreviousQueueItems`
- `queueItems`
- `sameQueueItems`
- `diffQueueRemovedItems`

Test cases:

- duplicate text entries preserve distinct IDs
- queue growth matches previous entries from the front
- queue shrink matches previous entries from the back
- pending delivery ID is reused when no previous match exists
- removed queue items are correctly computed across steer/follow-up queues

### 11.4 Agentd pilot success criteria

- `session-supervisor.ts` gets smaller without changing public behavior.
- Extracted modules are pure and unit-tested.
- `pnpm run typecheck` passes.
- `pnpm test` passes.
- `reviewer` agrees the split reduces an invariant boundary or moves pure logic out of the facade.
- `challenger` does not identify event-ordering regression risk.

## 12. Phase 6 — First Swift pilot extraction

After agentd pilot succeeds, start with a low-risk Swift extraction.

### 12.1 Preferred candidate: `DockLayoutController`

Why:

- Dock layout/grouping behavior is already partly represented by pure types in `Picky/HUD/PickyDockGrouping.swift` and `Picky/HUD/PickyHUDLayoutPolicy.swift`.
- It can be tested without changing SwiftUI view identity.
- It reduces `PickySessionListViewModel` responsibility without touching voice or HUD rendering.

Possible files:

```text
Picky/Sessions/PickySessionDockLayoutController.swift
PickyTests/PickySessionDockLayoutControllerTests.swift
```

Responsibilities:

- load/save dock layout through injected store
- reconcile layout with known session IDs
- move session in dock
- create/rename/remove groups
- reset manual order

Keep in `PickySessionListViewModel` initially:

- `@Published dockLayout`
- public methods used by existing views
- event application facade

The view model should delegate to the controller and publish the resulting state.

### 12.2 Second candidate: `ComposerDraftStore`

Possible files:

```text
Picky/Sessions/PickyComposerDraftStore.swift
PickyTests/PickyComposerDraftStoreTests.swift
```

Responsibilities:

- persisted draft text per session
- attachment paths per session
- append/replace/clear behavior
- draft request consumption

### 12.3 Swift pilot validation

Run relevant targeted tests:

```bash
xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickySessionViewModelTests
```

Run new tests:

```bash
xcodebuild -project Picky.xcodeproj \
  -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickySessionDockLayoutControllerTests
```

If HUD behavior is touched, also perform the `docs/perf-profiling.md` workflow before and after.

## 13. Anti-patterns to avoid

1. **Superficial file chopping**
   - Moving chunks into extensions/files without changing ownership or testability is not enough.

2. **Manager-to-manager coupling**
   - Avoid creating many collaborators that all mutate the same state cluster.

3. **Side-effecting domain modules**
   - Pure domain/policy modules should not perform file IO, network calls, UI calls, or process control.

4. **Silent failure in user actions**
   - Avoid `Task { try? await viewModel.someUserAction() }` without error surfacing.

5. **Hard line-count gates too early**
   - This creates incentive to hide complexity instead of removing it.

6. **HUD refactor without measurement**
   - SwiftUI/AppKit identity and layout can regress even when code looks cleaner.

7. **Protocol drift by manual edits**
   - Always update fixtures and both language tests.

8. **Changing Picky/Pi responsibility boundary**
   - Do not duplicate Pi skill selection, MCP behavior, or task routing policy in Picky.

## 14. Suggested commit/change sequencing

Keep each change small and reviewable.

1. `docs: add refactoring execution plan`
   - This document only.

2. `test: add agentd invariant coverage`
   - No production extraction yet.

3. `chore: add architecture guard checks`
   - Script only, warning-first where appropriate.

4. `chore: add lint configuration`
   - SwiftLint and/or ESLint setup.

5. `chore: add local pre-push quality gate`
   - Local pre-push checks.

6. `docs: add refactoring principles`
   - `docs/refactoring-principles.md` + `AGENTS.md` link.

7. `refactor(agentd): extract image size policy`
   - First pure extraction.

8. `refactor(agentd): extract queue policy`
   - Second pure extraction.

9. `refactor: extract session dock layout controller`
   - First Swift pilot.

Note: actual commits should only be made when the user/workflow explicitly asks for commits. Follow repository commitlint when committing.

## 15. Official references

- Git hooks: https://git-scm.com/docs/githooks
- SwiftLint rule directory: https://realm.github.io/SwiftLint/rule-directory.html
- typescript-eslint rules: https://typescript-eslint.io/rules/
- Swift Concurrency migration/guidance should also follow Apple documentation and the local project guide in `docs/swift-concurrency.md`.

## 16. Immediate next step if resuming

If no implementation has started yet, proceed in this exact order:

1. Run `git status --short`.
2. Run agentd baseline:
   ```bash
   cd agentd && pnpm run typecheck && pnpm run test:serial && pnpm run test:contracts
   ```
3. Run Swift protocol contract baseline:
   ```bash
   xcodebuild -project Picky.xcodeproj \
     -scheme Picky \
     -destination "platform=macOS,arch=$(uname -m)" \
     -parallel-testing-enabled NO \
     test -only-testing:PickyTests/ProtocolContractTests
   ```
4. Add tests for the first agentd pilot (`image-size` or `queue-policy`) before moving production code.
5. After each task, run `stress-interview` with verifier/reviewer/challenger.

# Picky Refactoring Plan — Final after Self-healing

Scope: Safe, behavior-preserving refactoring plan for the Picky codebase. Goal is to reduce oversized files, clarify module responsibilities, and preserve the current thin-Picky / Pi-decides architecture.

## Execution status

This plan has now been executed through the documentation finalization phase.

- Phase 0A completed in `3187113 docs: add refactoring phase 0 baseline`; artifact: [`docs/refactoring/phase-0a-baseline.md`](refactoring/phase-0a-baseline.md).
- Phase 1 completed in `1bc5c92 refactor: organize phase 1 module boundaries`; focused on low-risk folder placement and pure module boundaries.
- Phase 2 completed in `eb87370` plus formatting fix `984df2e`; focused on HUD/overlay/panel UI decomposition.
- Phase 3 completed in `298db42` plus cancellation boundary fix `9db897b`; focused on Companion/dictation responsibility separation while preserving cancellation behavior.
- Phase 4 completed in `26d2a1c refactor: decompose agentd session application layer`; focused on agentd application collaborators behind the existing `SessionSupervisor` facade.
- Phase 5 was intentionally skipped by the YAGNI gate after verifier/reviewer pass: `agentd/src/server.ts` and `agentd/src/runtime/pi-sdk-runtime.ts` remain understandable, and splitting transport/runtime helpers would add indirection without enough reuse or independent test value.
- Phase 6 is this documentation finalization pass: architecture snapshots, deferred items, and maintenance rules are recorded without production code changes.

## Self-healing summary

### Cycle 1

Stress-interview results:
- verifier found incorrect line counts, inaccurate Xcode project-reference risk, missing file placements, nonexistent target files, and risky `SessionCard` extraction assumptions.
- reviewer found PR slices too broad, shared session state incorrectly placed under HUD, unclear MainActor/coordinator boundaries, unclear runtime-event state ownership, and missing geometry tests.
- challenger found that the plan mixed mechanical extraction with lifecycle architecture changes and allowed weak baseline failures.

Plan changes applied:
- Corrected line counts.
- Noted `PBXFileSystemSynchronizedRootGroup` and removed inaccurate pbxproj-edit risk.
- Added missing Swift/agentd files to target structure.
- Kept `SessionCard` nested via extension file instead of promoting it to top-level.
- Added neutral `Sessions/` ownership for shared session selection/archive state.
- Reduced CompanionManager coordinator plan to 2–3 concrete extractions.
- Made `RuntimeEventHandler` the single state-transition owner.
- Made agentd transport/runtime cleanup optional/YAGNI-gated.
- Re-sliced PRs into smaller responsibility units.

### Cycle 2

Stress-interview results:
- verifier confirmed corrected line counts, Xcode synced-root claim, baseline commands, and agentd helper extraction targets.
- verifier found remaining concrete issues: known `fileprivate` break in dictation extraction, missing explicit file rename, phantom onboarding file, unclear split of session archive store, test file move note, and root `server.ts` ambiguity.
- reviewer subagent failed, so Cycle 2 review coverage is partial.
- challenger found remaining risks around Swift access control, Phase 0 becoming too broad, UI smoke verification, and missing `CompanionPanelView` split phase.

Plan changes applied:
- Added Swift access-control dry-run checklist to every file-split phase.
- Added known `BuddyPushToTalkShortcut` `fileprivate` case.
- Added explicit `PickySessionViewModel.swift` -> `PickySessionListViewModel.swift` rename step.
- Removed phantom `CompanionOnboardingMedia.swift` from target structure.
- Kept session selection/archive stores in one initial `Sessions/PickySessionSelectionStore.swift` file unless later split is justified.
- Added note that agentd test files should move with source files when source files move.
- Clarified `server.ts` remains root-level unless optional Phase 5 is executed.
- Split Phase 0 into minimal baseline/preflight and phase-local characterization tests.
- Added `CompanionPanelView` decomposition phase.
- Added a user-approved manual smoke gate for UI decomposition PRs.

## Current evidence

Large Swift files:
- `Picky/DesignSystem.swift` — 880 lines: design tokens, button styles, view helpers, cursor helpers.
- `Picky/BuddyDictationManager.swift` — 880 lines: shortcut models, permissions, dictation lifecycle, audio state.
- `Picky/OverlayWindow.swift` — 780 lines: `OverlayWindow`, cursor view, bubble layout, overlay manager.
- `Picky/PickySessionViewModel.swift` — 692 lines: HUD state, session mapping, notifications, Ghostty resume, archive/search, artifact opening.
- `Picky/CompanionManager.swift` — 712 lines: permission polling, onboarding, overlay, shortcut, context capture, agent submission, agent event response.
- `Picky/PickyHUDOverlay.swift` — 771 lines: NSPanel manager, HUD layout policy, session cards, action UI.
- `Picky/CompanionPanelView.swift` — 548 lines: menu panel rendering and permission/onboarding UI.

Large agentd files:
- `agentd/src/session-supervisor.ts` — 408 lines: session lifecycle, main-agent routing, side-agent handoff, runtime events, extension UI, artifacts, persistence patching.
- `agentd/src/runtime/pi-sdk-runtime.ts` — 215 lines: runtime factory, Pi session wrapper, image options, extension UI binding.
- `agentd/src/server.ts` — 152 lines: websocket transport, command dispatch, event factory/log formatting.

Project facts:
- `Picky.xcodeproj/project.pbxproj` uses `PBXFileSystemSynchronizedRootGroup`.
- Moving `.swift` files under synced `Picky/` subfolders should not require manual `PBXBuildFile` / `PBXFileReference` edits.
- Still verify each move with `xcodebuild test`, because `private` / `fileprivate`, generated accessors, tests, resource paths, and runtime UI behavior can still break.

Baseline evidence from Cycle 1 verifier:
- `pnpm --dir agentd test`: pass.
- `pnpm --dir agentd typecheck`: pass.
- `xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test`: pass.

Constraints:
- No deterministic workflow routing in Picky; Pi skills/extensions decide intent.
- Picky app restart should only happen when the user requests it.
- Refactoring PRs must not introduce feature changes.
- Avoid signing/project-default changes.
- Preserve protocol contract fixtures.
- Do not promote nested Swift types to top-level unless separately approved.

References / principles:
- Swift API Design Guidelines: clarity at use site and concise, unambiguous names.
- Apple SwiftUI model data guidance: separate model/state from views for modularity and testability.
- Node ESM/package docs: explicit module boundaries.
- TypeScript project references: useful for larger multi-project builds, but optional/YAGNI here.

## Target structure

### Swift target structure

```text
Picky/
  App/
    PickyApp.swift
    AppBundleConfiguration.swift
    PickyAnalytics.swift
    MenuBarPanelManager.swift
    WindowPositionManager.swift

  DesignSystem/
    DS+Colors.swift
    DS+Spacing.swift
    DS+Buttons.swift
    DS+ViewModifiers.swift
    BuddyComposerVisualStyle.swift
    IBeamCursorView.swift

  Context/
    PickyContextPacket.swift
    PickyContextPacketAssembler.swift
    PickyAppSupport.swift
    PickyAppSupportScreenshotStore.swift
    PickyAdvancedContext.swift
    AppleScriptBrowserContextProvider.swift
    ClipboardSelectedTextProvider.swift
    CGWindowPickyWindowContextProvider.swift
    CompanionScreenCaptureUtility.swift

  AgentClient/
    PickyAgentProtocol.swift
    PickyAgentClient.swift
    WebSocketPickyAgentClient.swift
    LocalStubPickyAgentClient.swift
    PickyAgentDaemonLauncher.swift
    PickyRuntimeDependencyChecker.swift

  Sessions/
    PickySessionSelectionStore.swift      # initially contains both selection and archive stores
    PickySessionArchive.swift
    PickyFriendlyRuntimeError.swift

  Companion/
    CompanionManager.swift
    CompanionVoiceState.swift
    CompanionPanelView.swift
    CompanionPanelPermissionsView.swift
    CompanionPanelFooterView.swift
    Dictation/
      BuddyDictationManager.swift
      BuddyPushToTalkShortcut.swift
      BuddyDictationPermissionProblem.swift
      BuddyAudioConversionSupport.swift
      BuddyTranscriptionProvider.swift
      AppleSpeechTranscriptionProvider.swift
      GlobalPushToTalkShortcutMonitor.swift

  Overlay/
    OverlayWindow.swift
    OverlayWindowManager.swift
    BlueCursorView.swift
    BubbleLayout.swift
    CursorResponseViews.swift
    CompanionResponseOverlay.swift

  HUD/
    PickyHUDOverlayManager.swift
    PickyHUDView.swift
    PickySessionCardView.swift
    PickyToolActivityRow.swift
    PickyHUDLayoutPolicy.swift
    PickySessionListViewModel.swift        # renamed from PickySessionViewModel.swift
    PickySessionListViewModel+SessionCard.swift
    PickySessionNotifications.swift
    PickyGhosttyResumeLauncher.swift
    PickyArtifactReporter.swift
    PickyArtifactPathValidator.swift
    PickyDiffPreview.swift

  Settings/
    PickySettings.swift
    PickySettingsStore.swift
    PickySettingsViewModel.swift
    PickySettingsView.swift
```

Notes:
- `PickySessionListViewModel.SessionCard` remains nested. Extract as `extension PickySessionListViewModel { struct SessionCard ... }`, not as a top-level type.
- `PickySessionSelectionStore.swift` initially keeps both `PickyUserDefaultsSessionSelectionStore` and `PickyUserDefaultsSessionArchiveStore`; split only if the file grows or ownership becomes clearer.
- `searchSessions(query:)` stays in `PickySessionListViewModel.swift` for now; a one-method `PickySessionSearch.swift` is not worth the extra file.
- No `CompanionOnboardingMedia.swift` target is listed until a concrete onboarding extraction is approved.

### agentd target structure

```text
agentd/src/
  index.ts
  server.ts                         # remains here unless optional Phase 5 runs

  protocol/
    protocol.ts
    auth.ts

  transport/                        # optional Phase 5 only
    websocket-server.ts
    command-dispatcher.ts
    event-factory.ts
    log-fields.ts

  application/
    session-supervisor.ts            # facade; public methods stable
    visible-session-lifecycle.ts
    main-agent-orchestrator.ts
    side-agent-orchestrator.ts       # only if it stays cohesive
    runtime-event-handler.ts         # single owner of runtime-event state transitions
    extension-ui-request-mapper.ts   # pure helper only
    artifact-materializer.ts
    handoff-tool.ts
    extension-ui-bridge.ts           # or runtime/ if more cohesive after inspection

  domain/
    session-status.ts
    session-title.ts
    session-summary.ts
    changed-files.ts
    artifacts.ts
    pi-event-normalizer.ts

  runtime/
    types.ts
    mock-runtime.ts
    pi-sdk-runtime.ts
    pi-sdk-session.ts                # optional Phase 5 only
    image-options.ts                 # optional Phase 5 only

  prompts/
    prompt-builder.ts
    context-renderer.ts              # optional extraction from prompt-builder.ts

  stores/
    session-store.ts
    artifact-store.ts
    log-store.ts

  routing/
    task-router.ts
    quick-reply.ts                   # optional extraction from task-router.ts
    router-prompt.ts                 # optional extraction from task-router.ts

  utils/
    local-log.ts
```

Notes:
- When an agentd source file moves, its matching `*.test.ts` should move with it or have imports updated in the same PR.
- Optional files are created only if a source function is actually extracted.

## Deferred items after Phase 6

These were intentionally left for future work because they did not clearly reduce complexity in the completed refactor slices:

- `PickyAgentClient.swift` split deferred until the app/daemon boundary grows enough to justify separate protocol, WebSocket, and stub files.
- `DesignSystem.swift` split deferred until design tokens/styles need independent ownership or tests.
- HUD session card separate file deferred; keep card extraction conservative and avoid promoting nested session-card types to top-level without separate approval.
- Cursor response/navigation bubble extraction deferred until overlay view complexity grows or pure layout testing needs it.
- Broader `main-agent-orchestrator` / visible lifecycle extraction beyond the Phase 4 application-layer split deferred until session orchestration responsibilities grow again.
- Phase 5 transport/runtime split skipped until `server.ts` or `pi-sdk-runtime.ts` complexity grows enough that extraction has net maintainability value.

## Maintenance rules

- Protocol changes require contract fixtures and both Swift/TypeScript tests in the same PR.
- UI manual smoke requires user approval before launching or restarting Picky.
- Avoid app restart unless the user explicitly requests it.
- Keep one responsibility per PR; do not mix UI restructuring, protocol changes, and runtime behavior changes.
- Access-control widening (`private` / `fileprivate` to broader visibility) must be explicit in PR notes and justified by the file boundary being introduced.
- Optional line-count checks may be added later as warning-only maintenance aids; do not make them CI-blocking for urgent hotfixes.

## Phase plan

### Phase 0A — Minimal baseline and preflight

Status: completed in `3187113`; execution artifact is [`docs/refactoring/phase-0a-baseline.md`](refactoring/phase-0a-baseline.md).

Purpose: establish the safety net without turning Phase 0 into a large implementation project.

Tasks:
1. Record baseline command results:
   - `pnpm --dir agentd test`
   - `pnpm --dir agentd typecheck`
   - `xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test`
2. Hard gate:
   - Do not proceed unless all baseline tests pass.
   - If a known failure appears, stop and ask whether to accept that failure as baseline.
3. Swift move preflight:
   - Confirm synced root groups are present.
   - Search planned source files for `private` / `fileprivate` declarations before splitting across files.
   - For each extracted Swift type/helper, choose one of:
     - keep helper in original file;
     - move caller and helper together;
     - widen access from `private/fileprivate` to `internal` with a comment in the PR description.
4. Protocol preflight:
   - Identify protocol files/fixtures touched by the phase.
   - Any protocol schema change requires fixture updates and Swift/TS tests in the same PR.

Exit criteria:
- Baseline suite is green or explicitly accepted as a known baseline by the user.
- Access-control checklist is documented for the first planned Swift split.
- No production behavior changes.

Execution artifact:
- `docs/refactoring/phase-0a-baseline.md`


#### Phase 0A detailed task list

Use this as the executable checklist for the first refactoring PR. Phase 0A should not move production code. It only records the baseline, confirms project mechanics, and prepares the access-control/protocol guardrails for Phase 1.

##### Task 0A-1 — Confirm clean working state

**Purpose:** avoid mixing refactoring guardrails with unrelated local changes.

**Commands:**

```bash
git status --short
git branch --show-current
```

**Expected result:**
- Current branch is the intended refactoring branch.
- Working tree is clean, or unrelated changes are explicitly noted before continuing.

**Output artifact:**
- Add a short note to the Phase 0A PR description: branch name and whether the working tree was clean at baseline time.

##### Task 0A-2 — Record toolchain versions

**Purpose:** make baseline failures/debugging reproducible.

**Commands:**

```bash
xcodebuild -version
node --version
pnpm --version
```

**Expected result:**
- Commands complete successfully.
- Versions are recorded in the Phase 0A PR description or in a short execution note.

##### Task 0A-3 — Run agentd test baseline

**Purpose:** prove Node/TypeScript behavior is green before refactoring.

**Command:**

```bash
pnpm --dir agentd test
```

**Expected result:**
- PASS.

**If it fails:**
- Stop.
- Capture the failing test names and error summary.
- Ask whether to accept the failure as baseline before proceeding.

##### Task 0A-4 — Run agentd typecheck baseline

**Purpose:** prove TypeScript compile/type state is green before moving modules.

**Command:**

```bash
pnpm --dir agentd typecheck
```

**Expected result:**
- PASS / no type errors.

**If it fails:**
- Stop and treat it as a baseline gate failure.

##### Task 0A-5 — Run Swift/Xcode test baseline

**Purpose:** prove macOS app tests are green before file moves.

**Command:**

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
```

**Expected result:**
- PASS.

**If it fails:**
- Stop.
- Capture failing test names and the `.xcresult` path.
- Ask whether to accept the failure as baseline before proceeding.

##### Task 0A-6 — Confirm Xcode filesystem-synced groups

**Purpose:** verify Swift file moves under `Picky/` should not require manual `project.pbxproj` file-reference edits.

**Command:**

```bash
grep -n "PBXFileSystemSynchronizedRootGroup" Picky.xcodeproj/project.pbxproj
```

**Expected result:**
- One or more `PBXFileSystemSynchronizedRootGroup` entries are present.

**Output artifact:**
- Record that Xcode uses filesystem-synced groups.
- Still run tests after moves because access control and runtime behavior can break independently of project references.

##### Task 0A-7 — Build Phase 1 Swift access-control checklist

**Purpose:** prevent compile failures from moving `private` / `fileprivate` helpers across files.

**Command:**

```bash
rg -n "\b(fileprivate|private)\b" \
  Picky/PickySessionViewModel.swift \
  Picky/PickyContextPacket.swift \
  Picky/PickyAgentClient.swift \
  Picky/PickySettings.swift \
  Picky/PickySessionPolish.swift \
  Picky/DesignSystem.swift \
  Picky/BuddyDictationManager.swift
```

**Expected result:**
- All `private` / `fileprivate` declarations that may cross file boundaries are identified before Phase 1/3.

**Checklist decisions to record:**
- Keep helper in original file.
- Move caller and helper together.
- Widen to `internal` only when necessary, and mention it explicitly in the PR notes.

**Known required check:**
- `BuddyPushToTalkShortcut` has `fileprivate` helper extensions used by `BuddyDictationManager`; Phase 3 must either keep those helpers with their callers or widen access deliberately.
- `PickySessionListViewModel.SessionCard` helper extensions must be checked before extracting to `PickySessionListViewModel+SessionCard.swift`.

##### Task 0A-8 — Build protocol/contract touch map

**Purpose:** prevent accidental protocol drift between Swift and TypeScript.

**Commands:**

```bash
find contracts -type f | sort
rg -n "pickyAgentProtocolVersion|PROTOCOL_VERSION|CommandEnvelope|EventEnvelope|PickyAgentSession" Picky agentd/src contracts
```

**Expected result:**
- Protocol owner files and contract fixtures are identified.

**Guardrail:**
- Phase 0A should not change protocol fields.
- Any future protocol schema change must update fixtures and both Swift/TS tests in the same PR.

##### Task 0A-9 — Create Phase 1 execution notes

**Purpose:** make the first actual refactor phase reviewable and reversible.

**Content to prepare in the Phase 0A PR description or issue:**
- Baseline command results.
- Toolchain versions.
- Xcode synced-root confirmation.
- Access-control checklist summary.
- Protocol/contract touch map summary.
- The first Phase 1 PR slice to execute, preferably `agentd` pure domain helper extraction or Swift standalone folder placement.

##### Task 0A-10 — Gate decision

**Purpose:** explicitly decide whether implementation may start.

**Proceed only if:**
- `agentd test` passes.
- `agentd typecheck` passes.
- `xcodebuild test` passes.
- Synced-root confirmation is recorded.
- Swift access-control checklist exists for the first planned split.
- No protocol changes are included in Phase 0A.

**If any item is not satisfied:**
- Stop and either fix the baseline issue or ask for explicit approval to proceed with a known risk.

### Phase 0B — Phase-local characterization tests

Purpose: add tests immediately before the phase that needs them, not all upfront.

Tasks by later phase:
- Before Phase 1 session extraction:
  - HUD session sorting/selection/archive behavior if not already covered.
  - Voice route behavior: new voice request -> `routeTask`; selected session voice follow-up -> `followUp` with context.
- Before Phase 2 UI decomposition:
  - HUD target-frame sizing within visible-frame bounds.
  - HUD expansion/collapse shrink-delay policy.
  - Bubble layout pure calculations.
  - Multi-display screen/cursor labeling helpers where pure.
- Before Phase 4 agentd decomposition:
  - non-terminal session restore -> blocked.
  - terminal artifact materialization: report + PR URL extraction + changed files extraction.
  - waiting_for_input transition with pending extension UI request.
  - side-agent completion notifies main only once.

Exit criteria:
- Each test is added only in the PR/phase it protects.
- No broad speculative test-writing phase.

### Phase 1 — Low-risk pure extraction and folder placement

Status: completed in `1bc5c92`; low-risk module placement and pure boundaries were organized while preserving behavior.

Purpose: reduce root clutter and file size by moving independent helpers without changing behavior.

Swift tasks:
1. Move existing standalone files into target folders first, without splitting internals where possible:
   - `PickyAnalytics.swift` -> `App/`.
   - `MenuBarPanelManager.swift` -> `App/`.
   - `WindowPositionManager.swift` -> `App/` initially; reassess later if Overlay ownership is clearer.
   - `CompanionScreenCaptureUtility.swift` -> `Context/`.
   - `BuddyTranscriptionProvider.swift`, `AppleSpeechTranscriptionProvider.swift`, `GlobalPushToTalkShortcutMonitor.swift`, `BuddyAudioConversionSupport.swift` -> `Companion/Dictation/`.
   - `CompanionResponseOverlay.swift` -> `Overlay/`.
   - `PickySessionSelectionStore.swift` -> `Sessions/`.
   - `PickyArtifactReporter.swift` -> `HUD/`.
2. Rename and split session view model carefully:
   - Rename `Picky/PickySessionViewModel.swift` -> `HUD/PickySessionListViewModel.swift` because the primary class is `PickySessionListViewModel`.
   - Move notification protocols/classes to `HUD/PickySessionNotifications.swift`.
   - Move Ghostty resume protocol/launcher/error to `HUD/PickyGhosttyResumeLauncher.swift`.
   - Move `SessionCard` as nested extension to `HUD/PickySessionListViewModel+SessionCard.swift` only after access-control dry run.
   - Known risk: current `private extension PickySessionListViewModel.SessionCard` and `private extension Array` helpers may need to remain in the same file or be widened to `internal` if used across files.
3. Split `Picky/PickyContextPacket.swift`:
   - Keep Codable models/protocols in `Context/PickyContextPacket.swift`.
   - Move `PickyContextPacketAssembler` to `Context/PickyContextPacketAssembler.swift`.
   - Move `PickyAppSupport` and `PickyAppSupportScreenshotStore` to focused context/app-support files.
4. Split `Picky/PickyAgentClient.swift` only if access remains simple:
   - protocol/submission types in `AgentClient/PickyAgentClient.swift`.
   - `LocalStubPickyAgentClient` in `AgentClient/LocalStubPickyAgentClient.swift`.
   - `WebSocketPickyAgentClient` in `AgentClient/WebSocketPickyAgentClient.swift`.
5. Split `Picky/PickySettings.swift`:
   - settings model/store/view model/view into separate files if access control stays simple.
6. Split `PickySessionPolish.swift` by responsibility:
   - `PickyDiffPreview` -> `HUD/PickyDiffPreview.swift`.
   - `PickySessionArchive` -> `Sessions/PickySessionArchive.swift`.
   - `PickyFriendlyRuntimeError` and `PickyRuntimeDependencyChecker` -> `AgentClient/` or `Sessions/` depending on call sites.
7. Split `Picky/DesignSystem.swift` into token/style files without renaming the public `DS` API.

agentd tasks:
1. Run agentd pure helper extraction before high-risk Swift UI work:
   - `domain/session-status.ts`: `isTerminalStatus`.
   - `domain/session-summary.ts`: `cleanFinalAnswer`, `summaryFromFinalAnswer`.
   - `domain/session-title.ts`: `titleFromContext`.
   - `domain/artifacts.ts`: `mergeArtifacts`.
   - `domain/changed-files.ts`: `mergeChangedFiles` if cohesive.
2. Move root files into target folders when imports/tests remain trivial:
   - `handoff-tool.ts` -> `application/handoff-tool.ts`.
   - `extension-ui-bridge.ts` -> `application/extension-ui-bridge.ts` or `runtime/extension-ui-bridge.ts` after checking Pi runtime cohesion.
   - `pi-event-normalizer.ts` -> `domain/pi-event-normalizer.ts`.
   - move/update matching tests in the same PR.
3. Keep `SessionSupervisor` public API unchanged.

Exit criteria:
- Mostly file moves and pure helper extraction.
- All tests pass after each PR-sized chunk.
- No renamed public commands/protocol fields.
- Any access widening is called out explicitly in PR notes.

### Phase 2 — HUD, overlay, and panel UI decomposition

Status: completed in `eb87370` with formatting fix `984df2e`; HUD/overlay/panel rendering responsibilities were split without changing protocol or runtime behavior.

Purpose: split SwiftUI/AppKit rendering from state and panel lifecycle after phase-local characterization tests exist.

Tasks:
1. Split `Picky/PickyHUDOverlay.swift`:
   - `HUD/PickyHUDOverlayManager.swift`: `NSPanel` creation, placement, resize.
   - `HUD/PickyHUDLayoutPolicy.swift`: `PickyHUDExpansion`, `PickyHUDExpandedContentPolicy`, size helpers.
   - `HUD/PickyHUDView.swift`: session list rendering.
   - `HUD/PickySessionCardView.swift`: card header/expanded body/follow-up/action buttons.
   - `HUD/PickyToolActivityRow.swift`: tool row.
2. Split `Picky/OverlayWindow.swift` conservatively:
   - `Overlay/OverlayWindow.swift`: `NSWindow` subclass only.
   - `Overlay/OverlayWindowManager.swift`: screen overlay lifecycle.
   - `Overlay/BlueCursorView.swift`: cursor SwiftUI view.
   - `Overlay/BubbleLayout.swift`: pure layout policy.
   - `Overlay/CursorResponseViews.swift`: response/navigation bubble views.
3. Split `Picky/CompanionPanelView.swift`:
   - keep `CompanionPanelView.swift` as top-level composition.
   - extract permission rows/sections to `CompanionPanelPermissionsView.swift`.
   - extract footer/onboarding/start-button subviews only if they reduce complexity without introducing state ownership changes.
4. UI manual smoke gate:
   - Before considering a UI decomposition PR complete, ask the user for approval to launch/smoke Picky.
   - If the user declines app launch, document UI smoke as deferred risk rather than silently treating tests as enough.

Manual smoke checklist if approved:
- HUD appears top-right when sessions exist.
- Expanded card shows active tool rows and follow-up field.
- Collapse shrink delay does not clip card contents.
- Stop/report/copy/follow-up buttons remain clickable.
- Menu bar panel opens/closes and permission rows render.
- Cursor overlay appears after onboarding/permission-ready state.
- Multi-display overlay creates one overlay per display if multiple displays are available.

Exit criteria:
- Unit tests cover pure geometry/layout policies.
- Existing HUD/session tests pass.
- User-approved manual smoke is run, or deferred explicitly.

### Phase 3 — Companion and dictation responsibility split

Status: completed in `298db42` with cancellation boundary fix `9db897b`; Companion/dictation responsibilities were separated while preserving lifecycle, actor, and cancellation behavior.

Purpose: shrink `CompanionManager` without changing lifecycle or actor behavior.

Tasks:
1. Split `BuddyDictationManager.swift` first:
   - `BuddyPushToTalkShortcut.swift` for shortcut option/transition types.
   - `BuddyDictationPermissionProblem.swift` for permission problem types.
   - Keep `BuddyDictationManager` focused on audio capture/transcription lifecycle.
2. Known access-control issue:
   - `BuddyPushToTalkShortcut` currently has `fileprivate` extension helpers used by `BuddyDictationManager`.
   - Either keep those helper extensions in the same file as their callers or change them to `internal` in the same PR with tests/build verification.
3. Extract at most 2–3 concrete collaborators from `CompanionManager`:
   - `PermissionStateObserver` (`@MainActor`): permission refresh/polling only.
   - `ContextCaptureCoordinator` (async service, MainActor only where OS APIs require): screen capture + context packet assembly.
   - `AgentSubmissionCoordinator` or `AgentEventPresenter` only if tests show the boundary is useful; avoid introducing both at once.
4. Actor/lifetime rules:
   - `CompanionManager` remains `@MainActor` and owns `@Published` UI state.
   - Timer, Combine, onboarding UI state, and speech/cursor presentation remain `@MainActor`.
   - Pure assembly/network submission can be nonisolated/async only if call sites remain explicit and tested.
5. Avoid protocols unless needed for an existing or newly added test double.

Exit criteria:
- `CompanionManager` public published state remains compatible with existing views/tests.
- Voice request and voice follow-up tests pass.
- No change to permission prompts, onboarding flow, cancellation behavior, or cursor response timing.
- Any access widening is called out explicitly in PR notes.

### Phase 4 — agentd application-layer decomposition

Status: completed in `26d2a1c`; application-layer collaborators were extracted while `SessionSupervisor` remained the app-facing facade.

Purpose: keep `SessionSupervisor` as facade but move separate workflows into focused collaborators.

Tasks:
1. Extract `application/visible-session-lifecycle.ts`:
   - queued session creation.
   - runtime attach.
   - patch/upsert persistence helper if it remains a single source of truth.
2. Extract `application/main-agent-orchestrator.ts`:
   - main agent prewarm.
   - route through main agent.
   - main draft handling.
   - handoff announcement and side completion summarization.
3. Extract `application/runtime-event-handler.ts` as the single state-transition owner:
   - log, assistant_delta, status, tool, extension_ui handling.
   - It owns status changes, persistence patch timing, and emitted supervisor events.
4. Keep extension UI helper pure:
   - `extension-ui-request-mapper.ts` may map/normalize requests.
   - It must not patch session state or emit events directly.
5. Extract `application/artifact-materializer.ts`:
   - report creation, PR artifact extraction, terminal artifact patching.
6. Keep `SessionSupervisor` methods stable:
   - `load`, `list`, `get`, `route`, `create`, `followUp`, `steer`, `abort`, `answerExtensionUi`, `openArtifact`.

Exit criteria:
- Existing `session-supervisor.test.ts` still tests facade behavior.
- Focused tests added for new collaborators when behavior is not already covered.
- No protocol changes.
- Event ordering invariants are tested, not merely documented:
  - status update before terminal artifact emission.
  - waiting_for_input transition with pending request.
  - side-agent completion notification to main only once.

### Phase 5 — Optional agentd transport/runtime boundary cleanup

Status: skipped by YAGNI gate after verifier/reviewer pass; no commit was created. `server.ts` and `pi-sdk-runtime.ts` remained small/readable, and candidate helper splits did not provide enough reuse or independent test value.

Purpose: make IO boundaries explicit only where complexity justifies it.

YAGNI gate:
- Skip this phase if `server.ts` and `pi-sdk-runtime.ts` remain understandable after Phase 4.
- Extract only helpers that become reused, independently testable, or noisy.

Optional tasks:
1. Split `agentd/src/server.ts`:
   - `transport/log-fields.ts` first, because it is pure.
   - `transport/event-factory.ts` if envelope creation grows.
   - `transport/command-dispatcher.ts` only if command handling becomes hard to read.
   - Keep `websocket-server.ts` only if transport lifecycle needs independent testing.
2. Split `runtime/pi-sdk-runtime.ts`:
   - `runtime/image-options.ts` first, because it is pure.
   - `runtime/pi-sdk-session.ts` only if session wrapper grows or tests become clearer.
3. Keep `index.ts` composition clear and small.

Exit criteria:
- Existing `server.test.ts` and `pi-sdk-runtime.test.ts` pass.
- WebSocket protocol contract unchanged.
- Net complexity reduction is justified in PR notes with before/after responsibilities.

### Phase 6 — Documentation and maintenance rules

Status: completed by the documentation finalization PR; no Swift/TypeScript runtime code changes are part of this phase.

Purpose: prevent regression into giant files and unclear ownership.

Tasks:
1. Update `README.md` architecture snapshot.
2. Update `ARCHITECTURE.md` with current module boundaries.
3. Add `docs/REFACTORING.md` with:
   - responsibility map.
   - PR checklist.
   - behavior-preserving refactor rules.
   - test commands.
   - ownership map for App, Context, AgentClient, Sessions, Companion, Overlay, HUD, Settings, agentd layers.
4. Optional warning-only script:
   - line count report for Swift/TS files.
   - warning-only, not CI-blocking.

Exit criteria:
- New contributors can find where to add UI, context capture, agent client, protocol, runtime, session state, and store code.
- Maintenance checks do not block urgent hotfixes.

## Revised PR slicing recommendation

Each PR should have one responsibility and should pass tests independently.

1. Phase 0A baseline/preflight docs PR.
2. agentd pure domain helper extraction PR.
3. Swift root file folder-placement PR, no internal splits where possible.
4. Swift session view model rename/helper extraction PR.
5. Swift context extraction PR.
6. Swift agent client/settings small-file split PR.
7. Swift design-system split PR.
8. Swift HUD decomposition PR.
9. Swift overlay decomposition PR.
10. Swift companion panel decomposition PR.
11. Swift dictation extraction PR.
12. Swift CompanionManager limited collaborator extraction PR.
13. agentd SessionSupervisor application decomposition PR.
14. Optional agentd transport/runtime cleanup PR.
15. docs finalization PR.

## Non-goals for this refactor

- Do not redesign protocol fields.
- Do not introduce a new task router.
- Do not auto-generate Swift models from TS schemas yet.
- Do not change signing/package defaults.
- Do not change Pi skill/extension behavior.
- Do not restart the app as part of validation unless explicitly requested.
- Do not promote nested Swift types to top-level unless a separate API cleanup is approved.

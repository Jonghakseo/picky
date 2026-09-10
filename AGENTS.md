# AGENTS.md - Picky Maintenance Guide

## Product intent

Picky is a local-first macOS command center for Pi sessions. It captures neutral desktop context, sends it to local Pi through `picky-agentd`, and shows long-running Pickles in the Picky dock. Picky should stay thin: context capture, overlay/session UI, and session control. Pi remains responsible for interpreting intent, choosing skills/tools/MCPs, and doing the work.

## Autonomous execution

These defaults follow OpenAI's [GPT-6 Astra guidance](https://developers.openai.com/api/docs/guides/latest-model#initiative-and-follow-through) on initiative and [testing and verification](https://developers.openai.com/api/docs/guides/latest-model#testing-and-verification). They govern agent workflow, not the app's model selection or API configuration.

- Treat requests such as "I want to change..." or "can you fix..." as authorization to do the scoped work. Inspect, implement, validate, and finish without stopping at a proposal or asking whether to continue.
- Infer routine details from the code and conversation. Choose a reasonable, reversible approach and proceed. Ask only when missing information materially changes the product outcome, compatibility, data safety, or authorization and cannot be resolved from available evidence. Complete independent authorized work before asking.
- Keep autonomy within the requested scope. Do not restart the running app, change signing, perform destructive operations, push, create PRs, or publish without the required authorization. Do not add approval gates for routine local edits or focused validation.
- Use a short plan for multi-phase work; handle small, obvious changes directly. Report meaningful findings, blockers, and completion, not every tool call. Default to a concise final answer with changes, validation, and any actionable limitation.
- Read the relevant code path and nearest tests first; expand investigation only when evidence points elsewhere. Batch independent reads and searches. Delegate independent, bounded work when the time or quality benefit exceeds coordination cost; keep small, tightly coupled edits local and avoid overlapping file ownership.
- Run long commands asynchronously when supported and continue independent work. Await the actual result before claiming completion; do not busy-poll, duplicate in-flight checks, or run concurrent Xcode jobs against the same DerivedData path.
- Apply skills to the task rather than turning every task into their largest workflow. For routine test scope and permission, the policy below supersedes blanket repository guidance to always add tests or to wait for an explicit test-writing request. Keep domain-specific safety gates and higher-priority instructions. If another instruction genuinely blocks progress, cite its exact file and rule rather than silently stopping.

## Behavior-focused validation

- Before adding a test, identify the observable contract and the realistic failure it would catch. Test user-visible outcomes, public input/output, persisted state, protocol compatibility, or externally meaningful effects. A test should survive a behavior-preserving refactor.
- Do not add tests that mirror implementation, inspect source text for a particular helper, freeze private structure or SwiftUI modifier order, or recompute the expected result with the same algorithm. Call counts and ordering are valid assertions only when they are the contract, such as duplicate suppression, exactly-once dispatch, or cancellation preventing an external effect. Keep existing architecture/static guards; do not substitute them for behavior evidence.
- A code-change request authorizes necessary regression/contract tests without a separate permission round. Prefer an existing test or extend its cases; add a new test only for a meaningful coverage gap. For a bug, reproduce the reported condition and assert the corrected outcome, with a before/after check when practical. Do not create tests merely because a file changed.
- For documentation-only edits, inspect the rendered content or diff and check relevant links/commands; do not build the app or run product suites. For low-impact copy, style, or mechanical changes, use an existing focused check or direct inspection when sufficient. A small diff is not automatically low risk: routing, persistence, concurrency, permissions, and protocol changes need relevant behavioral evidence.
- Choose the smallest reliable test boundary that proves the contract. Exercise real policy/orchestration code and fake external dependencies only. Routing/state changes must reach the final persisted/rendered outcome through the production event path; an isolated helper assertion is insufficient. Protocol changes still require Swift/TypeScript compatibility checks; performance claims still require measurements.
- Before a structural refactor, establish behavior coverage for the affected invariants. Reuse existing characterization tests; add only missing cases before moving code. Do not duplicate coverage at every layer or introduce a test harness/production abstraction solely to test a trivial change.
- Start with the affected test file/suite and required domain checks. Once they pass and cover the changed behavior, stop testing and finish. Broaden or repeat only for a relevant code change, failure, uncovered risk, explicit user request, or required hook/release gate. Do not run a full suite, package build, or repeated review by habit. These limits do not bypass required checks.
- Keep validation planning proportional. For an obvious change, one sentence naming the contract and check is enough; no full Test Plan Card or approval pause is required. Report what actually executed and what it proved. A build proves compilation, a mock smoke proves the exercised mock path, and zero selected tests or a blocked launch is not a pass.

## Non-negotiable architecture rules

- Keep local-first behavior. No SaaS backend, auth, billing, remote analytics, or remote STT/TTS requirement for v1.

- Preserve long-running Pickle UX: multiple sessions, states, tool activity, logs, follow-up, abort, completion notification, artifacts, persistence/reconnect.

- Do not restart the running Picky app unless the user explicitly asks.

- Do not change Xcode defaults to always sign. Use `./scripts/package-signed-app.sh` only when a signed app bundle is needed. `Signing.xcconfig` keeps those defaults (ad-hoc, `CODE_SIGNING_ALLOWED = NO`); a developer may opt in locally by creating the git-ignored `Signing.local.xcconfig` so every Debug build shares one Apple Development identity and macOS TCC grants survive rebuilds.

## Current architecture

```text
Picky.app (SwiftUI/AppKit)
  -> WebSocket local protocol
picky-agentd (Node/TypeScript)
  -> Pi SDK runtime
local ~/.pi/agent skills/extensions/MCP/tools
```

Default daemon port is `127.0.0.1:17631`. Mock runtime is available via `PICKY_AGENTD_RUNTIME=mock`.

Packaged Picky.app bundles an arm64 Node runtime under `Contents/Resources/agentd-runtime/bin/node` and its npm CLI under `Contents/Resources/agentd-runtime/lib/node_modules/npm`; only Node is signed separately with `Picky/NodeRuntime.entitlements` for V8 JIT. The exact bundled version is pinned by `agentd/package.json#engines.node`. The launcher (`Picky/PickyAgentDaemonLauncher.swift`) resolves Node in this order:

1. `PICKY_NODE_PATH` env override (dev/debug).
2. Bundled `Resources/agentd-runtime/bin/node`.
3. `/usr/bin/env node` from inherited PATH (dev builds, `PICKY_SKIP_NODE_BUNDLE=1` packages).

Node version is single-sourced from `agentd/package.json#engines.node` (exact pin, no range). `scripts/fetch-node-runtime.sh` downloads + SHA256-verifies + caches under `build/cache/node/`. `agentd.node-preflight.json` records which source the launcher chose.

## Distribution identity

The upstream appcast URL, bundle identifier, logging subsystem, and keychain service currently use the maintainer's personal namespace (`Jonghakseo` / `com.jonghakseo.picky`). Forks or downstream distributions must replace those identifiers, Sparkle appcast URL, signing settings, and feedback Slack configuration with their own values before shipping.

## Optional Pi handoff command

Picky writes a local capability file for Pi extensions while `picky-agentd` is running:

```text
~/Library/Application Support/Picky/agentd-connection.json
```

For local development, enable the bundled handoff command by symlinking it into the local Pi extensions directory:

```bash
mkdir -p ~/.pi/agent/extensions
ln -sfn "$PWD/pi-extensions/picky-handoff" ~/.pi/agent/extensions/picky-handoff
```

After restarting Pi or running `/reload`, use:

```text
/handoff-to-picky continue this investigation in Picky and produce a final report
```

If Pi is mid-turn, the command first aborts the current turn and waits for it to settle. It then creates a new visible Pickle in Picky seeded with the current Pi session file, cwd, and recent branch excerpt as neutral context, and sends the kickoff instruction (defaults to `continue` when no argument is given) as the first user message so the Pickle resumes the work automatically.

## Code navigation index

When the user asks about a feature, start here before broad searching:

- App lifecycle / menu bar / permissions: `Picky/PickyApp.swift`, `Picky/App/`, `Picky/Companion/CompanionPanel*.swift`
- Settings / default cwd / local paths: `Picky/App/Settings/`, `Picky/App/Settings/PickySettingsStore.swift`
- Voice / push-to-talk / dictation: `Picky/CompanionManager.swift`, `Picky/BuddyDictationManager.swift`, `Picky/Companion/Dictation/`
- Global shortcut semantics/settings: `Picky/Shortcuts/`, `Picky/Companion/Dictation/GlobalPushToTalkShortcutMonitor.swift`, `Picky/Companion/Dictation/BuddyPushToTalkShortcut.swift`, `Picky/QuickInput/QuickInputDoubleTapDetector.swift`
- Quick text input: `Picky/QuickInput/`
- Speech transcription/playback providers: `Picky/Companion/Dictation/AppleSpeechTranscriptionProvider.swift`, `Picky/Companion/Dictation/BuddyTranscriptionProvider.swift`, `Picky/Companion/AzureOpenAI/`, `Picky/Companion/ElevenLabs/`, `Picky/Companion/Speech/`
- Screen/context capture: `Picky/Context/`, `Picky/PickyAdvancedContext.swift`, `Picky/Context/PickyContextPacketAssembler.swift`
- HUD shell / dock / Pickle container: `Picky/HUD/`, `Picky/HUD/PickyHUDView.swift`, `Picky/PickySessionViewModel.swift`
- HUD dock rail / dock icon / size reporting / recent-folder picker: `Picky/HUD/PickyHUDDockRailView.swift`, `Picky/HUD/PickyHUDDockIconView.swift`, `Picky/HUD/PickyHUDSizeReporting.swift`, `Picky/HUD/PickyRecentPickleFolderPicker.swift`
- HUD presentation policies (status tone, artifact badges, slash-command autocomplete): `Picky/HUD/PickySessionStatusPresentation.swift`, `Picky/HUD/PickyArtifactPresentation.swift`, `Picky/HUD/PickySlashCommandAutocompletePolicy.swift`
- Conversation card UI: `Picky/HUD/Conversation/`, particularly `PickyConversationCardView`, `PickyConversationListView`, `PickyConversationComposerView`, `PickyConversationMenu`
- Conversation bubble components: `Picky/HUD/Conversation/Bubbles/`
- Session selection/archive state: `Picky/Sessions/PickySessionSelectionStore.swift`, `Picky/Sessions/`
- Pi terminal overlay / resume command: `Picky/Sessions/PickyTerminalOverlay.swift`, `Picky/PickySessionViewModel.swift`, search `openTerminalOverlay` or `copyTerminalResumeCommand`
- Interaction state/effects: `Picky/Interaction/`
- Per-Pickle daemon topology and session ownership rules: `docs/per-pickle-daemon-topology.md`, `Picky/Sessions/Projection/PickyProjectionOwnershipLedger.swift`, `Picky/PickyAgentDaemonPool.swift`
- Pointer overlay validation/resolution: `Picky/PointerOverlay/`, `agentd/src/application/pointer-overlay-request.ts`, `agentd/src/application/overlay-context-resolver.ts`, `agentd/src/domain/pointer-validation.ts`
- App-daemon protocol/client: `Picky/PickyAgentProtocol.swift`, `Picky/PickyAgentClient.swift`, `Picky/PickyAgentClientRouter.swift`, `Picky/PickyAgentDaemonLauncher.swift`, `Picky/PickyAgentDaemonPool.swift`
- agentd entry/composition: `agentd/src/index.ts`
- agentd WebSocket protocol handling: `agentd/src/server.ts`, `agentd/src/protocol.ts`
- agentd session lifecycle/orchestration: `agentd/src/session-supervisor.ts` (Pickle sessions), `agentd/src/application/main-agent-coordinator.ts` (always-on main agent: handle lifecycle, turn/interrupt guards, idle compaction, Pickle completion delivery), `agentd/src/session-store.ts`
- Backend message journal / source mapping: `agentd/src/session-message-builder.ts`, `agentd/src/domain/log-prefixes.ts`
- Tool categorizer/activity counts: `agentd/src/domain/tool-categorizer.ts`, `agentd/src/domain/tool-activity.ts`
- Session policy helpers (user bash format, slash commands, pi session files, handoff pin, main-agent limits): `agentd/src/domain/user-bash-format.ts`, `agentd/src/domain/slash-commands.ts`, `agentd/src/domain/pi-session-files.ts`, `agentd/src/domain/pickle-handoff-context.ts`, `agentd/src/domain/main-agent-policy.ts`, `agentd/src/domain/queue-policy.ts`
- agentd prompt/context construction: `agentd/src/prompt-builder.ts`, `contracts/prompts/`, `contracts/context/`
- Main-agent standing rules (Picky CLI, visual overlay DSL, TTS reply style): `agentd/src/domain/picky-runtime-contract.ts`, attached to Pi's system prompt every turn by `agentd/src/runtime/picky-runtime-contract-extension.ts` and wired in `agentd/src/bootstrap.ts`. Never move these back into `buildMainAgentBootstrapPair`: anything in a transcript message is dropped the first time Pi compacts the session.
- Pi SDK runtime adapter: `agentd/src/runtime/pi-sdk-runtime.ts`, `agentd/src/runtime/types.ts`, `agentd/src/runtime/mock-runtime.ts`
- Picky CLI / main-agent delegation: `agentd/src/cli.ts`, `agentd/src/application/internal-picky-cli.ts`, `agentd/src/server.ts`
- Pickle interactive input bridge: `agentd/src/runtime/ask-user-question-tool.ts`, `agentd/src/runtime/extension-ui-bridge.ts`
- Pi SDK adapters (tools, extension UI, OAuth, package manager, RPC runner): `agentd/src/runtime/`. Only `runtime/` and `bootstrap.ts` may import `@earendil-works/*`; application code depends on `agentd/src/runtime/types.ts` (guard-enforced)
- Pi session sync: `agentd/src/application/pi-session-syncer.ts`
- Artifacts/reports/changed files: `agentd/src/artifact-store.ts`, `agentd/src/domain/`, `Picky/HUD/PickyArtifactReporter.swift`, `Picky/HUD/PickyReportViewer.swift`
- Pi extension handoff command: `pi-extensions/picky-handoff/`
- HUD perf instrumentation / profiling playbook: `Picky/Feedback/PickyPerf.swift`, `docs/perf-profiling.md` (use this before guessing at HUD lag root causes)
- Swift Concurrency guidelines (MainActor-first, measure before optimizing, GCD migration): `docs/swift-concurrency.md` (follow this when adding/refactoring async Swift code)
- Refactoring principles and safety gates: `docs/refactoring-principles.md` (follow this before structural splits; establish characterization coverage first, reusing existing tests where sufficient, extract pure policies before splitting facades, keep line-count checks warning-first, and preserve the Picky neutral-context / Pi-intent boundary)
- Tests for Swift UI/session/voice: `PickyTests/PickySessionViewModelTests.swift`, `PickyTests/PickyCompanionManagerTests.swift`, `PickyTests/PickyAgentClientTests.swift`
- Tests for agentd/session/runtime: `agentd/src/*.test.ts`, especially `session-supervisor.test.ts`, `runtime/pi-sdk-runtime.test.ts`

## Fast investigation workflow

1. Use the code navigation index above to pick likely files.
2. Run `rg -n "exact term|symbol|UI label" <likely paths>` before opening large files.
3. For Swift UI behavior, check both the View and `PickySessionViewModel`/store that backs it.
4. For voice behavior, check the hotkey snapshot moment in `CompanionManager` and the routing method that sends `followUp` vs `submit`.
5. For daemon behavior, trace `server.ts -> session-supervisor.ts -> runtime/* -> prompt-builder.ts`.
6. Before editing, run `git status --short` and protect unrelated user changes.
7. For daemon debugging, check `~/Library/Application Support/Picky/Logs/agentd.stdout.log` and `agentd.stderr.log`; launcher lifecycle messages are printed to the app console with `Picky agentd launcher`.
8. When an issue matches a known operational procedure, follow the runbooks under `runbook/` first: `runbook/log-debugging.md` (session hang/crash log investigation). When the user asks to release ("release" / "릴리즈"), follow `runbook/release.md` end-to-end without extra confirmation. New release tags use `X.Y.Z-beta.N` for beta and plain `X.Y.Z` for stable; historical plain-number beta and `*-stable` tags remain untouched.
9. When editing `.github/workflows/beta-notarized-release.yml`, preserve its split checkout: build/package source comes from the target release tag, while release-policy helpers and their tests come from the repository default branch. Do not move current policy-helper execution onto the historical target checkout because legacy tags may not contain those files.
10. For routing/state bugs, trace the value through every boundary to the persisted and rendered result; do not stop at the first plausible UI cause. Verify the exact production event path (for example, v1 vs v2) and test the final invariant, not only intermediate callbacks.

## Build, test, package

Choose commands for the affected surface; this is a reference, not a checklist. Install dependencies only when missing or changed. Apply the Xcode toolchain and shared DerivedData settings below to every agent-driven Xcode command.

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test
cd agentd && pnpm install
cd agentd && pnpm run test:ci
cd agentd && pnpm run build
./scripts/package-signed-app.sh
```

Use targeted tests while iterating, for example:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickyCompanionManagerTests
```

For a targeted `xcodebuild test` run, treat exit 0 or `** TEST SUCCEEDED **` as validation only when the output or `.xcresult` confirms that the intended test or tests executed. If a method-level selector is uncertain or selects no tests, enumerate the containing suite and copy the exact returned identifier, including `()` when present, or rerun the containing suite. When chaining `test` and `build` in one shell, capture the `xcodebuild test` exit status immediately and propagate it as the final status; a later successful build must not mask `** TEST FAILED **`.

If `xcodebuild test` fails with `IDELaunchErrorDomain` Code 20 (`Could not launch “PickyTests”`), the selected tests did not execute. Report that failure as-is; do not retry with changed signing settings, and never present supplementary checks as a test pass. Verified fallbacks, each labeled explicitly as partial validation only: (a) `xcodebuild ... build` with the same `-derivedDataPath` proves compilation only; (b) `build-for-testing` plus a temporary `@testable import Picky` Swift harness linked against the built `Picky.debug.dylib`, with rpaths for the app executable directory and `Picky.app/Contents/Frameworks`, validates pure policy/model contracts only.

When piping `xcodebuild` through `tee`, preserve the primary command status before running log extraction. `set -o pipefail` alone is insufficient when a later `rg` or `tail` becomes the shell's final command. Use this shape so a failed build/test remains a failed tool call while bounded evidence is still printed:

```bash
set -o pipefail
set +e
xcodebuild ... 2>&1 | tee "$LOG"
xcode_status=${PIPESTATUS[0]}
set -e
rg -n "TEST SUCCEEDED|TEST FAILED|intended-test-name" "$LOG" || true
exit "$xcode_status"
```

WindowServer-dependent tests are disabled during ordinary local Xcode and pre-push runs. They run exactly once per fresh test host only through GitHub-hosted `.github/workflows/isolated-ui-tests.yml`, which invokes the pre-push script's UI-effect mode with its `TEST_RUNNER_` opt-in. Do not set that variable or invoke UI-effect/performance modes for ad-hoc local commands. See `docs/test-desktop-isolation.md`.

Build with **Xcode 16.3** (`/Applications/Xcode.app`). Xcode 26.3 miscompiles the implicit isolated `deinit` that `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` produces: Release crashes `swift-frontend`, and Debug builds corrupt the heap so the app and the XCTest host die with `SIGBUS`. If `xcode-select -p` points elsewhere, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` rather than changing the global setting. Details and the open blocker are in `docs/known-issues/xcode-26-3-isolated-deinit.md`. Use a toolchain-specific `-derivedDataPath` when comparing Xcode versions; reusing one across versions fails to link.

Agent-driven `xcodebuild` runs use `-derivedDataPath /private/tmp/PickyAgentDD` and **reuse that one path across runs**. Staying out of Xcode's default DerivedData avoids build-DB lock collisions with a developer's GUI builds, and reusing a single path keeps rebuilds incremental. A fresh `mktemp` directory per run costs a full cold build instead (roughly 10 minutes and 2 GB every time), which is why per-run isolation is not the default.

Switch to a unique path (`mktemp -d /private/tmp/Picky<purpose>DD.XXXXXX`) only when the shared agent path is actually unavailable: another `xcodebuild` is already running (`pgrep -x xcodebuild`), or a run just failed with a build-DB lock collision (exit 65). Keep the `Picky` prefix and `/private/tmp` root so `scripts/prune-build-artifacts.sh` can recover the path later.

A *unique* path is owned by the run that created it and must be torn down when that run finishes; `/private/tmp/PickyAgentDD` is meant to persist and must be left in place. Recursively unregister a directory **before** deleting it, because Picky.app embeds Sparkle's separately registered Updater.app and LaunchServices cannot unregister bundles after their paths disappear:

```bash
DD="$(mktemp -d /private/tmp/PickyVerifyDD.XXXXXX)"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u -R "$DD"
rm -rf "$DD"
```

Skipping this is not cosmetic. Each abandoned DerivedData directory keeps roughly 1 GB on disk and leaves a permanent LaunchServices bundle record; accumulated records drive `launchservicesd` into sustained high CPU and starve the Picky main thread, which surfaces as HUD lag with no matching hot path in the app itself. Reusing the shared path also helps here: it keeps a single bundle record that gets overwritten rather than one record per run. Use `./scripts/prune-build-artifacts.sh` to reclaim directories that earlier runs abandoned; it protects anything modified within `--keep-hours` (default 24), so an in-flight or recently used shared path is not at risk.

When an agentd vitest run fails, inspect the failure and its connection to the changed behavior before editing code. If it appears intermittent, rerun the failing file once in isolation. Escalate to `--no-file-parallelism` only to investigate suspected cross-file interference; compare the same failing case against the pre-change baseline in a temporary worktree only when attribution remains unresolved. A failure reproduced on the baseline is evidence of a pre-existing issue, not proof that the change caused it. Do not automatically repeat full suites or baseline runs three times. Report unresolved flakiness without calling it a pass, do not fix unrelated failures, and remove any temporary worktree afterwards.

Committing from a temp worktree runs this repo's commit hooks, which need both the root and `agentd` dependency trees. If the worktree has no installed dependencies, symlink both from the primary worktree before committing and remove the links afterwards (linking only `agentd/node_modules` is not enough; root `commitlint` is also required). Skip this when the worktree has its own installed dependencies or their versions may diverge from the hooks' expectations:

```bash
ln -sfn "$MAIN/node_modules" node_modules
ln -sfn "$MAIN/agentd/node_modules" agentd/node_modules
git commit ...
rm node_modules agentd/node_modules
```

Daemon protocol changes (event ordering, bootstrap sequences) can be smoke-tested without touching the running Picky.app: launch a throwaway agentd on a non-default port with `PICKY_AGENTD_PORT=<port> PICKY_AGENTD_RUNTIME=mock PICKY_APP_SUPPORT_DIR=<tmp-dir>`, connect a scripted WebSocket client (register capabilities, assert frame order), then tear it down. Never attach to or restart the user's live daemon for this.

Runtime smoke for packaged app:

```bash
PICKY_AGENTD_RUNTIME=mock PICKY_AGENTD_ROOT="$PWD/agentd" build/package/export/Picky.app/Contents/MacOS/Picky
```

Expected: `picky-agentd listening on 127.0.0.1:17631`; quitting the app closes the daemon/port.

## Implementation guidance

- Prefer small, focused changes. Add/update nearby tests only when they protect a meaningful behavior gap, following Behavior-focused validation above.
- Keep context packets neutral: transcript, app/window, browser URL/title/selection, screenshots, cwd, selected session.
- Follow-up routing must be explicit and predictable; avoid surprising session capture.
- Extension UI and confirmation flows should remain visible in the HUD, not hidden in logs.
- When committing, include only your own changes. Never stage unrelated local edits.
- Commit messages must pass commitlint Conventional Commits in English/ASCII only, e.g. `feat: add dock shortcut`.

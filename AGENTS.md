# AGENTS.md - Picky Maintenance Guide

## Product intent

Picky is a local-first macOS command center for Pi sessions. It captures neutral desktop context, sends it to local Pi through `picky-agentd`, and shows long-running Pickles in the Picky dock. Picky should stay thin: context capture, overlay/session UI, and session control. Pi remains responsible for interpreting intent, choosing skills/tools/MCPs, and doing the work.

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

Packaged Picky.app bundles a pinned Node 22.x arm64 runtime under `Contents/Resources/agentd-runtime/bin/node` and its npm CLI under `Contents/Resources/agentd-runtime/lib/node_modules/npm`; only Node is signed separately with `Picky/NodeRuntime.entitlements` for V8 JIT. The launcher (`Picky/PickyAgentDaemonLauncher.swift`) resolves Node in this order:

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
- Pointer overlay validation/resolution: `Picky/PointerOverlay/`, `agentd/src/application/pointer-tool.ts`
- App-daemon protocol/client: `Picky/PickyAgentProtocol.swift`, `Picky/PickyAgentClient.swift`, `Picky/PickyAgentClientRouter.swift`, `Picky/PickyAgentDaemonLauncher.swift`, `Picky/PickyAgentDaemonPool.swift`
- agentd entry/composition: `agentd/src/index.ts`
- agentd WebSocket protocol handling: `agentd/src/server.ts`, `agentd/src/protocol.ts`
- agentd session lifecycle/orchestration: `agentd/src/session-supervisor.ts`, `agentd/src/session-store.ts`
- Backend message journal / source mapping: `agentd/src/session-message-builder.ts`, `agentd/src/domain/log-prefixes.ts`
- Tool categorizer/activity counts: `agentd/src/domain/tool-categorizer.ts`, `agentd/src/domain/tool-activity.ts`
- Session policy helpers (user bash format, slash commands, pi session files, handoff pin, main-agent limits): `agentd/src/domain/user-bash-format.ts`, `agentd/src/domain/slash-commands.ts`, `agentd/src/domain/pi-session-files.ts`, `agentd/src/domain/pickle-handoff-context.ts`, `agentd/src/domain/main-agent-policy.ts`, `agentd/src/domain/queue-policy.ts`
- agentd prompt/context construction: `agentd/src/prompt-builder.ts`, `contracts/prompts/`, `contracts/context/`
- Pi SDK runtime adapter: `agentd/src/runtime/pi-sdk-runtime.ts`, `agentd/src/runtime/types.ts`, `agentd/src/runtime/mock-runtime.ts`
- Picky CLI / main-agent delegation: `agentd/src/cli.ts`, `agentd/src/application/internal-picky-cli.ts`, `agentd/src/server.ts`
- Pickle interactive input bridge: `agentd/src/application/ask-user-question-tool.ts`, `agentd/src/application/extension-ui-bridge.ts`
- Pi session sync: `agentd/src/application/pi-session-syncer.ts`
- Artifacts/reports/changed files: `agentd/src/artifact-store.ts`, `agentd/src/domain/`, `Picky/HUD/PickyArtifactReporter.swift`, `Picky/HUD/PickyReportViewer.swift`
- Pi extension handoff command: `pi-extensions/picky-handoff/`
- HUD perf instrumentation / profiling playbook: `Picky/Feedback/PickyPerf.swift`, `docs/perf-profiling.md` (use this before guessing at HUD lag root causes)
- Swift Concurrency guidelines (MainActor-first, measure before optimizing, GCD migration): `docs/swift-concurrency.md` (follow this when adding/refactoring async Swift code)
- Refactoring principles and safety gates: `docs/refactoring-principles.md` (follow this before structural splits; write characterization tests first, extract pure policies before splitting facades, keep line-count checks warning-first, and preserve the Picky neutral-context / Pi-intent boundary)
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

For a targeted `xcodebuild test` run, treat exit 0 or `** TEST SUCCEEDED **` as validation only when the output or `.xcresult` confirms that the intended test or tests executed. If a method-level selector is uncertain or selects no tests, enumerate the containing suite and copy the exact returned identifier, including `()` when present, or rerun the containing suite.

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

WindowServer-dependent tests are disabled during ordinary Xcode test runs. They may run exactly once through `scripts/pre-push-checks.sh`, which owns the `PICKY_PRE_PUSH_UI_EFFECT_TESTS=1` opt-in. Do not set that variable for ad-hoc or repeated test commands.

Parallel or subagent-driven `xcodebuild test` runs must use a unique `-derivedDataPath` under `/private/tmp` (for example `/private/tmp/Picky<purpose>DD`); the shared default DerivedData causes build-DB lock collisions (exit 65) when another build is running concurrently. Keeping the `Picky` prefix and `/private/tmp` root lets `scripts/prune-build-artifacts.sh` recover an abandoned path after an interrupted run.

A temporary `-derivedDataPath` is owned by the run that created it and must be torn down when that run finishes. Recursively unregister the directory **before** deleting it, because Picky.app embeds Sparkle's separately registered Updater.app and LaunchServices cannot unregister bundles after their paths disappear:

```bash
DD="$(mktemp -d /private/tmp/PickyVerifyDD.XXXXXX)"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u -R "$DD"
rm -rf "$DD"
```

Skipping this is not cosmetic. Each abandoned DerivedData directory keeps roughly 1 GB on disk and leaves a permanent LaunchServices bundle record; accumulated records drive `launchservicesd` into sustained high CPU and starve the Picky main thread, which surfaces as HUD lag with no matching hot path in the app itself. Use `./scripts/prune-build-artifacts.sh` to reclaim directories that earlier runs abandoned.

When the full agentd vitest suite fails intermittently, classify before touching code: (1) rerun the failing file alone, (2) rerun the suite with `--no-file-parallelism`, (3) reproduce on a clean HEAD temp worktree (`git worktree add /tmp/picky-verify-<n> HEAD`) three times. Only a failure that survives all three steps implicates the changeset. Remove temp worktrees afterwards.

Daemon protocol changes (event ordering, bootstrap sequences) can be smoke-tested without touching the running Picky.app: launch a throwaway agentd on a non-default port with `PICKY_AGENTD_PORT=<port> PICKY_AGENTD_RUNTIME=mock PICKY_APP_SUPPORT_DIR=<tmp-dir>`, connect a scripted WebSocket client (register capabilities, assert frame order), then tear it down. Never attach to or restart the user's live daemon for this.

Runtime smoke for packaged app:

```bash
PICKY_AGENTD_RUNTIME=mock PICKY_AGENTD_ROOT="$PWD/agentd" build/package/export/Picky.app/Contents/MacOS/Picky
```

Expected: `picky-agentd listening on 127.0.0.1:17631`; quitting the app closes the daemon/port.

## Implementation guidance

- Prefer small, focused changes and add/update tests near the touched code.
- Keep context packets neutral: transcript, app/window, browser URL/title/selection, screenshots, cwd, selected session.
- Follow-up routing must be explicit and predictable; avoid surprising session capture.
- Extension UI and confirmation flows should remain visible in the HUD, not hidden in logs.
- When committing, include only your own changes. Never stage unrelated local edits.
- Commit messages must pass commitlint Conventional Commits in English/ASCII only, e.g. `feat: add dock shortcut`.

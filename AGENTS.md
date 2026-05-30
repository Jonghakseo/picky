# AGENTS.md - Picky Maintenance Guide

## Product intent

Picky is a local-first macOS command center for Pi sessions. It captures neutral desktop context, sends it to local Pi through `picky-agentd`, and shows long-running Pickles in the Picky dock. Picky should stay thin: context capture, overlay/session UI, and session control. Pi remains responsible for interpreting intent, choosing skills/tools/MCPs, and doing the work.

## Non-negotiable architecture rules

- Keep local-first behavior. No SaaS backend, auth, billing, remote analytics, or remote STT/TTS requirement for v1.

- Preserve long-running Pickle UX: multiple sessions, states, tool activity, logs, follow-up, abort, completion notification, artifacts, persistence/reconnect.

- Do not restart the running Picky app unless the user explicitly asks.

- Do not change Xcode defaults to always sign. Use `./scripts/package-signed-app.sh` only when a signed app bundle is needed.

## Current architecture

```text
Picky.app (SwiftUI/AppKit)
  -> WebSocket local protocol
picky-agentd (Node/TypeScript)
  -> Pi SDK runtime
local ~/.pi/agent skills/extensions/MCP/tools
```

Default daemon port is `127.0.0.1:17631`. Mock runtime is available via `PICKY_AGENTD_RUNTIME=mock`.

Packaged Picky.app bundles a pinned Node 22.x arm64 runtime under `Contents/Resources/agentd-runtime/bin/node`, signed separately with `Picky/NodeRuntime.entitlements` for V8 JIT. The launcher (`Picky/PickyAgentDaemonLauncher.swift`) resolves Node in this order:

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
- OpenAI Realtime voice mode (opt-in): `Picky/Companion/Realtime/`, `agentd/src/runtime/openai-realtime-main-runtime.ts`, `agentd/src/runtime/selectable-main-runtime.ts`, runtime selection in `agentd/src/bootstrap.ts`
- Screen/context capture: `Picky/Context/`, `Picky/PickyAdvancedContext.swift`, `Picky/Context/PickyContextPacketAssembler.swift`
- HUD shell / dock / Pickle container: `Picky/HUD/`, `Picky/HUD/PickyHUDView.swift`, `Picky/PickySessionViewModel.swift`
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
- agentd prompt/context construction: `agentd/src/prompt-builder.ts`, `contracts/prompts/`, `contracts/context/`
- Pi SDK runtime adapter: `agentd/src/runtime/pi-sdk-runtime.ts`, `agentd/src/runtime/types.ts`, `agentd/src/runtime/mock-runtime.ts`, `agentd/src/runtime/selectable-main-runtime.ts`
- Picky/Pickle session tools: `agentd/src/application/handoff-tool.ts`
- Pickle interactive input bridge: `agentd/src/application/ask-user-question-tool.ts`, `agentd/src/application/extension-ui-bridge.ts`
- Pi session sync: `agentd/src/application/pi-session-syncer.ts`
- Artifacts/reports/changed files: `agentd/src/artifact-store.ts`, `agentd/src/domain/`, `Picky/HUD/PickyArtifactReporter.swift`, `Picky/HUD/PickyReportViewer.swift`
- Pi extension handoff command: `pi-extensions/picky-handoff/`
- HUD perf instrumentation / profiling playbook: `Picky/Feedback/PickyPerf.swift`, `docs/perf-profiling.md` (use this before guessing at HUD lag root causes)
- Swift Concurrency guidelines (MainActor-first, measure before optimizing, GCD migration): `docs/swift-concurrency.md` (follow this when adding/refactoring async Swift code)
- Tests for Swift UI/session/voice: `PickyTests/PickySessionViewModelTests.swift`, `PickyTests/PickyCompanionManagerTests.swift`, `PickyTests/PickyAgentClientTests.swift`
- Tests for agentd/session/runtime: `agentd/src/*.test.ts`, especially `session-supervisor.test.ts`, `runtime/pi-sdk-runtime.test.ts`

## Fast investigation workflow

1. Use the code navigation index above to pick likely files.
2. Run `rg -n "exact term|symbol|UI label" <likely paths>` before opening large files.
3. For Swift UI behavior, check both the View and `PickySessionViewModel`/store that backs it.
4. For voice behavior, check the hotkey snapshot moment in `CompanionManager` and the routing method that sends `followUp` vs `submit`. For Realtime mode, also check `Picky/Companion/Realtime/` and the runtime selection in `agentd/src/bootstrap.ts` / `agentd/src/runtime/selectable-main-runtime.ts`.
5. For daemon behavior, trace `server.ts -> session-supervisor.ts -> runtime/* -> prompt-builder.ts`.
6. Before editing, run `git status --short` and protect unrelated user changes.
7. For daemon debugging, check `~/Library/Application Support/Picky/Logs/agentd.stdout.log` and `agentd.stderr.log`; launcher lifecycle messages are printed to the app console with `Picky agentd launcher`.

## Build, test, package

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test
cd agentd && pnpm install
cd agentd && pnpm test
cd agentd && pnpm run build
./scripts/package-signed-app.sh
```

Use targeted tests while iterating, for example:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickyCompanionManagerTests
```

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

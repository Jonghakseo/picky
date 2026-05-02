# AGENTS.md - Picky Maintenance Guide

## Product intent

Picky is a local-first macOS command center for Pi sessions. It captures neutral desktop context, sends it to local Pi through `picky-agentd`, and shows long-running side agents in a compact top-right HUD. Picky should stay thin: context capture, overlay/session UI, and session control. Pi remains responsible for interpreting intent, choosing skills/tools/MCPs, and doing the work.

## Non-negotiable architecture rules

- Do not add deterministic workflow routing in Picky. No `if Sentry URL then Sentry flow`, `if Slack URL then Slack flow`, etc.
- Do not duplicate Pi skills, MCP bridge, or task intelligence in Picky.
- Keep local-first behavior. No SaaS backend, auth, billing, remote analytics, or remote STT/TTS requirement for v1.
- Preserve long-running agent UX: multiple sessions, states, tool activity, logs, follow-up, abort, completion notification, artifacts, persistence/reconnect.
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

## Code navigation index

When the user asks about a feature, start here before broad searching:

- App lifecycle / menu bar / permissions: `Picky/PickyApp.swift`, `Picky/App/`, `Picky/Companion/CompanionPanel*.swift`
- Settings / default cwd / local paths: `Picky/App/Settings/`, `Picky/App/Settings/PickySettingsStore.swift`
- Voice / push-to-talk / dictation: `Picky/CompanionManager.swift`, `Picky/BuddyDictationManager.swift`, `Picky/Companion/Dictation/`
- Global hotkey semantics: `Picky/Companion/Dictation/GlobalPushToTalkShortcutMonitor.swift`, `Picky/Companion/Dictation/BuddyPushToTalkShortcut.swift`
- Speech transcription provider: `Picky/Companion/Dictation/AppleSpeechTranscriptionProvider.swift`, `Picky/Companion/Dictation/BuddyTranscriptionProvider.swift`
- Screen/context capture: `Picky/Context/`, `Picky/PickyAdvancedContext.swift`, `Picky/Context/PickyContextPacketAssembler.swift`
- HUD / side agent cards / follow-up UI: `Picky/HUD/`, `Picky/HUD/PickyHUDView.swift`, `Picky/PickySessionViewModel.swift`
- Session selection/archive state: `Picky/Sessions/PickySessionSelectionStore.swift`, `Picky/Sessions/`
- Ghostty resume / terminal handoff: `Picky/PickySessionViewModel.swift`, search `PickyGhosttyResumeLauncher`
- App-daemon protocol/client: `Picky/PickyAgentProtocol.swift`, `Picky/PickyAgentClient.swift`, `Picky/PickyAgentDaemonLauncher.swift`
- agentd entry/composition: `agentd/src/index.ts`
- agentd WebSocket protocol handling: `agentd/src/server.ts`, `agentd/src/protocol.ts`
- agentd session lifecycle/orchestration: `agentd/src/session-supervisor.ts`, `agentd/src/session-store.ts`
- agentd prompt/context construction: `agentd/src/prompt-builder.ts`, `contracts/prompts/`, `contracts/context/`
- Pi SDK runtime adapter: `agentd/src/runtime/pi-sdk-runtime.ts`, `agentd/src/runtime/types.ts`, `agentd/src/runtime/mock-runtime.ts`
- Main-agent side-session tools: `agentd/src/application/handoff-tool.ts`
- Artifacts/reports/changed files: `agentd/src/artifact-store.ts`, `agentd/src/domain/`, `Picky/PickySessionReport.swift`
- Pi extension handoff command: `pi-extensions/picky-handoff/`
- Tests for Swift UI/session/voice: `PickyTests/PickySessionViewModelTests.swift`, `PickyTests/PickyCompanionManagerTests.swift`, `PickyTests/PickyAgentClientTests.swift`
- Tests for agentd/session/runtime: `agentd/src/*.test.ts`, especially `session-supervisor.test.ts`, `runtime/pi-sdk-runtime.test.ts`

## Fast investigation workflow

1. Use the code navigation index above to pick likely files.
2. Run `rg -n "exact term|symbol|UI label" <likely paths>` before opening large files.
3. For Swift UI behavior, check both the View and `PickySessionViewModel`/store that backs it.
4. For voice behavior, check the hotkey snapshot moment in `CompanionManager` and the routing method that sends `followUp` vs `submit`.
5. For daemon behavior, trace `server.ts -> session-supervisor.ts -> runtime/* -> prompt-builder.ts`.
6. Before editing, run `git status --short` and protect unrelated user changes.

## Build, test, package

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
cd agentd && npm test
cd agentd && npm run build
./scripts/package-signed-app.sh
```

Use targeted tests while iterating, for example:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test -only-testing:PickyTests/PickyCompanionManagerTests
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

# Picky Current Architecture

_Last updated: 2026-05-06_

## 1. Product shape

Picky is a local-first macOS command center for Pi sessions. It is not a generic chat app and it should not become a workflow router. The app captures neutral desktop context, sends it to local Pi through `picky-agentd`, and renders long-running Pickles in the Picky dock.

Core principle:

```text
Picky captures context and manages session UX.
Pi interprets intent and chooses skills, extensions, MCPs, and tools.
```

## 2. Non-negotiable rules

- Do not hard-code task routing in Picky. No URL/app-name rules such as "Sentry URL => Sentry flow".
- Do not duplicate Pi skills, MCP bridge behavior, or tool policy in Picky.
- Keep local-first behavior. No SaaS backend, auth, billing, remote analytics, or remote STT/TTS requirement for v1.
- Long-running agents are first-class: multiple sessions, statuses, tool activity, logs, follow-up, abort, notifications, artifacts, persistence/reconnect.
- Do not restart the running Picky app unless the user explicitly asks.
- Do not change Xcode project defaults to always sign. Use `./scripts/package-signed-app.sh` when a signed local app bundle is needed.

## 3. Runtime architecture

```text
Picky.app (SwiftUI/AppKit)
  - menu bar app, push-to-talk, context capture, HUD, settings
  - WebSocket client + child-process daemon launcher
        |
        | local WebSocket protocol, default 127.0.0.1:17631
        v
picky-agentd (Node/TypeScript)
  - command/event transport, session supervision, Pi SDK runtime adapter
  - metadata, artifacts, reports, extension UI bridge
        |
        | Pi SDK runtime
        v
local Pi environment
  - ~/.pi/agent settings, skills, extensions, MCP bridge, tools, memory
```

`picky-agentd` runs as a child process of `Picky.app` for the current MVP. It writes connection info under Picky app support so Pi extensions can discover the running daemon.

## 4. Main data flows

### New voice/text task

1. User invokes Picky by a configurable push-to-talk shortcut or quick-input shortcut. Defaults are `Control+Option` for voice and double-tap `Control` for text entry.
2. `Picky.app` captures transcript, active app/window, browser context, selected text, screenshots, cwd, and optional selected session.
3. App sends `routeTask`/`createTask` to `picky-agentd`.
4. If Picky mode is enabled, daemon routes through the always-on Picky runtime. Simple requests can receive `quickReply`; complex work is delegated through `picky_start_pickle` to a visible Pickle session.
5. Pickle session runs through Pi SDK; daemon normalizes runtime events into HUD events.

### Follow-up

- Text follow-up from a HUD card sends `followUp(sessionId, text)`.
- Voice follow-up uses an explicit target snapshot at hotkey press time. Priority is: active voice target, hovered HUD card voice target, otherwise new/main request.
- Follow-up context source is `voice-follow-up` or `text-follow-up` when a session target is known.

### Extension UI

Pi extension UI requests are surfaced as native HUD input. A session enters `waiting_for_input`, stores the pending request, and resumes after the app sends `answerExtensionUi`.

### Artifacts

Terminal/completed sessions materialize durable artifacts: final answer/report markdown, PR URLs, changed files, logs, screenshots, and opened artifact paths.

## 5. Picky.app responsibility map

Current Swift source is intentionally partially decomposed. Some large root files remain until a split clearly reduces complexity.

```text
Picky/
  PickyApp.swift                         app entry and lifecycle
  AppBundleConfiguration.swift           bundle/config helpers
  DesignSystem.swift                     DS tokens, styles, view helpers (deferred split)
  PickyAgentProtocol.swift               Codable app-daemon protocol models
  PickyAgentClient.swift                 client protocol + WebSocket/stub pieces (deferred split)
  PickyAgentDaemonLauncher.swift         child-process daemon launch/stop
  PickyAdvancedContext.swift             browser/window/selection providers
  CompanionManager.swift                 voice pipeline orchestration and event presentation
  BuddyDictationManager.swift            audio capture + transcription lifecycle
  CompanionPanelView.swift               menu panel composition
  PickySessionViewModel.swift            HUD session state facade (deferred rename/split)
  PickyAskUserQuestionForm.swift         extension UI form rendering

  App/
    MenuBarPanelManager.swift            menu bar panel lifecycle
    PickyAnalytics.swift                 local logging/analytics shim
    PickyExtensionInstaller.swift        opt-in bundled Pi extension installer
    PickySkillInstaller.swift            opt-in bundled Picky skill installer
    WindowPositionManager.swift          accessibility/window positioning helpers
    Settings/                            settings model/store/view model/view

  Shortcuts/                             shortcut specs, capture recorder, settings rows
  QuickInput/                            quick text input panel and double-tap detector
  Interaction/                           interaction state/effects/reducer/runtime/journal
  PointerOverlay/                        pointer overlay coordinate validation/resolution
  Domain/                                shared app-domain helpers such as log prefixes

  Context/
    PickyContextPacket.swift             context packet Codable model
    PickyContextPacketAssembler.swift    neutral context assembly
    PickyAppSupport.swift                app-support paths and screenshot storage
    PickyVoiceContextCaptureCoordinator.swift
    CompanionScreenCaptureUtility.swift

  Companion/
    CompanionPanel*.swift                panel sections/status/permissions/settings
    Dictation/                           shortcut, transcription provider, permissions, audio conversion
    AzureOpenAI/                         Azure STT/TTS provider and Keychain config
    ElevenLabs/                          ElevenLabs TTS provider
    Speech/                              macOS speech playback abstractions

  HUD/
    PickyHUDOverlayManager.swift         NSPanel overlay lifecycle and sizing
    PickyHUDLayoutPolicy.swift           pure HUD layout/animation policy
    PickyHUDView.swift                   session cards, follow-up controls, extension UI rendering
    PickyToolActivityRow.swift           tool row rendering
    PickyArtifactReporter.swift          report generation helpers
    PickyReportViewer.swift              markdown report viewer
    PickyDiffPreview.swift               diff preview helpers

  Overlay/
    OverlayWindow.swift                  overlay NSWindow
    OverlayWindowManager.swift           multi-display overlay lifecycle
    BlueCursorView.swift                 cursor/bubble SwiftUI rendering
    BubbleLayout.swift                   pure bubble layout calculations
    CompanionResponseOverlay.swift       transient response overlay

  Sessions/
    PickySessionSelectionStore.swift     selected/voice-target/archive stores
    PickySessionArchive.swift            archive helpers
    PickyTerminalOverlay.swift           in-app Pi terminal overlay and resume command builder
```

## 6. picky-agentd responsibility map

```text
agentd/src/
  index.ts                              process composition, runtime/tool wiring
  server.ts                             WebSocket transport + command dispatch
  protocol.ts                           zod protocol schemas and shared types
  auth.ts                               local auth/token helpers
  connection-info-store.ts              daemon discovery file
  session-supervisor.ts                 app-facing session facade
  session-store.ts                      persisted session metadata
  session-message-builder.ts            app-facing message journal/source mapping
  artifact-store.ts                     artifact persistence/opening
  log-store.ts                          daemon log storage
  prompt-builder.ts                     neutral task/follow-up/Picky/Pickle prompts
  task-router.ts                        mock conservative router for mock runtime
  local-log.ts                          daemon logging

  application/
    handoff-tool.ts                     Picky tools: start/list/follow-up Pickle sessions
    pointer-tool.ts                     Picky pointer overlay request tool
    ask-user-question-tool.ts           Pickle ask_user_question bridge
    pi-session-syncer.ts                Pi session JSONL/history sync helpers
    runtime-event-handler.ts            normalized runtime event state transitions
    artifact-materializer.ts            terminal artifacts/reports/PR extraction
    extension-ui-bridge.ts              Pi extension UI bridge
    extension-ui-request-mapper.ts      pure request mapping

  domain/
    artifacts.ts                        artifact merge helpers
    changed-files.ts                    changed-file merge helpers
    pi-event-normalizer.ts              Pi event -> normalized event
    safe-truncate.ts                    bounded string truncation helpers
    session-status.ts                   terminal/status helpers
    session-summary.ts                  final answer/summary helpers
    session-title.ts                    title generation
    tool-activity.ts                    tool activity merge/summary helpers

  runtime/
    types.ts                            runtime handle interfaces
    mock-runtime.ts                     UI/test mock runtime
    pi-sdk-runtime.ts                   Pi SDK adapter (deferred split)
```

`SessionSupervisor` remains the stable facade for app-visible operations: `load`, `list`, `get`, `route`, `create`, `followUp`, `steer`, `abort`, `answerExtensionUi`, and artifact/report materialization through the application-layer stores.

## 7. Protocol and state model

The app-daemon protocol is owned in both languages:

- Swift: `Picky/PickyAgentProtocol.swift`
- TypeScript: `agentd/src/protocol.ts`
- Fixtures/contracts: `contracts/`

Protocol changes must update fixtures and both Swift/TypeScript tests in the same PR.

Session status values:

```text
queued -> running -> waiting_for_input -> running -> completed
                       |                 |-> failed
                       |-> blocked       |-> cancelled
```

`PickyAgentSession` includes id, title, status, cwd, timestamps, summary/final answer, logs, tool activity, artifacts, changed files, and pending extension UI request.

## 8. Prompting model

Picky prompts must be neutral. Include user request and captured context, then tell Pi to use available skills/extensions/MCPs/tools as appropriate. Do not name a workflow unless the user explicitly did.

Important prompt builders:

- `buildInitialTaskPrompt`: visible session without Picky routing.
- `buildMainAgentPrompt`: always-on Picky turn with Pickle tools.
- `buildPicklePrompt`: delegated Pickle session.
- `buildFollowUpPrompt`: follow-up with optional fresh context.
- `buildMainAgentPickleCompletionPrompt`: concise completion summary back to Picky.

## 9. Persistence and file locations

Picky app support root stores daemon metadata, screenshots, artifacts, reports, logs, and session metadata under `~/Library/Application Support/Picky/`.

Pi session JSONL/history remains in normal Pi storage. Picky metadata points to Pi session files where available so the in-app Pi terminal overlay, copied `pi --session ...` command, or Pi itself can resume or inspect sessions.

## 10. Build, test, and packaging

Normal development:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test
cd agentd && pnpm install
cd agentd && pnpm test
cd agentd && pnpm run build
```

Targeted Swift test example:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickyCompanionManagerTests
```

Signed local package:

```bash
./scripts/package-signed-app.sh
```

Runtime smoke for packaged app:

```bash
PICKY_AGENTD_RUNTIME=mock PICKY_AGENTD_ROOT="$PWD/agentd" build/package/export/Picky.app/Contents/MacOS/Picky
```

Expected: `picky-agentd listening on 127.0.0.1:17631`; quitting the app closes the daemon/port.

## 11. Maintenance and refactoring rules

- Run `git status --short` before edits and protect unrelated user changes.
- Keep one responsibility per PR/change: do not mix UI restructuring, protocol changes, and runtime behavior changes.
- Add characterization tests immediately before the change that needs them, not broad speculative test suites.
- UI manual smoke requires user approval before launching/restarting Picky.
- Access-control widening (`private`/`fileprivate` to broader visibility) must be explicit and justified by the file boundary introduced.
- Do not promote nested Swift types to top-level without a separate API cleanup decision.
- Keep warning-only line-count checks non-blocking; urgent hotfixes should not be blocked by file-size policy.
- `Picky.xcodeproj` uses filesystem-synchronized root groups, so moves under `Picky/` usually do not need manual project file edits, but tests still must verify access-control/runtime behavior.

## 12. Deferred structural splits

These are intentionally deferred until they clearly reduce complexity:

- `DesignSystem.swift` token/style split.
- `PickyAgentClient.swift` protocol/WebSocket/stub split.
- `PickySessionViewModel.swift` rename/split into HUD-specific files.
- Separate `PickySessionCardView.swift` only if card ownership grows; keep `SessionCard` nested unless separately approved.
- Further `CompanionManager` collaborators beyond the current voice/context/event boundaries.
- `agentd/src/server.ts` transport split.
- `agentd/src/runtime/pi-sdk-runtime.ts` session/image-options split.
- Broader Picky runtime orchestrator or visible lifecycle extraction unless session orchestration grows again.

## 13. Pi integration references

Before changing Pi SDK/runtime/extension behavior, resolve the installed `@mariozechner/pi-coding-agent` package location and read the relevant official docs:

- `README.md`
- `docs/sdk.md`
- `docs/rpc.md`
- `docs/extensions.md`
- `docs/session-format.md`
- `examples/sdk/`

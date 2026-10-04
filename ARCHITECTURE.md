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

`picky-agentd` runs as a child process of `Picky.app`. The primary daemon owns the fixed port and the main agent; each manual Pickle can additionally run in its own child daemon bound to the Pickle's cwd. Ownership of session projections across those connections is decided by `PickyProjectionOwnershipLedger`; see `docs/per-pickle-daemon-topology.md`. The primary writes connection info under Picky app support so Pi extensions can discover it.

## 4. Main data flows

### New voice/text task

1. User invokes Picky by a configurable push-to-talk shortcut or quick-input shortcut. Defaults are `Control+Option` for voice and double-tap `Control` for text entry.
2. `Picky.app` captures transcript, active app/window, browser context, selected text, screenshots, cwd, and optional selected session.
3. App sends `routeTask`/`createTask` to `picky-agentd`.
4. If Picky mode is enabled, daemon routes through the always-on Picky runtime. Simple requests can receive `quickReply`; complex work is delegated with the local `picky` CLI through the main agent's existing bash tool to a visible Pickle session.
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
  PickyAgentClient.swift                 client protocol + WebSocket/stub pieces (deferred split)
  PickyAgentClientRouter.swift           per-Pickle daemon client routing
  PickyAgentDaemonLauncher.swift         child-process daemon launch/stop
  PickyAgentDaemonPool.swift             per-Pickle daemon pool and ownership
  PickyAdvancedContext.swift             browser/window/selection providers
  BuddyDictationManager.swift            audio capture + transcription lifecycle
  PickySessionViewModel.swift            HUD session state facade (deferred rename/split)
  PickyAskUserQuestionForm.swift         extension UI form rendering

  Protocol/                              Codable app-daemon protocol models and codecs
    PickyAgentProtocol.swift             core command/event envelope and version
    PickyAgentProtocolCodec.swift        shared encode/decode helpers
    Picky*Protocol.swift                 projection, async task, package, MCP, CLI, narration, settings

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
  MainAgent/                             always-on main-agent transcript store
  Localization/                          locale manager and localized string helpers
  Feedback/                              feedback capture and HUD perf instrumentation
  Updates/                               Sparkle update controller and UI
  Watchdog/                              crash watchdog and its alert helper target
  Domain/                                shared app-domain helpers such as log prefixes

  Context/
    PickyContextPacket.swift             context packet Codable model
    PickyContextPacketAssembler.swift    neutral context assembly
    PickyAppSupport.swift                app-support paths and screenshot storage
    PickyVoiceContextCaptureCoordinator.swift
    CompanionScreenCaptureUtility.swift

  Companion/                             voice pipeline only (settings UI moved to Hub/Settings)
    CompanionManager.swift               voice pipeline orchestration and event presentation
    CompanionManager+*.swift             voice/event lifecycle extensions (one folder; state owners split out)
    CompanionVoicePolicies.swift         pure voice routing/eligibility policy
    PickyVoice*.swift                    voice input target and transcript routing policy
    PickyPermissionMonitor.swift         mic/speech/accessibility permission observation
    Dictation/                           shortcut, transcription provider, permissions, audio conversion
    Input/                               IME-aware AppKit text view shared by composers
    AzureOpenAI/                         Azure STT/TTS provider and Keychain config
    ElevenLabs/                          ElevenLabs TTS provider
    OpenAI/                              OpenAI STT/TTS provider
    Speech/                              macOS speech playback abstractions

  Hub/
    PickyHubRootView.swift               Hub window shell and navigation
    Pages/                               dashboard, settings, plugins, conversation pages
    Components/                          shared Hub controls and modals
    Settings/                            settings/prerequisite/cron/main-agent settings UI
    Plugins/                             curated plugin catalog, MCP server admin
    Statistics/, Guides/, QuickStart/    supporting Hub surfaces

  HUD/
    PickyHUDOverlayManager.swift         NSPanel overlay lifecycle and sizing
    PickyHUDLayoutPolicy.swift           pure HUD layout/animation policy
    PickyHUDView.swift                   panel shell and session card composition
    PickyHUDPanel.swift, PickyHUDPlacement.swift, PickyHUDVisibilityStore.swift
                                         panel shell, placement, visibility
    Conversation/                        conversation card, composer, list, bubbles
    Dock/                                dock rail, dock icons, group list/folder UI, drag-drop
    ToolHistory/                         tool activity rows, history viewer, result rendering
    Archive/                             archive action controller and undo toast
    Artifacts/                           report viewer, artifacts/changes views, diff preview

  Overlay/
    OverlayWindow.swift                  overlay NSWindow
    OverlayWindowManager.swift           multi-display overlay lifecycle
    BlueCursorView.swift                 cursor/bubble SwiftUI rendering
    BubbleLayout.swift                   pure bubble layout calculations
    CompanionResponseOverlay.swift       transient response overlay
    Pointer/                             pointer overlay coordinate validation/resolution

  Sessions/
    PickySessionSelectionStore.swift     selected/voice-target/archive stores
    PickySessionArchive.swift            archive helpers
    PickyTerminalOverlay.swift           shared SwiftTerm view/process adapters and resume command builder
    Dock/PickyDockLayout.swift           persisted dock layout model (groups, entries, colors)
    Projection/                          v2 session projection stores and ownership ledger
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
  session-log-append.ts                 bounded session-log appends
  prompt-builder.ts                     neutral task/follow-up/Picky/Pickle prompts
  task-router.ts                        mock conservative router for mock runtime
  local-log.ts                          daemon logging

  application/                          Pi-SDK-free orchestration (guard-enforced)
    internal-picky-cli.ts               Primary-only local CLI wrapper/PATH installation
    main-agent-coordinator.ts           always-on main agent lifecycle and reply guards
    pointer-overlay-request.ts          validated Picky pointer overlay requests
    overlay-context-resolver.ts         overlay app/window context resolution
    pi-session-syncer.ts                Pi session JSONL/history sync helpers
    runtime-event-handler.ts            normalized runtime event state transitions
    artifact-materializer.ts            terminal artifacts/reports/PR extraction
    extension-ui-request-mapper.ts      pure request mapping
    pickle-terminal-waiter.ts           CLI --wait replies from projection commits

  domain/
    artifacts.ts                        artifact merge helpers
    changed-files.ts                    changed-file merge helpers
    pi-event-normalizer.ts              Pi event -> normalized event
    safe-truncate.ts                    bounded string truncation helpers
    session-status.ts                   terminal/status helpers
    session-summary.ts                  final answer/summary helpers
    session-title.ts                    title generation
    tool-activity.ts                    tool activity merge/summary helpers

  runtime/                              the only layer (with bootstrap.ts) that imports @earendil-works/*
    types.ts                            runtime handle interfaces and boundary types (RuntimeCustomTool)
    mock-runtime.ts                     UI/test mock runtime
    pi-sdk-runtime.ts                   Pi SDK adapter (deferred split)
    ask-user-question-tool.ts           Pickle ask_user_question Pi tool
    user-guide-tool.ts                  read_picky_user_guide Pi tool
    extension-ui-bridge.ts              Pi ExtensionUIContext implementation
    pi-oauth-service.ts                 Pi model OAuth adapter
    package-operations.ts               Pi package manager adapter
    pi-extension-command-runner.ts      Pi RPC child runner
```

`SessionSupervisor` remains the stable facade for app-visible operations: `load`, `list`, `get`, `route`, `create`, `followUp`, `steer`, `abort`, `answerExtensionUi`, and artifact/report materialization through the application-layer stores.

## 7. Protocol and state model

The app-daemon protocol is owned in both languages:

- Swift: `Picky/Protocol/PickyAgentProtocol.swift`
- TypeScript: `agentd/src/protocol.ts`
- Fixtures/contracts: `contracts/`

Protocol changes must update fixtures and both Swift/TypeScript tests in the same PR.

Each connection has a client profile, `core` or `desktop` (`agentd/src/domain/client-profile.ts`). Core is platform-neutral session control, which is all the `picky` CLI needs; desktop additionally owns overlay windows, cursor narration/TTS, and the embedded terminal. A client declares its profile in the optional `profile` field of `registerAppCapabilities`; a client that omits it is classified `desktop` when it registers an app bridge capability and `core` otherwise, and a client that never registers is `core`. The daemon drops events in `DESKTOP_ONLY_EVENT_TYPES` for core connections. Only `broadcast` is gated: unicast replies to a requesting socket always go through, so a CLI never loses the answer to its own command. A new event defaults to core until it is added to that set.

How a client folds a v2 projection stream into session state is pinned separately by `contracts/projection/conformance/`: ordered snapshot/transaction scenarios with the per-section state they must produce, including the `unavailable` vs loaded-but-empty distinction a flattened session card erases. The Swift storage reducer (`Picky/Sessions/PickyRegistrySessionProjectionStorage+V2.swift`) is normative; `agentd/src/domain/session-projection-reducer.ts` is the TypeScript reference a web client reuses instead of re-reading the protocol, and its test also asserts that `buildSessionProjectionMutations` round-trips through it. The matching Swift conformance test is a following step.

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

Pi session JSONL/history remains in normal Pi storage. Picky metadata points to Pi session files where available so the copied `pi --session ...` command, the card's Sync from Pi session action, or Pi itself can resume or inspect sessions.

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
- `agentd/src/runtime/pi-sdk-runtime.ts` session/image-options split.
- Broader Picky runtime orchestrator or visible lifecycle extraction unless session orchestration grows again.

### 12.1 agentd feature slices (Phase 1-d pilot)

`agentd/src/server.ts` is no longer deferred as a whole. Instead of splitting it by
transport layer, four Hub-side features moved into `agentd/src/features/<slice>/`,
where each slice owns the pieces that used to change together across
`protocol.ts`, `server.ts`, and a service file.

A slice is:

- `schema.ts`: the feature's zod command and event schemas, built on
  `agentd/src/protocol-base.ts`. `protocol.ts` spreads them back into the single
  wire union, so message names and fields are unchanged.
- `handlers.ts`: a `(ctx) => CommandHandlersFor<...>` factory, following the
  existing `packageOperationHandlers` shape. `server.ts` merges the factories into
  one registry annotated with `CommandHandlerMap`, so a command without a handler
  is still a compile error.
- Services with no other owner (`settings-control-broker.ts`,
  `hub-statistics-broker.ts`). Anything that imports `@earendil-works/*` stays in
  `runtime/`; the slice declares a narrow port and the runtime adapter satisfies it
  structurally.

Decisions worth keeping:

- The four slices are `settings`, `package`, `pi-oauth`, and `hub`. They are the
  Hub-side features that never touched `session-supervisor.ts` in the last 90 days.
- `reloadPlugins` is **not** in the `hub` slice. It queues `/reload` follow-ups and
  appends session logs through the supervisor, so folding it in would mix session
  state into the measurement below. It stays in `server.ts`.
- `application/hub-statistics-service.ts` stays in `application/`: `bootstrap.ts`
  and `application/pickle-classifier.ts` own it too, and moving it would make
  application code depend on a feature slice.
- Envelope primitives live in `protocol-base.ts` rather than `protocol.ts` because
  a slice schema importing `protocol.ts` would be a module cycle.
- `scripts/check-architecture-rules.js` enforces two slice rules: the protocol
  parity guard resolves `...sliceSchemas` spreads so slice messages still need a
  Swift counterpart, and `checkFeatureSliceSupervisorBoundary` fails when anything
  under `features/` imports `session-supervisor.js` as a value. Supervisor
  capabilities must arrive through a narrow port on the slice context
  (`reloadPiAuthentication` is the only current case); `import type` stays allowed.

#### Measuring whether the slice holds

The pilot is worth continuing only if changing one of these features stops
spreading across the tree. Re-measure in 4-6 weeks with
`scripts/measure-slice-cochange.sh` (`SINCE="42 days ago"` narrows the window to
the post-split period). It walks the slice folders plus the pre-slice service
paths and judges each commit on its own:

- `slice`: which feature the commit belongs to. Two slices in one commit is not
  closed.
- `outside`: agentd files the commit touched that the slice does not own.
- `protocol` / `server` / `swift`: whether it touched `agentd/src/protocol.ts`,
  `agentd/src/server.ts`, or the Swift protocol models (`Picky/Protocol/`, or the
  pre-move `Picky/Picky*Protocol.swift`).
- `closed`: one slice, nothing outside it, and none of those three.

The script excludes commits that are the restructuring itself rather than a
feature change: the split (`4b4aed2e7`) and the Pi SDK import confinement
(`e357adf34`, 11 renames). `EXCLUDE="<sha> ..."` adds more. `avg_dirs` is kept
as a reference number only; it counts directories, not coupling. With fewer
than five measurable commits the script prints `verdict=inconclusive` instead of
a percentage, because one commit either way swings the rate by 20 points.

Baseline in the 90 days before the split (11 measurable commits, 2 excluded):
**1 of 11 closed (9%)**, **36%** (4 of 11) changed `protocol.ts` and `server.ts`
together, **64%** (7 of 11) also changed the Swift protocol models, and the
average commit touched 8.2 directories. The one closed commit (`ad0b408a0`) was a
one-file import fix, so in practice no Hub feature change stayed inside its
feature before the split.

Decision rule: if the post-split window has at least five measurable commits and
the closed rate clears 50% while `protocol.ts` + `server.ts` co-change drops
below the 36% baseline, extend slicing to the next feature. If commits keep
fanning out, stop slicing rather than adding more `features/` directories.

## 13. Pi integration references

Before changing Pi SDK/runtime/extension behavior, resolve the installed `@earendil-works/pi-coding-agent` package location and read the relevant official docs:

- `README.md`
- `docs/sdk.md`
- `docs/rpc.md`
- `docs/extensions.md`
- `docs/session-format.md`
- `examples/sdk/`

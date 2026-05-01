# Picky Implementation Tasks

_Last updated: 2026-05-01_

This file expands `ARCHITECTURE.md` into implementation-ready phases, task bundles, and validation contracts.

Primary references:

- `ARCHITECTURE.md`
- `AGENTS.md`
- Pi SDK docs: `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/sdk.md`
- Pi RPC + extension UI docs: `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/rpc.md`
- Pi session format docs: `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/session-format.md`
- Public Clicky clone: `/tmp/clicky-re/upstream` or `https://github.com/farzaa/clicky/`

## Non-negotiable product constraints

1. **Picky captures context. Pi interprets intent.**
   - Do not add deterministic routers such as `if sentry url then sentry flow`.
   - URLs, selected text, screenshots, cwd, and app/window metadata are neutral context only.
2. **Use existing Pi resources.**
   - Load normal `~/.pi/agent` settings, skills, extensions, prompts, memory, and sessions.
   - Do not reimplement skills, MCP bridge, hotfix policy, DB policy, or shipping workflows.
3. **Long-running sessions are first-class.**
   - Multiple sessions, queueing, tool activity, extension UI requests, follow-up, abort, persistence, and reconnect are required.
4. **Local-first v1.**
   - No Cloudflare Worker, SaaS auth, billing, analytics, PostHog, FormSpark, ElevenLabs TTS, or Claude-direct backend.
   - App may use macOS-native speech first; any optional remote STT must be disabled by default and isolated behind settings.
5. **Security and risk are visible.**
   - Always surface cwd, branch/worktree when known, tool mode if known, active destructive confirmation, and external access via tool activity.
6. **Testing and contracts are part of every phase.**
   - Every implementation task must include unit/integration/contract checks or an explicit reason why it cannot.

## Baseline assumptions for v1 implementation

These assumptions convert architecture choices into executable tasks. Change them only if the user explicitly revises the plan.

- `picky-agentd` lives under `agentd/` and uses TypeScript.
- New Node package management uses `pnpm`.
- App-daemon transport for MVP is local WebSocket on `127.0.0.1` with an app-generated bearer token.
  - Unix domain socket can be revisited after the MVP bridge is stable.
- `picky-agentd` is launched as a child process of `Picky.app` for v1.
- Pi sessions remain in the standard Pi session store; Picky metadata/artifacts live under `~/Library/Application Support/Picky/`.
- Swift tests should prefer pure model/contract tests first, then UI tests where stable.
- Do not commit changes from worker agents unless the main user explicitly asks for commits.

## Shared validation commands

Use the commands that apply to the current repo state. If a command cannot run yet, the worker must explain why and the verifier must confirm that reason.

### macOS app

```bash
# Discover final scheme after rename
xcodebuild -list

# Expected final build/test commands after Phase 0 rename
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
```

### Node daemon

```bash
pnpm --dir agentd install
pnpm --dir agentd typecheck
pnpm --dir agentd test
pnpm --dir agentd build
```

### Contract fixtures

```bash
pnpm --dir agentd test:contracts
# Swift-side contract tests should decode the same fixtures under contracts/.
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test -only-testing:PickyTests/ProtocolContractTests
```

### Repo-level safety grep

```bash
# No deterministic task routers in app/daemon code.
rg -n "sentry|slack|notion|creatrip-db|hotfix" --glob '!ARCHITECTURE.md' --glob '!AGENTS.md' --glob '!TASKS.md'

# No old remote backend/analytics dependencies after Phase 1.
rg -n "Cloudflare|workers.dev|api\.anthropic|ElevenLabs|AssemblyAI|PostHog|FormSpark|Supabase|stripe|billing|paywall" .
```

## Contract test strategy

Create shared JSON fixtures under `contracts/` early and reuse them from both TypeScript and Swift tests.

### Contract group A — App-daemon protocol

Files:

- `contracts/protocol/create-task.request.json`
- `contracts/protocol/follow-up.request.json`
- `contracts/protocol/steer.request.json`
- `contracts/protocol/abort.request.json`
- `contracts/protocol/list-sessions.request.json`
- `contracts/protocol/extension-ui-response.request.json`
- `contracts/protocol/session-snapshot.event.json`
- `contracts/protocol/session-updated.event.json`
- `contracts/protocol/tool-activity.event.json`
- `contracts/protocol/extension-ui-request.event.json`
- `contracts/protocol/error.event.json`

Validation:

- Node `zod` schemas parse every fixture.
- Swift `Codable` models decode every fixture.
- Node and Swift encode equivalent required fields for command/event envelopes.
- Unknown future event fields are ignored by Swift but preserved enough for logging/debugging.

### Contract group B — Pi event normalization

Files:

- `contracts/pi-events/agent-start.json`
- `contracts/pi-events/message-text-delta.json`
- `contracts/pi-events/tool-start.json`
- `contracts/pi-events/tool-update.json`
- `contracts/pi-events/tool-end-success.json`
- `contracts/pi-events/tool-end-error.json`
- `contracts/pi-events/queue-update.json`
- `contracts/pi-events/extension-ui-request-confirm.json`
- `contracts/pi-events/agent-end.json`
- `contracts/pi-events/abort-error.json`

Validation:

- `normalizePiEvent()` maps each fixture to a deterministic Picky event/session patch.
- Tool events correlate by `toolCallId`.
- `extension_ui_request` sets session status to `waiting_for_input` for dialog methods.
- `agent_end` only becomes `completed` when no queued steering/follow-up and no pending UI request remain.

### Contract group C — Neutral context and prompt building

Files:

- `contracts/context/sentry-url.context.json`
- `contracts/context/slack-url.context.json`
- `contracts/context/plain-text.context.json`
- `contracts/context/multi-screen.context.json`
- `contracts/prompts/sentry-url.expected.md`
- `contracts/prompts/slack-url.expected.md`

Validation:

- Prompt builder includes transcript, cwd, app/window/browser metadata, and screenshot labels.
- Prompt builder does **not** instruct Pi to use Sentry/Slack/DB/Notion/hotfix skills based on URL.
- Prompt includes the neutral instruction: use available Pi skills/extensions/MCPs/local tools as appropriate.
- Screenshot paths are attached as images where supported and referenced by label in text.

### Contract group D — Persistence and recovery

Validation:

- Picky metadata writes only under `~/Library/Application Support/Picky/` or an injected test directory.
- Session metadata can be reloaded after daemon restart.
- Missing Pi session files degrade to `blocked` or `failed` with a clear error, not a crash.
- Path traversal in artifact names is rejected.

## Phase 0 — Repository setup and Clicky foundation

Goal: import the public Clicky source safely, preserve local planning docs, rename to Picky, and establish a compilable baseline.

### Task 0.1 — Baseline repository guardrails

Files:

- Modify/create: `TASKS.md` only for planning.
- Do not overwrite existing `AGENTS.md` or `ARCHITECTURE.md`; they may contain user edits.

Steps:

1. Check `git status --short` and note pre-existing modified files.
2. Confirm `/tmp/clicky-re/upstream` exists; if not, clone `https://github.com/farzaa/clicky/` into a temp directory.
3. Record public source commit hash in `docs/CLICKY_UPSTREAM.md`.
4. Add a short clean-room note: public MIT code may be copied; local installed Clicky app is UX reference only.

Tests/contracts:

- `git status --short` shows no accidental overwrite of `AGENTS.md` or `ARCHITECTURE.md`.
- `docs/CLICKY_UPSTREAM.md` includes upstream URL, commit SHA, license, and exclusions.

Done when:

- Upstream provenance is documented.
- Existing planning docs are preserved.

### Task 0.2 — Import public Clicky macOS source

Files:

- Copy from public source into repo, excluding upstream `.git` and root `AGENTS.md`.
- Keep MIT `LICENSE`.
- Avoid copying Cloudflare `worker/` if Phase 1 will remove it immediately; if copied, Phase 1 must delete it.

Suggested command shape:

```bash
rsync -a --exclude '.git' --exclude 'AGENTS.md' /tmp/clicky-re/upstream/ ./
```

Then verify and adjust so local `AGENTS.md` remains the Picky project context.

Tests/contracts:

- `test -f LICENSE`
- `test -d leanring-buddy` initially or the renamed app directory after Task 0.3.
- `git diff -- AGENTS.md ARCHITECTURE.md` confirms only intentional user edits remain.

Done when:

- Public source is present in this repo.
- Picky project docs are not overwritten.

### Task 0.3 — Rename app, project, bundle identifiers to Picky

Files likely affected:

- Rename `leanring-buddy.xcodeproj` → `Picky.xcodeproj`
- Rename `leanring-buddy/` → `Picky/`
- Rename test folders similarly if practical.
- Update `project.pbxproj`
- Update `Info.plist`
- Update entitlements filename/content if needed.
- Update Swift app entry file name and app display names.

Requirements:

- Final macOS app display/product name: `Picky`.
- Final scheme should be `Picky` if feasible.
- Bundle identifier should be Picky-specific and not collide with Clicky/leanring-buddy.
- Keep public Clicky attribution in docs/license, but app runtime strings should not present as Clicky.

Tests/contracts:

```bash
xcodebuild -list
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
plutil -lint Picky/Info.plist
rg -n "leanring-buddy|leanring_buddy|Clicky" Picky Picky.xcodeproj --glob '!*.png' --glob '!*.jpg'
```

Allowed grep exceptions:

- license/provenance docs
- comments explicitly documenting public Clicky attribution

Done when:

- `Picky` scheme builds.
- Old runtime identity is removed.

### Task 0.4 — Establish initial test baseline

Files likely affected:

- `PickyTests/*`
- `PickyUITests/*`
- Optional: `scripts/test-macos.sh`

Steps:

1. Rename generated test modules/classes to Picky.
2. Keep at least one passing unit test that validates app metadata or a pure helper.
3. Keep or disable flaky autogenerated UI tests with an explicit comment.
4. Add a script for repeatable local build/test if useful.

Tests/contracts:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
```

Done when:

- The imported/renamed app has a known build/test baseline.

## Phase 1 — Strip remote Clicky backend and SaaS dependencies

Goal: remove SaaS/backend assumptions while preserving macOS primitives.

### Task 1.1 — Remove Cloudflare Worker and direct Claude backend flow

Files likely affected:

- Delete `worker/` if present.
- Remove or replace `ClaudeAPI.swift` and any call sites.
- Update manager classes that expected a remote chat response.

Requirements:

- No request path depends on Cloudflare Worker or direct Claude API.
- Voice/text task submission should route to a local `PickyAgentClient` abstraction, even if stubbed until Phase 3.

Tests/contracts:

```bash
rg -n "worker|workers.dev|Cloudflare|api\.anthropic|ClaudeAPI" Picky agentd worker 2>/dev/null || true
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
```

Done when:

- App compiles without remote Claude/Worker code.

### Task 1.2 — Remove analytics, email capture, billing/paywall remnants

Files likely affected:

- Remove `ClickyAnalytics.swift` or replace with no-op local logging.
- Remove PostHog/FormSpark/Supabase/auth/billing/paywall UI and configuration if present.

Requirements:

- No analytics or email capture in v1.
- No app launch network request for telemetry.

Tests/contracts:

```bash
rg -n "PostHog|FormSpark|Supabase|analytics|telemetry|billing|paywall|stripe" Picky . --glob '!TASKS.md' --glob '!ARCHITECTURE.md'
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' build
```

Done when:

- SaaS growth/auth/billing concepts are absent from app code.

### Task 1.3 — Replace remote TTS/STT defaults with local-first abstractions

Files likely affected:

- `BuddyTranscriptionProvider.swift`
- `AppleSpeechTranscriptionProvider.swift`
- `AssemblyAIStreamingTranscriptionProvider.swift`
- `ElevenLabsTTSClient.swift`
- dictation/audio manager files

Requirements:

- Apple Speech or local transcription provider is the default.
- Remote AssemblyAI/ElevenLabs clients are removed or fully disabled behind future-only abstractions with no credentials/endpoints.
- Audio pipeline remains usable for push-to-talk capture.

Tests/contracts:

```bash
rg -n "AssemblyAI|ElevenLabs|elevenlabs|api\.assemblyai|api\.elevenlabs" Picky . --glob '!TASKS.md' --glob '!ARCHITECTURE.md'
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test
```

Done when:

- Push-to-talk/dictation code compiles with local-first provider only.

### Task 1.4 — Preserve macOS primitives behind Picky-named APIs

Files likely affected:

- global hotkey monitor
- screen capture utility
- overlay window
- menu bar panel manager
- window position manager
- design system

Requirements:

- Keep working code for menu bar, hotkey, permissions, screen capture, overlay/cursor.
- Rename types gradually where useful, but do not break functionality for cosmetic renames.
- Add protocols around context capture and client submission to make daemon integration testable.

Tests/contracts:

- Unit tests for pure context packet assembly with fake app/window/screen providers.
- Build/test pass.

Done when:

- The app is local-first and still has the macOS shell needed for Picky.

## Phase 2 — Create `picky-agentd`

Goal: build a testable TypeScript daemon that supervises Pi SDK sessions and exposes a stable app protocol.

### Task 2.1 — Scaffold TypeScript daemon package

Files:

- Create `agentd/package.json`
- Create `agentd/tsconfig.json`
- Create `agentd/src/index.ts`
- Create `agentd/src/server.ts`
- Create `agentd/src/protocol.ts`
- Create `agentd/src/__tests__/smoke.test.ts`
- Optional root `pnpm-workspace.yaml` if helpful.

Requirements:

- Use `pnpm`.
- Include scripts: `typecheck`, `test`, `test:contracts`, `build`, `dev`.
- Use a Node test runner that works locally without external services.

Tests/contracts:

```bash
pnpm --dir agentd install
pnpm --dir agentd typecheck
pnpm --dir agentd test
pnpm --dir agentd build
```

Done when:

- Empty daemon package compiles and tests.

### Task 2.2 — Define app-daemon protocol schemas and fixtures

Files:

- `agentd/src/protocol.ts`
- `agentd/src/protocol.test.ts`
- `contracts/protocol/*.json`

Required command envelopes:

- `createTask`
- `followUp`
- `steer`
- `abort`
- `listSessions`
- `getSession`
- `answerExtensionUi`
- `openArtifact` or artifact URL/path request if needed

Required event envelopes:

- `hello`
- `sessionSnapshot`
- `sessionUpdated`
- `sessionLogAppended`
- `toolActivityUpdated`
- `extensionUiRequest`
- `artifactUpdated`
- `error`

Core data models:

- `PickyContextPacket`
- `PickyAgentSession`
- `PickyToolActivity`
- `PickyArtifact`
- `PickyChangedFile`
- `PickyExtensionUiRequest`

Tests/contracts:

- Zod parse succeeds for every fixture.
- Invalid fixtures fail with useful errors.
- Fixture IDs/timestamps use stable fake values.

Done when:

- Protocol is versioned and fixture-backed.

### Task 2.3 — Implement local WebSocket transport

Files:

- `agentd/src/server.ts`
- `agentd/src/auth.ts`
- `agentd/src/index.ts`
- `agentd/src/server.test.ts`

Requirements:

- Bind only to `127.0.0.1`.
- Require a bearer token or query token provided by the app at daemon launch.
- Emit `hello` event with protocol version.
- Handle malformed JSON without crashing.
- Support multiple app clients observing the same sessions.

Tests/contracts:

- Unauthorized connection is rejected.
- Authorized client receives `hello`.
- Malformed message returns `error` event and keeps server alive.
- `listSessions` returns an empty array before sessions exist.

Done when:

- App-facing local server is reliable without Pi runtime yet.

### Task 2.4 — Implement session supervisor with mock runtime

Files:

- `agentd/src/session-supervisor.ts`
- `agentd/src/session-store.ts`
- `agentd/src/runtime/types.ts`
- `agentd/src/runtime/mock-runtime.ts`
- tests for supervisor/store

Requirements:

- Manage multiple `PickyAgentSession` records.
- Statuses: `queued`, `running`, `waiting_for_input`, `blocked`, `completed`, `failed`, `cancelled`.
- Actions: create, followUp, steer, abort, list, get.
- Persist Picky metadata under injectable app support directory.
- No real Pi/model required for unit tests.

Tests/contracts:

- Create two mock sessions concurrently.
- Follow-up targets selected session.
- Abort changes status to `cancelled`.
- Store reload reconstructs sessions.
- Invalid transition is rejected or normalized deterministically.

Done when:

- Long-running session semantics are testable independent of Pi.

### Task 2.5 — Implement neutral prompt builder

Files:

- `agentd/src/prompt-builder.ts`
- `agentd/src/prompt-builder.test.ts`
- `contracts/context/*.json`
- `contracts/prompts/*.md`

Requirements:

- Build initial task prompt from `PickyContextPacket`.
- Build follow-up prompt preserving session context.
- Include screenshots as image attachments when supported by Pi SDK; include text labels either way.
- Do not hard-code skill names or route by URL.

Tests/contracts:

- Sentry URL fixture produces neutral prompt; grep expected prompt for absence of `sentry-investigate` instruction.
- Slack URL fixture remains neutral.
- Multi-screen screenshot labels preserved.

Done when:

- Prompt output is deterministic and contract-backed.

### Task 2.6 — Implement Pi SDK runtime adapter

Files:

- `agentd/src/runtime/pi-sdk-runtime.ts`
- `agentd/src/runtime/types.ts`
- `agentd/src/pi-event-normalizer.ts`
- `agentd/src/pi-event-normalizer.test.ts`

Pi SDK references:

- `createAgentSessionRuntime()`
- `createAgentSessionServices()`
- `createAgentSessionFromServices()`
- `DefaultResourceLoader`
- `SessionManager.create(cwd)`
- `session.prompt()` / `session.steer()` / `session.followUp()` / `session.abort()`
- `session.subscribe()`

Requirements:

- Use standard Pi resource discovery for `cwd` and `~/.pi/agent`.
- Keep Pi session files in standard Pi session storage.
- Convert Pi events into Picky session patches/events.
- Re-subscribe if a runtime session is replaced.
- Report resource/extension diagnostics as Picky logs, not crashes.

Tests/contracts:

- Unit tests with fake Pi session/event emitter.
- No live model call in default tests.
- Optional integration test gated by env var, e.g. `PICKY_RUN_PI_INTEGRATION=1`.

Done when:

- Daemon can run against mocked Pi and has a narrow adapter for real Pi.

### Task 2.7 — Implement extension UI bridge in daemon

Files:

- `agentd/src/extension-ui-bridge.ts`
- `agentd/src/extension-ui-bridge.test.ts`
- protocol fixtures

Requirements:

- Support dialog methods: `select`, `confirm`, `input`, `editor`.
- Support fire-and-forget methods: `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`.
- Dialog request sets session `waiting_for_input`.
- App response resumes the pending request.
- Timeout/default behavior follows Pi RPC semantics where available.

Tests/contracts:

- Confirm request → app event → answer → promise resolves.
- Cancel response maps to `undefined` or `false` as appropriate.
- Fire-and-forget emits event but does not block.

Done when:

- Native Picky UI can safely satisfy Pi extension UI needs.

### Task 2.8 — Implement artifact store and logs

Files:

- `agentd/src/artifact-store.ts`
- `agentd/src/log-store.ts`
- tests

Requirements:

- Store metadata, prompts, final answers, reports, screenshots, logs, PR links, and diff summaries.
- Root path defaults to `~/Library/Application Support/Picky/`; tests inject temp dir.
- Reject unsafe paths and path traversal.

Tests/contracts:

- Write/read/list artifacts.
- Reject `../evil` artifact name.
- Report path returned as file URL/path for app.

Done when:

- Durable output survives daemon restart.

## Phase 3 — Connect Swift app to daemon

Goal: launch `picky-agentd`, connect over local WebSocket, send context packets, and render streaming state.

### Task 3.1 — Add Swift protocol models matching contract fixtures

Files:

- `Picky/PickyAgentProtocol.swift`
- `PickyTests/ProtocolContractTests.swift`
- `contracts/protocol/*.json`

Requirements:

- Swift `Codable` types decode shared fixtures.
- Unknown future fields do not break decoding.
- Event enum handles known cases and preserves/logs unknown event types.

Tests/contracts:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test -only-testing:PickyTests/ProtocolContractTests
```

Done when:

- App and daemon share a fixture-backed protocol.

### Task 3.2 — Launch and supervise daemon child process

Files:

- `Picky/PickyAgentDaemonLauncher.swift`
- tests with injectable process runner

Requirements:

- Start `agentd` on app launch in development mode.
- Pass port/token/app support path/default cwd through env or args.
- Capture stdout/stderr to local logs.
- Restart with backoff on crash.
- Stop child on app termination for v1.

Tests/contracts:

- Unit test command construction.
- Unit test restart/backoff state machine with fake process.
- Manual smoke: app launch starts daemon and writes log.

Done when:

- Swift owns daemon lifecycle for MVP.

### Task 3.3 — Implement WebSocket client and reconnect

Files:

- `Picky/PickyAgentClient.swift`
- `PickyTests/PickyAgentClientTests.swift`

Requirements:

- Connect to `127.0.0.1` using token.
- Send command envelopes.
- Receive and decode event envelopes.
- Reconnect after daemon restart.
- Queue or reject commands while disconnected with visible error.

Tests/contracts:

- Fake WebSocket/server test for `hello`, `listSessions`, `sessionUpdated`.
- Decode malformed event into recoverable client error.

Done when:

- App can observe daemon state without UI coupling.

### Task 3.4 — Build context packet from macOS capture pipeline

Files:

- context capture utility/protocol files
- screenshot capture utility
- app/window metadata provider
- tests with fakes

Requirements:

- Assemble `PickyContextPacket` with source, transcript, timestamp, active app/window, browser metadata if available, screens, default cwd, selected session.
- Store screenshots under app support before sending paths.
- No URL-based routing.

Tests/contracts:

- Given fake app/window/screens, context packet matches fixture.
- Screenshot file path is under Picky app support.
- Sentry/Slack URLs are just data fields.

Done when:

- Voice/text invocation can produce a neutral context packet.

### Task 3.5 — Submit task and display streaming basic response

Files:

- manager/view model connecting dictation/text to `PickyAgentClient`
- minimal response overlay view
- tests

Requirements:

- Initial transcript sends `createTask`.
- Daemon events update local session view models.
- Assistant text/log preview displays incrementally.

Tests/contracts:

- Fake client emits session events; view model updates title/status/last summary.
- Manual smoke with mock daemon.

Done when:

- End-to-end app ↔ daemon loop works with mock runtime.

## Phase 4 — Long-running HUD MVP

Goal: top-right overlay shows multiple session cards with state, tool activity, logs, and completion.

### Task 4.1 — Session state view models and status machine

Files:

- `Picky/SessionModels.swift`
- `Picky/SessionStore.swift` or view-model equivalent
- tests

Requirements:

- Represent all statuses.
- Maintain active/recent ordering.
- Derive compact display fields: title, cwd, duration, tool count, last summary.
- Prevent invalid UI state transitions.

Tests/contracts:

- Event sequence fixtures drive expected status changes.
- Completed sessions remain visible as recent.

Done when:

- UI state is deterministic and independently tested.

### Task 4.2 — Collapsed top-right session cards

Files:

- HUD overlay window/view files
- card view components

Requirements:

- Top-right overlay lists active/recent sessions.
- Shows status, title, cwd, elapsed time, active tool/tool count.
- Non-intrusive and usable while app is unfocused.

Tests/contracts:

- SwiftUI preview or snapshot-style assertions if available.
- Manual smoke with fake sessions in all statuses.

Done when:

- Multiple sessions are visible in compact form.

### Task 4.3 — Expanded session detail

Requirements:

- Show task title, status, cwd/worktree/branch when known, last summary, active tool, recent log preview, changed files, pending question.
- Buttons: Open report, Open terminal/debug, Follow up, Stop, Copy summary.

Tests/contracts:

- Fake session with pending extension UI renders waiting state.
- Stop button sends `abort` command.

Done when:

- User can inspect and control a long-running session from overlay.

### Task 4.4 — Tool activity rows

Requirements:

- Render started/running/succeeded/failed tool states.
- Show safe preview of args/output.
- Highlight risk-relevant tools (bash, edit/write, external MCP/DB/Slack) based on tool name metadata, without blocking/routing.

Tests/contracts:

- Tool start/update/end fixture updates one row by `toolCallId`.
- Failed tool is visible with error state.

Done when:

- HUD makes agent activity observable.

### Task 4.5 — Completion/failure/waiting notifications

Requirements:

- Completion: `분석이 끝났습니다` or task-specific short message.
- Failure: concise error + open logs.
- Waiting: badge + prompt.
- PR URL: display as chip when artifact detected.

Tests/contracts:

- Notification adapter tested with fake notification center.
- No duplicate notifications for same terminal event.

Done when:

- Long-running tasks can finish in background and notify clearly.

## Phase 5 — Follow-up and session selection

Goal: continue the same Pi session naturally by voice/text.

### Task 5.1 — Session selection model

Requirements:

- User can select session from HUD.
- If none selected, default to most recently active/completed.
- Explicit cwd override remains possible at task creation.

Tests/contracts:

- Selection persists across HUD collapse/expand.
- Default selection follows most recent completed session.

Done when:

- Follow-ups target predictable sessions.

### Task 5.2 — Text follow-up field

Requirements:

- Expanded HUD includes text field.
- Submit sends `followUp` to selected session.
- While running, user can choose follow-up vs steer if UI exposes both.

Tests/contracts:

- Fake client receives correct session id and command type.
- Empty follow-up is rejected client-side.

Done when:

- Text continuation works without voice.

### Task 5.3 — Voice follow-up flow

Requirements:

- Push-to-talk while a session is selected sends source `voice-follow-up`.
- If no session exists, it creates a new task.
- Transcript confirmation/error handling is visible.

Tests/contracts:

- Dictation manager fake transcript routes to follow-up/create correctly.

Done when:

- `수정 PR까지 올려줘` can continue prior investigation.

### Task 5.4 — Abort/stop and terminal/debug handoff

Requirements:

- Stop button sends `abort` and updates UI optimistically/pessimistically based on response.
- Open terminal/debug view shows daemon/Pi session logs or opens a terminal at cwd/session info.

Tests/contracts:

- Abort command fixture handled.
- Failed abort surfaces error.

Done when:

- User can safely stop or inspect stuck sessions.

## Phase 6 — Work artifacts and reports

Goal: persist useful outputs and show completed reports.

### Task 6.1 — Persist screenshots, prompts, and session metadata

Requirements:

- Each task stores captured screenshots, initial prompt, context packet, session metadata.
- Sensitive raw data is not uploaded remotely.
- Storage path is deterministic and app-support scoped.

Tests/contracts:

- Restart reloads metadata and screenshot references.
- Missing screenshot path degrades gracefully.

Done when:

- Session context is durable.

### Task 6.2 — Generate report markdown from final answer and artifacts

Requirements:

- Create a markdown report when session completes.
- Include final answer, tool summary, artifact links, PR URL if detected.
- Keep report neutral; do not fabricate verification status.

Tests/contracts:

- Fixture session produces stable report markdown.
- Report generation handles failed/cancelled sessions.

Done when:

- Completed sessions have a report artifact.

### Task 6.3 — Report/artifact viewer

Requirements:

- Open report from HUD.
- Show local markdown or render safely.
- Copy summary/report path.

Tests/contracts:

- Viewer opens existing report.
- Missing report shows clear error.

Done when:

- User can read completed results without terminal switching.

### Task 6.4 — Changed files and PR link artifacts

Requirements:

- Track changed file summaries when Pi/tool events or git metadata expose them.
- Detect PR links from final output/tool logs as artifacts, not policy.
- Show PR chip in HUD.

Tests/contracts:

- URL extraction recognizes GitHub PR URL from final answer.
- Does not infer PR state without explicit URL/artifact.

Done when:

- Shipping/hotfix flows are easier to monitor.

## Phase 7 — Advanced macOS context

Goal: enrich neutral desktop context capture.

### Task 7.1 — Browser URL/title extraction

Requirements:

- Support Chrome/Safari/Arc if feasible through accessibility/AppleScript APIs.
- Extract URL/title only; do not interpret route.
- Permission failures are visible and non-fatal.

Tests/contracts:

- Fake browser provider returns expected metadata.
- Sentry/Slack URLs remain neutral in prompt tests.

Done when:

- Browser context is available to Pi.

### Task 7.2 — Selected text extraction

Requirements:

- Capture selected text from active app where permitted.
- Limit size and indicate truncation.
- Do not copy clipboard destructively without restoring it.

Tests/contracts:

- Text truncation tested.
- Permission failure returns nil + warning.

Done when:

- Pi receives selected text as neutral context.

### Task 7.3 — Active app/window metadata robustness

Requirements:

- Bundle id, localized name, pid, window title/frame.
- Multi-display coordinate consistency with screenshot labels.

Tests/contracts:

- Fake windows/screens produce stable packet.
- Coordinates match `[POINT:x,y:label:screenN]` convention.

Done when:

- Screen context is reliable enough for pointing.

### Task 7.4 — Optional region screenshot handoff

Requirements:

- Let user capture a region if full screen is too broad.
- Store and label region screenshots consistently.

Tests/contracts:

- Region metadata validates bounds.

Done when:

- Context capture can be narrower when needed.

## Phase 8 — Polish and settings

Goal: make the MVP comfortable for daily use.

### Task 8.1 — Settings UI

Requirements:

- Default cwd editable.
- Worktree parent/preferred tool visible as settings but not hard-routed.
- Read-only investigation preference can be displayed/passed as context if implemented, but should not silently override Pi permissions.
- Daemon path/log path visible.

Tests/contracts:

- Settings persist and reload.
- Invalid cwd shows validation error.

Done when:

- User can configure the MVP without editing files.

### Task 8.2 — Diff preview

Requirements:

- Show file diff preview when available.
- Do not run destructive git commands.
- Large diffs are truncated safely.

Tests/contracts:

- Diff truncation and file grouping tested.

Done when:

- User can inspect implementation sessions from HUD.

### Task 8.3 — Better summaries and archive/search

Requirements:

- Session archive/search by title, cwd, status, PR URL, summary.
- Summary source is final Pi answer or explicit artifact, not fabricated by Picky.

Tests/contracts:

- Search over fixture sessions.
- Archived sessions disappear from active HUD but remain retrievable.

Done when:

- Long-term session history is manageable.

### Task 8.4 — Final product hardening

Requirements:

- Permission copy explains microphone/screen/accessibility needs.
- Clear failure states for missing Pi, missing auth/model, daemon crash.
- App icon/name/package metadata finalized.

Tests/contracts:

- Missing `pi`/SDK dependency path has friendly error.
- Permission-denied flows do not crash.

Done when:

- Picky is usable as a local daily driver MVP.

## Recommended task bundles for subagents

Use sequential worker → verifier chains for each bundle. Do not run multiple workers in parallel if they touch the same Swift project files. Parallelism is safe only for independent read-only research or daemon-only vs app-only work after Phase 0 is stable.

### Bundle A — Phase 0 foundation

Scope:

- Tasks 0.1–0.4.
- Import public Clicky source.
- Preserve `AGENTS.md` and `ARCHITECTURE.md`.
- Rename/build Picky baseline.

Worker output required:

- Changed files.
- Upstream provenance.
- Exact build/test commands run and outputs.
- Any build blockers.

Verifier output required:

- Independent build/test or clear reproduction of blocker.
- Grep identity check.
- Confirmation that local planning docs were not overwritten.

### Bundle B — Phase 1 local-first stripping

Scope:

- Tasks 1.1–1.4.
- Remove remote backend/analytics/TTS/STT defaults.
- Preserve hotkey, overlay, screenshot, permission primitives.

Can start:

- After Bundle A builds.

Verifier focus:

- Safety grep for SaaS/remotes.
- Build/test.
- No loss of macOS primitives.

### Bundle C — Phase 2 daemon protocol and mock supervisor

Scope:

- Tasks 2.1–2.5.
- TypeScript package, protocol fixtures, local transport, mock session supervisor, neutral prompt builder.

Can start:

- After Bundle A creates repo baseline. It can run in parallel with Bundle B if it only touches `agentd/` and `contracts/`.

Verifier focus:

- `pnpm --dir agentd typecheck/test/build`.
- Contract fixture validation.
- Neutrality checks for prompt builder.

### Bundle D — Phase 2 Pi adapter and extension UI bridge

Scope:

- Tasks 2.6–2.8.
- Pi SDK adapter, event normalizer, extension UI bridge, artifact/log store.

Can start:

- After Bundle C protocol and supervisor are stable.

Verifier focus:

- Mocked Pi event tests.
- No live model dependency in default tests.
- SDK API usage matches official docs.

### Bundle E — Phase 3 Swift-daemon bridge

Scope:

- Tasks 3.1–3.5.
- Swift protocol models, daemon launcher, WebSocket client, context packet assembly, basic streaming display.

Can start:

- After Bundle C protocol fixtures exist.
- Best after Bundle B has stripped old backend.

Verifier focus:

- Swift decodes shared fixtures.
- Fake WebSocket/client tests.
- App build/test.

### Bundle F — Phase 4 HUD MVP

Scope:

- Tasks 4.1–4.5.
- Multi-session card overlay, expanded detail, tool rows, notifications.

Can start:

- After Bundle E exposes session view models/events.

Verifier focus:

- Status machine tests.
- Fake sessions for all statuses.
- Manual/snapshot evidence for top-right HUD.

### Bundle G — Phase 5 + Phase 6 continuation and artifacts

Scope:

- Tasks 5.1–5.4 and 6.1–6.4.
- Follow-up voice/text, session selection, abort/debug, reports/artifacts.

Can start:

- After Bundle F HUD controls exist.

Verifier focus:

- Follow-up targets correct session.
- Persistence/restart tests.
- Report/artifact path safety.

### Bundle H — Phase 7 + Phase 8 context polish

Scope:

- Tasks 7.1–7.4 and 8.1–8.4.
- Advanced context, settings, diff preview, archive/search, hardening.

Can start:

- After core MVP path is working.

Verifier focus:

- No deterministic routers.
- Permission failure tests.
- Settings persistence and safety.

## Subagent execution protocol

For each bundle, run a chain:

1. `worker`: implement the bundle; run self-checks; do not commit unless explicitly asked.
2. `verifier`: independently validate changed files and commands; report evidence.
3. Optional `reviewer` or `security-auditor`: use after large or security-sensitive bundles, especially D, E, G, H.

Worker prompt template:

```markdown
Implement Bundle <X> from `TASKS.md`.

Hard constraints:
- Preserve current user edits in `AGENTS.md` and `ARCHITECTURE.md`.
- Do not commit.
- Do not add deterministic task routing.
- Keep tests/contracts rigorous.
- Report changed files, commands run, outputs, and blockers.

Read only the relevant phase/bundle sections, then implement.
```

Verifier prompt template:

```markdown
Verify Bundle <X> implementation.

Check:
- Required files and behavior from `TASKS.md`.
- Build/test/typecheck commands with concrete output.
- Contract fixtures where applicable.
- No deterministic routers or remote SaaS regressions.
- No accidental overwrite of `AGENTS.md` / `ARCHITECTURE.md`.

Do not modify files unless the verification task explicitly asks for tiny test harness fixes. Prefer reporting exact failures.
```

## Current recommended start

Start with **Bundle A** as a sequential chain:

```bash
subagent chain --main \
  --agent worker --task "Implement Bundle A — Phase 0 foundation from TASKS.md. Preserve AGENTS.md and ARCHITECTURE.md, import public Clicky source, rename/build Picky baseline, do not commit, report commands and blockers." \
  --agent verifier --task "Verify Bundle A implementation from TASKS.md. Confirm provenance docs, Picky rename/build/test baseline, no overwritten planning docs, and report exact evidence."
```

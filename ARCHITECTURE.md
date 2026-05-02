# Picky Architecture Plan

_Last updated: 2026-05-02_

## 1. Goal

Picky is a macOS-level command center for local Pi agent sessions.

The problem to solve is not "make another chat app." The problem is that multiple Ghostty/Pi terminal sessions create too much context switching. Picky should let the user invoke a local Pi agent from the current macOS context, then monitor and steer long-running work from a compact overlay.

Target experience:

```text
User is looking at a Sentry issue in the browser
→ presses Ctrl+Option
→ says: "이 에러 원인 분석해줘"
→ Picky captures current desktop context neutrally
→ Picky starts or resumes a local Pi session for ~/Product
→ Pi decides which skills/tools/MCPs to use
→ Pi investigates Sentry, code, DB, Slack, etc. as needed
→ Picky shows a top-right long-running agent card
→ when done, Picky says/shows "분석이 끝났습니다" and opens the report
→ user says: "수정 PR까지 올려줘"
→ the same Pi session continues with the previous analysis context
→ Pi creates worktree/branch, fixes, verifies, ships, and opens a hotfix PR
```

## 2. Core Design Correction

Picky should **not** implement deterministic task routing such as:

- "If URL matches `acme.sentry.io/issues/...`, force Sentry flow"
- "If Slack URL, force Slack flow"
- "If user says DB, force creatrip-db flow"

That logic already belongs to Pi's model + skills + extensions. Picky should provide context, not policy.

### Principle

```text
Picky captures and presents context.
Pi interprets intent and chooses skills/tools/MCPs.
```

This keeps Picky thin, avoids duplicated routing logic, and lets existing Pi skill descriptions remain the source of truth.

## 3. Non-goals

Picky v1 will not:

- Reimplement Pi skills.
- Reimplement the MCP bridge.
- Hard-code Sentry/Slack/DB/Notion routing rules.
- Bundle a private Clicky/Codex runtime.
- Add auth, billing, Supabase, PostHog, or remote SaaS backend.
- Replace Pi's model/tool/session semantics with a custom protocol.

## 4. Reuse Strategy

### From public Clicky source

Use the public MIT Clicky repo as a macOS UX foundation:

- Menu bar app structure.
- Global push-to-talk shortcut.
- Microphone/STT pipeline.
- ScreenCaptureKit multi-display screenshot capture.
- Floating cursor / overlay window.
- Permission flow patterns.
- `[POINT:x,y:label:screenN]` coordinate convention.

Relevant public files:

- `leanring-buddy/CompanionManager.swift`
- `leanring-buddy/BuddyDictationManager.swift`
- `leanring-buddy/BuddyTranscriptionProvider.swift`
- `leanring-buddy/CompanionScreenCaptureUtility.swift`
- `leanring-buddy/OverlayWindow.swift`
- `leanring-buddy/MenuBarPanelManager.swift`
- `leanring-buddy/WindowPositionManager.swift`

### From observed local Clicky behavior

Recreate the product ideas, not the private implementation:

- Long-running agent cards.
- Agent HUD with tool activity.
- Follow-up voice/text into an active task.
- File diff preview.
- Completion chime/notification.
- Report/artifact presentation.
- Multi-session overview.

## 5. High-level Architecture

```text
┌────────────────────────────────────────────────────────────┐
│                        Picky.app                            │
│                   SwiftUI + AppKit macOS                    │
│                                                            │
│  Hotkey/STT  Context Capture  Overlay HUD  Session Control  │
└───────────────┬────────────────────────────────────────────┘
                │ local WebSocket or Unix domain socket
                ▼
┌────────────────────────────────────────────────────────────┐
│                    picky-agentd                             │
│                 Node/TypeScript daemon                      │
│                                                            │
│  Session Supervisor  Pi SDK Runtime  Artifact Store         │
│  Event Normalizer    Process Lifecycle  App Bridge          │
└───────────────┬────────────────────────────────────────────┘
                │ Pi SDK
                ▼
┌────────────────────────────────────────────────────────────┐
│                    Local Pi Runtime                         │
│                                                            │
│  ~/.pi/agent settings, skills, extensions, MCP bridge       │
│  read/bash/edit/write, creatrip tools, sentry/slack skills  │
└────────────────────────────────────────────────────────────┘
```

Why a daemon instead of Swift spawning one `pi --mode rpc` process per request?

- We need multiple long-running sessions.
- We need central lifecycle management.
- We need stable session metadata and artifact storage.
- We need richer Pi SDK access than subprocess RPC alone provides.
- We need to preserve existing Pi resource discovery and extension behavior.

Pi RPC remains useful as a fallback/debug integration, but the primary backend should be the Pi SDK via `picky-agentd`.

### Current implementation snapshot

The current codebase follows this split:

- `Picky/`: SwiftUI/AppKit macOS shell. App/menu bar, settings, companion voice flow, dictation helpers, context capture, overlay windows, HUD rendering, session selection/archive state, and daemon launch/client code live here.
- `Picky/Context/`: neutral context packet assembly and app-support screenshot storage helpers. Advanced browser/window/selection capture remains in `Picky/PickyAdvancedContext.swift`.
- `Picky/Companion/` and `Picky/Companion/Dictation/`: companion panel components plus speech, audio conversion, transcription, and global shortcut helpers.
- `Picky/HUD/`, `Picky/Overlay/`, `Picky/Sessions/`, `Picky/App/Settings/`: focused Swift modules for session UI, overlay lifecycle/layout, persisted session UI state, and user settings.
- `agentd/src/`: TypeScript daemon with root WebSocket server/runtime entry points plus focused `application/`, `domain/`, and `runtime/` helpers. `SessionSupervisor` remains the facade for app-visible session operations.
- `agentd/src/server.ts` and `agentd/src/runtime/pi-sdk-runtime.ts` intentionally remain unsplit while they are small and readable; transport/runtime extraction is deferred until it clearly reduces complexity.

## 6. Picky.app Responsibilities

### 6.1 Input capture

- Global shortcut: default `Ctrl+Option`.
- Push-to-talk voice capture.
- Optional text follow-up field in overlay.
- Abort/stop shortcut.

### 6.2 Neutral context capture

Picky captures context without deciding what it means.

Context packet fields:

```ts
type PickyContextPacket = {
  source: "voice" | "text" | "voice-follow-up" | "text-follow-up";
  transcript: string;
  timestamp: string;
  activeApplication?: {
    bundleIdentifier?: string;
    localizedName?: string;
    processIdentifier?: number;
  };
  activeWindow?: {
    title?: string;
    frame?: { x: number; y: number; width: number; height: number };
  };
  browser?: {
    url?: string;
    title?: string;
    selectedText?: string;
  };
  screens: Array<{
    label: string;
    isCursorScreen: boolean;
    imagePath: string;
    widthPixels: number;
    heightPixels: number;
    displayFrame: { x: number; y: number; width: number; height: number };
  }>;
  defaultCwd?: string;
  selectedSessionId?: string;
};
```

Important: even if the browser URL is Sentry, Picky only includes it as context. Pi decides whether to load `sentry-investigate`, use MCP, search code, query DB, or ask a clarification.

### 6.3 Overlay HUD

The overlay should be the main value proposition.

Collapsed card:

```text
[Sentry analysis] running · ~/Product · 4 tools · 13m
[Hotfix PR] waiting · hotfix/payment-callback · needs approval
[Release audit] done · report ready
```

Expanded card:

- Task title.
- Status.
- CWD/worktree/branch.
- Last assistant summary.
- Active tool call.
- Recent tool log preview.
- Changed files summary.
- Pending question / extension UI request.
- Buttons: Open report, Open terminal, Follow up, Stop, Copy summary.

### 6.4 Notifications

- Completion: "분석이 끝났습니다".
- Failure: concise error + open logs.
- Waiting for input: badge + prompt.
- PR ready: show PR URL.

## 7. picky-agentd Responsibilities

### 7.1 Session Supervisor

Owns long-running Pi sessions.

```ts
type PickyAgentSession = {
  id: string;
  piSessionId: string;
  piSessionFile?: string;
  title: string;
  status: "queued" | "running" | "waiting_for_input" | "blocked" | "completed" | "failed" | "cancelled";
  cwd: string;
  createdAt: string;
  updatedAt: string;
  sourceContext?: PickyContextPacket;
  currentPhase?: string;
  lastSummary?: string;
  activeTool?: PickyToolActivity;
  toolHistory: PickyToolActivity[];
  artifacts: PickyArtifact[];
  changedFiles?: PickyChangedFile[];
};
```

Supervisor actions:

- Create session.
- Resume session.
- Follow up into session.
- Steer active session.
- Abort.
- Archive.
- Open report.
- Attach terminal/debug view.

### 7.2 Pi SDK Runtime

Use Pi SDK instead of hard-coded subprocess control.

Primary SDK concepts:

- `createAgentSessionRuntime()` for replaceable session runtime.
- `createAgentSessionServices()` / `createAgentSessionFromServices()` for default Pi services.
- `DefaultResourceLoader` to load existing `~/.pi/agent` resources.
- `SessionManager.create(cwd)` for persistent sessions.
- `session.subscribe()` for streaming events.
- `session.prompt()`, `session.steer()`, `session.followUp()`, `session.abort()`.

Picky should preserve the user's existing Pi environment:

- `~/.pi/agent/settings.json`
- `~/.pi/agent/skills`
- `~/.pi/agent/extensions`
- installed Pi packages
- MCP bridge extension
- memory layer
- custom bash/edit wrappers

### 7.3 Event Normalizer

Pi events are rich and low-level. The daemon should normalize them for the Swift HUD.

Mapping:

```text
agent_start             → session.status = running
message_update          → live assistant text / short summary candidate
tool_execution_start    → activeTool started
tool_execution_update   → activeTool output updated
tool_execution_end      → activeTool finished
queue_update            → queued follow-ups displayed
extension_ui_request    → status = waiting_for_input
agent_end               → completed or awaiting follow-up
error/abort             → failed/cancelled
```

### 7.4 Artifact Store

Store durable task outputs under:

```text
~/Library/Application Support/Picky/
  sessions/
  artifacts/
  screenshots/
  reports/
  logs/
```

Artifacts:

- Markdown report.
- Captured screenshots.
- Final answer.
- PR link.
- Diff summary.
- Tool logs.

## 8. Prompting Model

Picky should build a neutral task prompt. It should not tell Pi which skill to use unless the user explicitly asks.

Example generated prompt:

```markdown
You are running from Picky, a macOS overlay for local Pi.

The user invoked Picky from their current desktop context and said:

> 이 에러 원인 분석해줘

Current context:
- Active app: Google Chrome
- Active window title: <title>
- Browser URL: <url>
- Default working directory: ~/Product
- Screenshots are attached and labeled by screen.

Use the available Pi skills, extensions, MCPs, and local CLI tools as appropriate.
Do not assume the URL type from Picky; inspect the context and decide the right workflow yourself.
If this becomes a long-running investigation, provide concise progress updates.
When done, produce a clear report and a final short status line for Picky.
If pointing at something on screen is useful, append [POINT:x,y:label:screenN]. Otherwise append [POINT:none].
```

For follow-up:

```markdown
The user is following up on the active Picky session:

> 수정 PR까지 올려줘

Continue from the existing investigation context. Use available skills/tools as appropriate.
```

## 9. Existing Pi Capabilities Picky Should Rely On

Picky should lean on these current Pi assets instead of duplicating them:

- `sentry-investigate` skill: Sentry issue investigation.
- `hotfix-flow` skill: production hotfix PR flow.
- `ship` skill: commit, verify, push.
- `creatrip-db-query` skill: read-only Creatrip DB CLI workflow.
- `slack-thread-context` skill: Slack thread loading.
- `notion-context` skill: Notion context loading.
- `systematic-debugging` skill: root-cause debugging.
- `stress-interview`, `self-healing`, `simplify`: quality loops.
- Existing MCP bridge extension.
- Existing memory/todo/diff/review extensions.

Picky's job is to make these easier to invoke and monitor from macOS.

## 10. Long-running Agent Requirements

This is required, not optional.

### 10.1 Multi-session

- Multiple active sessions can run concurrently.
- Each has its own cwd, Pi session file, title, and status.
- The overlay shows all active/recent sessions.

### 10.2 Session continuation

- Follow-up voice/text should go to the selected session.
- If no session is selected, default to the most recently active/completed session.
- User can explicitly choose a different session from the overlay.

### 10.3 Background execution

- Sessions continue when overlay is collapsed.
- Sessions continue when Picky is not focused.
- Picky can reconnect to `picky-agentd` and rebuild HUD state.

### 10.4 Input requests

When Pi extensions ask for confirmation/input, Picky must surface it natively.

Examples:

- Dangerous command confirmation.
- Worktree/base branch choice.
- Missing credential/token request.
- Hotfix suitability confirmation.

This maps naturally to Pi RPC/extension UI concepts, but in SDK mode the daemon may need an app-facing bridge for extension UI events.

## 11. Sentry Investigation Scenario without Hard-coded Routing

No deterministic Sentry router.

Flow:

```text
Picky captures:
- transcript: "이 에러 원인 분석해줘"
- active URL: https://acme.sentry.io/issues/...
- screenshots
- cwd: ~/Product

Pi receives neutral context.
Pi reads available skills.
Because sentry-investigate skill describes Sentry URL triggers, Pi chooses that workflow.
Pi may then use Sentry MCP, fetch, code search, Slack, DB, or other tools as needed.
Picky only observes and renders progress.
```

This preserves agent autonomy and keeps workflows evolvable by editing skills, not Picky app code.

## 12. Follow-up Hotfix Scenario

```text
User: "수정 PR까지 올려줘"
Picky: sends follow-up to selected/completed Sentry investigation session
Pi: uses prior report context
Pi: decides hotfix-flow is appropriate
Pi: may ask confirmation if risk gates trigger
Pi: creates worktree/branch, edits code, verifies, ships, opens PR
Picky: shows status, changed files, PR link, and final summary
```

Picky does not implement hotfix policy. The `hotfix-flow` and `ship` skills do.

## 13. Worktree/CWD Strategy

Default project root:

```text
~/Product
```

Picky settings should allow:

- Default cwd.
- Per-session cwd override.
- Worktree parent directory.
- Preferred worktree tool: `gw`, `gws`, or plain `git worktree`.

But the actual decision to create worktree/branch should remain with Pi/skills unless user config says otherwise.

## 14. Security Model

Picky makes local Pi more powerful because it lowers friction. Therefore it must make risk visible.

Required UI indicators:

- Current cwd.
- Current branch/worktree.
- Whether tool mode is full-access/read-only.
- Active destructive command confirmations.
- MCP/DB/Slack access surfaced through tool activity.

Recommended settings:

- Default mode: use existing Pi settings.
- Optional read-only mode for investigations.
- Optional confirmation before PR creation.
- Optional confirmation before DB production query if Pi skill requests it.

Do not silently downgrade or override Pi's configured permissions; display them.

## 15. Implementation Plan

### Phase 0 — Repository setup

- Create `~/Documents/picky`.
- Copy public Clicky source into project repo.
- Rename app/product/bundle identifiers to Picky.
- Add this architecture document.

### Phase 1 — Strip remote Clicky backend

- Remove Cloudflare Worker dependency from app flow.
- Remove hard-coded Claude/ElevenLabs/AssemblyAI URLs.
- Remove analytics and email capture.
- Keep menu bar, overlay, hotkey, permission, screenshot, and cursor code.

### Phase 2 — Create `picky-agentd`

- Node/TypeScript package inside repo.
- Use Pi SDK.
- Start one persistent Pi session with default resource discovery.
- Accept `createTask`, `followUp`, `steer`, `abort`, `listSessions` over local socket.
- Stream normalized events to app.

### Phase 3 — Connect Swift app to daemon

- Launch daemon on app start.
- Reconnect if daemon restarts.
- Send transcript + screenshots + context packet.
- Display streaming response and tool lifecycle.

### Phase 4 — Long-running HUD MVP

- Top-right session card overlay.
- Expanded session detail.
- Status machine.
- Tool activity rows.
- Completion notification.
- Report artifact viewer.

### Phase 5 — Follow-up and session selection

- Voice/text follow-up into selected session.
- Most-recent-session default.
- Abort/stop.
- Open terminal/debug session.

### Phase 6 — Work artifacts and reports

- Persist screenshots, prompts, reports, PR links, logs.
- Auto-generate report markdown from final Pi answer and artifacts.
- Show completed report from overlay.

### Phase 7 — Advanced macOS context

- Browser URL/title extraction.
- Selected text extraction.
- Active app/window metadata.
- Optional region screenshot handoff.
- Optional clipboard context.

### Phase 8 — Polish

- File diff preview.
- PR link chip.
- Better summaries.
- Session archive/search.
- App settings UI.

## 16. Resolved Questions

1. Should `picky-agentd` run as a child process of Picky.app or as a LaunchAgent?
   - **Decision**: run `picky-agentd` as a child process of Picky.app for v1/MVP.
   - Rationale: prioritize implementation speed and simple lifecycle control. Picky starts the daemon on app launch and owns shutdown/restart behavior.
   - Not in MVP: LaunchAgent persistence across app restarts. Revisit only after the core long-running session UX is validated.

2. Should Picky use the same `~/.pi/agent` session directory or a Picky-specific session directory?
   - **Decision**: use normal Pi session storage plus separate Picky metadata.
   - Pi session JSONL files stay in the standard `~/.pi/agent/sessions` location so Ghostty/Pi and Picky can inspect or resume the same underlying sessions.
   - Picky-specific state stays under `~/Library/Application Support/Picky/`, including overlay card metadata, task status, screenshots, reports, logs, and app-level artifacts.

3. Should the app default to `~/Product` or infer cwd from frontmost terminal/editor?
   - **Decision**: make the default working directory configurable in Picky settings.
   - Initial/default value can be `~/Product` for the user's current Creatrip workflow, but it must be editable from the app settings.
   - Each task should use the configured default unless the user explicitly overrides the cwd from the overlay/session controls.
   - Do not rely on fragile frontmost terminal/editor cwd inference for v1.

4. How should extension UI be bridged in SDK mode?
   - **Decision**: support Pi extension UI requests with native Picky UI from v1.
   - Confirm/select/input/editor-style requests should surface through macOS-native overlay or modal components instead of falling back to the terminal.
   - `picky-agentd` must expose an app-facing extension UI bridge so Pi sessions can pause in `waiting_for_input` and resume after the user answers in Picky.
   - Implementation note: study Pi RPC's documented `extension_ui_request` semantics and mirror the same concepts in the SDK-backed daemon/app protocol.

5. How much of public Clicky should be kept versus rewritten?
   - **Decision**: fork/copy the public Clicky source and incrementally refactor it into Picky.
   - Rationale: preserve working macOS primitives first: menu bar, hotkey, permissions, ScreenCaptureKit, overlay/cursor, and push-to-talk behavior.
   - Refactor direction: remove remote backend/analytics/SaaS pieces early, then rename/reorganize modules around Picky concepts as the Pi-backed long-running agent UX stabilizes.

## 17. References

### Pi official docs

Resolve the installed `@mariozechner/pi-coding-agent` package location from the current environment, then read:

- `README.md`
  - Pi modes, SDK, RPC, extensions, skills, packages, CLI behavior.
- `docs/sdk.md`
  - `createAgentSession`, `createAgentSessionRuntime`, `DefaultResourceLoader`, sessions, tools, events.
- `docs/rpc.md`
  - JSONL RPC protocol, event stream, extension UI request/response protocol.
- `docs/extensions.md`
  - Extension lifecycle, event hooks, tool events, input/context hooks.
- `docs/session-format.md`
  - Pi session JSONL format and tree semantics.

### Public Clicky source

- `https://github.com/farzaa/clicky/`
- Optional local analysis clone: a developer-created temporary checkout of the upstream repository.
- Key architecture doc, if an upstream checkout is available: `CLAUDE.md`.

### Local installed Clicky app reference

A locally installed Clicky app may be used as a behavioral/product reference for long-running agent UX when a developer has it available, not as code to copy blindly. Do not depend on a fixed installation path.

Suggested reference areas, if available locally:

- App bundle, binary, bundle metadata, and build metadata.
- Embedded app notes/model instructions, bundled skills, bundled wiki seed, and bundled runtime references.
- User data/runtime state.

Important constraint: the local Clicky app is a private compiled product. Treat it as a reverse-engineering reference for architecture and UX ideas only. Picky should use public Clicky MIT source plus clean-room reimplementation for private/local Clicky behaviors.

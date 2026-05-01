# AGENTS.md - Picky Project Context

## Why this project exists

The user currently runs many Pi sessions in Ghostty for investigation, debugging, implementation, and shipping work. This creates too much context switching: multiple terminal windows, scattered task state, unclear long-running progress, and weak continuity between investigation and follow-up actions.

Picky exists to turn local Pi into a macOS-level agent command center.

The intended product is not a generic chat app. It is a desktop overlay that lets the user invoke local Pi from the current screen context, monitor multiple long-running Pi sessions from the top-right of macOS, and continue work naturally by voice or text.

Example target workflow:

1. User is viewing a Sentry issue in the browser.
2. User presses `Ctrl+Option` and says: `이 에러 원인 분석해줘`.
3. Picky captures neutral context: transcript, active app/window, browser URL/title, screenshots, selected/default cwd.
4. Picky starts or resumes a local Pi session.
5. Pi decides which skills, extensions, MCPs, CLIs, and codebase tools to use.
6. Pi investigates the issue using available tools such as Sentry MCP, local code search, Creatrip DB CLI, Slack history, etc.
7. Picky shows progress in a compact long-running agent overlay.
8. When complete, Picky reports: `분석이 끝났습니다` and presents the analysis report.
9. If the user follows up with `수정 PR까지 올려줘`, Picky sends that follow-up to the same Pi session, preserving context.
10. Pi performs the implementation/hotfix/ship/PR flow using existing skills and tools.

## What the user wants

The user wants:

- A macOS app named **Picky**.
- Built on top of the public Clicky source where useful.
- Backend replaced with the user's **local Pi** environment.
- A top-right overlay that summarizes multiple Pi sessions.
- Long-running agent support as a first-class requirement.
- Voice invocation via `Ctrl+Option`.
- Neutral desktop context capture.
- Follow-up voice/text to active or recently completed sessions.
- Existing Pi skills/extensions/MCP bridge to remain the source of task intelligence.
- No hard-coded task router in Picky.

## Core architecture principle

Picky captures context. Pi interprets intent.

Do **not** build deterministic routing logic into Picky such as:

- If URL matches Sentry, run Sentry flow.
- If Slack URL, run Slack flow.
- If user mentions DB, force a DB tool.

Those decisions belong to Pi's model, skills, and extensions.

Picky should pass rich context and let Pi decide:

- which skill to load,
- which MCP/tool to call,
- whether to ask for clarification,
- whether a hotfix flow is appropriate,
- whether a DB/Slack/Sentry lookup is necessary.

## Required long-running agent behavior

Long-running agent functionality is mandatory.

Picky must support:

- Multiple active Pi sessions.
- Session cards in the top-right overlay.
- Session state: queued, running, waiting_for_input, blocked, completed, failed, cancelled.
- Tool activity display.
- Recent log/output preview.
- Follow-up messages into the selected session.
- Abort/stop.
- Completion notifications.
- Report/artifact viewing.
- Persistence/reconnect after app/daemon restart.

## Preferred backend design

Use a local daemon:

```text
Picky.app (SwiftUI/AppKit)
→ picky-agentd (Node/TypeScript)
→ Pi SDK runtime
→ local ~/.pi/agent skills/extensions/MCP/tools
```

Reasoning:

- One-off `pi --mode rpc` is too limited for multi-session long-running orchestration.
- Pi SDK exposes session runtime, event subscriptions, resource loading, and session management.
- A daemon can supervise multiple Pi sessions and normalize events for the Swift app.

RPC mode can still be useful for debugging or fallback, but the primary design should use Pi SDK in `picky-agentd`.

## Existing Pi assets to rely on

Do not duplicate these in Picky. Let Pi use them naturally.

Current relevant skills include:

- `sentry-investigate` - Sentry issue investigation.
- `hotfix-flow` - production hotfix PR flow.
- `ship` - commit, verify, push.
- `creatrip-db-query` - safe read-only Creatrip DB CLI workflow.
- `slack-thread-context` - Slack thread loading.
- `notion-context` - Notion context loading.
- `systematic-debugging` - root-cause debugging.
- `stress-interview`, `self-healing`, `simplify` - quality/review loops.

Existing Pi extensions/packages include MCP bridge support and other workflow extensions. Picky should load the user's existing `~/.pi/agent` resources instead of reinventing them.

## Public Clicky reuse guidance

Public Clicky source is MIT licensed and can be used as the macOS shell foundation.

Useful areas:

- Menu bar app structure.
- Global push-to-talk shortcut.
- STT/microphone flow.
- ScreenCaptureKit multi-display capture.
- Overlay/cursor rendering.
- Permission handling.
- `[POINT:x,y:label:screenN]` convention.

Remove or replace:

- Cloudflare Worker API proxy.
- Claude direct chat backend.
- ElevenLabs remote TTS dependency.
- AssemblyAI token flow if not needed.
- PostHog/FormSpark analytics/email capture.
- SaaS auth/billing/paywall concepts.

Observed local Clicky features can be recreated as product behavior, but do not copy private implementation.

## Key documents in this folder

- `ARCHITECTURE.md` - Main architecture and implementation plan.
- `AGENTS.md` - This file. Project intent and future-agent guidance.

## Required references

When working on this project, use these references.

### Picky planning

- `~/Documents/picky/ARCHITECTURE.md`

### Public Clicky source

- GitHub: `https://github.com/farzaa/clicky/`
- Local analysis clone, if still present: `/tmp/clicky-re/upstream`
- Important files:
  - `CLAUDE.md`
  - `leanring-buddy/CompanionManager.swift`
  - `leanring-buddy/BuddyDictationManager.swift`
  - `leanring-buddy/BuddyTranscriptionProvider.swift`
  - `leanring-buddy/CompanionScreenCaptureUtility.swift`
  - `leanring-buddy/OverlayWindow.swift`
  - `leanring-buddy/MenuBarPanelManager.swift`
  - `leanring-buddy/WindowPositionManager.swift`

### Pi docs

Read relevant Pi docs before implementing Pi integration:

- `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/README.md`
- `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/sdk.md`
- `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/rpc.md`
- `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/extensions.md`
- `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/docs/session-format.md`
- `/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/examples/sdk/`

## Implementation priorities

1. Preserve the intent: macOS Pi session command center.
2. Keep Picky thin: context capture + overlay + session control.
3. Keep intelligence in Pi: skills/extensions/MCP/tools decide workflow.
4. Build long-running session supervision early.
5. Prefer existing Pi environment and resource discovery.
6. Avoid hard-coded Creatrip/Sentry/Slack task logic in Picky.
7. Make permission and execution risk visible in the UI.

## Initial implementation phases

Follow `ARCHITECTURE.md`, but the high-level order is:

1. Create/rename Picky app from public Clicky source.
2. Strip remote Clicky backend and analytics.
3. Create `picky-agentd` with Pi SDK.
4. Connect Swift app to daemon.
5. Implement long-running top-right session HUD.
6. Add follow-up voice/text into selected session.
7. Persist reports/artifacts/session metadata.
8. Add advanced context capture and polish.

## Design constraints

- No deterministic task router in Picky.
- No duplicated MCP bridge.
- No remote SaaS backend requirement.
- No billing/auth layer for v1.
- No private Clicky implementation dependency.
- No loss of existing Pi skills/extensions behavior.

## Tone and product direction

Picky should feel like a calm local operations console for agents:

- Minimal overlay.
- Clear session state.
- Low context switching.
- Strong continuity from investigation to action.
- Local-first, developer-power-user oriented.

The product should help the user stay in their current app/browser/code context while Pi handles long-running work in the background.

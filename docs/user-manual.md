# Picky User Manual

Picky is a local-first macOS command center for Pi sessions. It lives in the menu bar, captures neutral desktop context only when invoked, and hands work to local Pi/Pickle sessions.

This document describes the current user-facing behavior: menu bar usage, shortcuts, HUD interactions, Pickle controls, and settings.

## 1. First launch and prerequisites

Picky is a menu bar-only app. It has no regular Dock icon or main app window. On launch, click the Picky icon in the macOS menu bar to open the companion panel.

If setup is incomplete, Picky opens the panel automatically and shows prerequisites before the normal tabs.

Required items:

| Item | Why Picky needs it |
| --- | --- |
| Pi runtime | Runs local Pi/Pickle sessions. |
| Microphone | Captures Push-to-Talk voice input. |
| Accessibility | Enables global shortcuts and capture interactions. |
| Screen Recording | Captures screenshots for context. |
| Screen Content | Enables ScreenCaptureKit-based screen context. |

Speech Recognition is not part of the initial setup gate. If you use Apple Speech STT, macOS may separately request Speech Recognition during dictation.

Setup actions shown in the panel include:

- **Install**: opens `https://pi.dev` when Pi is missing.
- **Recheck**: reruns the local Pi runtime probe.
- **Grant**: requests or opens the matching macOS permission pane.
- **Find App**: reveals Picky in Finder and opens Accessibility settings, useful for unsigned/dev builds.

When all prerequisites are satisfied, Picky shows the main tabs: **Status**, **Messages**, and **Settings**.

### 1.1 Guided onboarding

On fresh installs, after prerequisites are satisfied, Picky may run a short guided onboarding. The walkthrough uses Picky cursor-bubble narration to introduce the main interactions: Push-to-Talk, drawing screen highlights, the Pickle dock, opening a Pickle, and archiving.

You can skip onboarding at any beat by pressing Escape or clicking **Skip**.

## 2. Menu bar companion panel

Open the companion panel by clicking the Picky menu bar icon.

Panel behavior:

- Click the menu bar icon again to toggle the panel.
- Click outside the panel to dismiss it.
- Click the `x` in the header to dismiss it.
- The panel does not activate like a normal app window, so it stays lightweight while you work.
- The footer includes **Quit** and a Light/Dark appearance toggle.

### 2.1 Status tab

The Status tab shows the current Picky state and setup/update information.

Voice status states:

- **Ready when you are**: idle and ready for input.
- **Listening…**: Push-to-Talk is held and audio is being captured.
- **Preparing context…**: Picky is collecting desktop context for Pi.
- **Answering…**: Picky/Pi is responding.

The **What Picky captures** section explains the neutral context Picky sends when invoked:

- Screenshots only when you use the hotkey/input flow.
- Selected text and browser context when available.
- Default workspace from Settings.

The **Updates** section can show:

- Current app version/build.
- Update channel: Stable or Beta.
- Automatic update checks.
- Manual **Check Now**.

Alpha builds may show a static reinstall notice instead of Sparkle update controls.

#### Pi extensions

Picky bundles optional Pi extensions and lets you install them on demand. Picky never modifies `~/.pi/agent` on launch — each extension is opt-in.

For every bundled extension the Status tab shows:

- A short description of what the extension adds to your local Pi.
- The current state: **Not installed**, **Installed**, or a **Conflict** message when an unrelated entry already lives at the target path.
- An **Install** button when the bundled source exists and the target slot is empty.
- A **Remove** button when Picky's symlink is in place. Picky never removes a path it did not create.

Currently bundled:

- **Pi handoff command** — adds a `/handoff-to-picky` slash command to local Pi so you can pin an idle Pi conversation to Picky as a completed Pickle card. After installing, restart Pi or run `/reload`.

The Status tab also links to **Send feedback**.

#### Send feedback

The feedback page lets you send a note to the Picky team. It supports:

- Category: Bug, Idea, or Other.
- Message text.
- Up to 5 image/video attachments, each up to 100 MB and 250 MB total.
- Optional diagnostics: Off, Logs only, or Full diagnostics with API keys masked.

If feedback is not configured in the build/environment, the page explains that the feedback channel is unavailable and disables sending.

### 2.2 Messages tab

The Messages tab shows the latest Picky main-agent conversation.

Available actions:

- Review recent prompts and replies.
- Read Markdown-rendered Picky replies.
- Send a direct message via the bottom composer.
- Start a **New session** for the main Picky conversation.
- **Open in Pi** — launches the in-app Pi terminal overlay against the same `pi` session file the daemon is driving. Available once the main agent has run at least one turn.
- **Copy resume command** — copies a `cd <cwd> && pi --session <file>` command to the clipboard so you can resume the main Picky session in any external shell. The button briefly switches to **Copied** to confirm.

Both escape hatches stay hidden until the daemon reports a session file, and they reuse the same overlay/resume command flow as Pickles.

Composer behavior:

- Placeholder: `Message Picky…`
- Press Return or click the send icon to submit.
- Empty messages cannot be sent.
- Submission captures current desktop context in the same local-first flow.

### 2.3 Settings tab

Settings are grouped into these sections:

1. General
2. Picky
3. Pickle
4. Notification
5. Cursor & Bubbles
6. Voice (STT & TTS)
7. Shortcuts

Most toggles and pickers save immediately. Directory and provider text fields show a section-level **Save changes** / **Saved** indicator.

### 2.4 Footer controls

Footer controls are always visible:

- **Quit**: asks for confirmation before terminating Picky.
- **Light/Dark toggle**: switches the Picky UI appearance and persists the choice.

## 3. Global shortcuts

Default shortcuts:

| Feature | Default | Behavior |
| --- | --- | --- |
| Push-to-Talk | Control + Option | Hold to speak; release to send. |
| Quick Input | Double-tap Control | Opens a text composer near the cursor. |

Shortcuts are configurable in **Settings → Shortcuts**.

Supported shortcut shapes:

- Push-to-Talk:
  - Modifier-only combo, such as `Control + Option`.
  - Modifier + key combo, such as `Control + Option + Space`.
- Quick Input:
  - Double-tap a single modifier, such as Control twice.
  - Modifier + key combo.

The shortcut editor prevents invalid or conflicting shortcuts. Use **Reset to defaults** to restore the defaults.

## 4. Push-to-Talk voice input

Basic flow:

1. Hold the Push-to-Talk shortcut.
2. Speak naturally.
3. Optionally draw on screen while holding the shortcut.
4. Release the shortcut.
5. Picky transcribes speech, captures context, and sends the request to Pi.
6. Replies appear in the Picky cursor bubble, Messages tab, or Pickle HUD depending on routing.
7. If TTS is enabled, Picky also reads replies aloud.

### 4.1 Voice interruption

Starting a new voice input interrupts an in-progress spoken response. This lets you quickly correct, redirect, or continue without waiting for TTS to finish.

### 4.2 Voice follow-up to a Pickle

When a Pickle conversation card is open and the cursor is hovering over it, Push-to-Talk targets that Pickle instead of the main Picky agent.

Visible cues:

- The Pickle header can show a small microphone badge.
- The voice input becomes a Pickle follow-up/steer rather than a main Picky turn.

### 4.3 Screen-context target to a Pickle

You can explicitly arm a Pickle as the target for the next Picky screen-context input:

1. Open a Pickle card.
2. Click the Pickle/Pi badge in the header, or press `Cmd + K`.
3. The composer shows: “Next Picky screen input will go to this Pickle”.
4. Use Push-to-Talk or Quick Input.
5. The next screen-context input is sent directly to that Pickle.
6. The target clears after delivery.

## 5. Quick Input text input

Default shortcut: double-tap Control.

Behavior:

1. Trigger Quick Input.
2. A compact pill composer appears near the cursor.
3. Type a message.
4. Press Return or click the up-arrow send button.
5. Press Escape or click `x` to close.

Quick Input captures the current context just like voice input.

Quick Input is suppressed while Push-to-Talk or dictation is active, so the two input modes do not fight for focus.

## 6. Drawing screen highlights

During Push-to-Talk or Quick Input, Picky starts an ink-capture mode.

How to use it:

1. Trigger Push-to-Talk or Quick Input.
2. Click and drag on the screen to mark an area.
3. Release the input shortcut or submit the text.
4. The freehand mark is mapped into the captured screenshot and sent as context.

Details:

- Very short drags are ignored.
- A drag must cross the threshold before becoming a visible mark.
- The app underneath does not receive mouse events while Picky owns ink capture, except for pass-through cases inside Picky UI.
- Marks are neutral context; Picky does not infer workflows from them.

## 7. Pickle HUD and dock

Pickles are independent Pi sessions shown in the Picky HUD dock. They are useful for long-running work that should continue in the background.

The dock can be vertical or horizontal and can attach to the screen edge.

### 7.1 Dock states

Pickle status can be:

| Status | Meaning |
| --- | --- |
| queued | Waiting to run. |
| running | Actively working. |
| waiting_for_input | Needs user input. |
| blocked | Blocked or paused. |
| completed | Finished successfully. |
| failed | Failed. |
| cancelled | Stopped/cancelled. |

The dock icon color, glyph, unread dot, and completion flash reflect these states.

### 7.2 Dock interactions

| Interaction | Result |
| --- | --- |
| Hover a Pickle | Shows a mini preview. |
| Click a Pickle | Opens or closes its conversation card. |
| Long-press a Pickle | Archives it. |
| Drag a Pickle | Reorders visible dock sessions. |
| Right-click / Control-click | Opens the dock context menu. |
| Click the `+` slot | Choose a folder and start an empty Pickle. |
| Drag the dock handle | Move the dock along or across screen edges. |
| Double-click the dock handle | Toggle vertical/horizontal dock layout. |

The dock shows up to 12 active sessions. Number shortcuts apply to the first 9 visible sessions.

### 7.3 Creating an empty Pickle

Click the `+` slot in the dock. Picky opens a folder picker:

1. Choose a working folder.
2. Click **Start**.
3. Picky creates an empty Pickle for that folder.
4. If visible, the new Pickle opens automatically.

### 7.4 Archiving and undo

Archive methods:

- Long-press a Pickle dock icon until the progress ring completes.
- Use the Pickle context menu.
- Use the conversation card menu.

After archiving:

- The Pickle leaves the active dock.
- A screen-level **Session archived** toast appears.
- Click **Undo** within the toast window to restore it.

The current UI exposes immediate restore through the undo toast.

## 8. Pickle conversation card

Click a Pickle dock icon to open its card.

The card contains:

- Header with title, status badge, and menu.
- Context line with working folder, Git/PR/link badges.
- Conversation history.
- Composer for steer/follow-up input.
- Inline question forms when Pi/tools need user input.
- Optional inline Pi terminal mode.
- Optional private note add-on.

### 8.1 Header

Header actions:

| Action | Behavior |
| --- | --- |
| Double-click title | Rename the Pickle. |
| Click status/Pickle badge | Arm or disarm this Pickle as the next screen-context target. |
| Open ellipsis menu | Shows terminal/session actions. |
| Click model/thinking metadata | Cycle model or thinking level when available. |

Renaming sends an internal `/name <new title>` command to the Pickle. You can also type `/name <new title>` directly in the composer.

The header may also show a context-usage percentage/bar. It gives a quick view of how full the Pickle's context window is. The bar becomes more urgent as usage grows, turning amber above roughly 70% and red above roughly 90%. Hover it to see token counts when available.

### 8.2 Context line

The context line can show:

- Working folder.
- Repository name.
- Branch name.
- Git insertion/deletion counts.
- Ahead/behind counts.
- Pull request status.
- Link badges from artifacts, such as GitHub, Slack, Notion, Jira, Linear, or generic links.

Interactions:

- Click working folder to open Finder.
- Click repository/branch links to open the remote web URL when available.
- Click `↑N` to run `git push`.
- Click `↓N` to run `git pull`.
- Click PR/link badges to open external links.

### 8.3 Composer behavior

The composer changes behavior based on Pickle status.

| Session status | Default Return action |
| --- | --- |
| running / queued / waiting_for_input | Steer this agent. |
| completed / blocked | Send follow-up. |
| cancelled | Resume with a steer. |
| failed | Send recovery steer or open terminal. |

Keyboard behavior inside the composer:

| Key | Action |
| --- | --- |
| Return | Submit default action. |
| Shift + Return | Insert newline. |
| Option + Return | Submit follow-up when available. |
| Escape | Dismiss autocomplete; if armed, cancel screen context; if empty, stop active session. |
| Tab | Accept selected autocomplete. |
| Shift + Tab | Cycle thinking level. |
| Control + P | Cycle model forward. |
| Control + Shift + P | Cycle model backward. |
| Up / Down | Navigate autocomplete. |
| Option + Up | Pull queued messages back into the composer and clear the queue. |

### 8.4 Steer vs follow-up

- **Steer**: changes or directs what the currently running/failed/cancelled agent should do next.
- **Follow-up**: starts a new continuation after a completed/blocked turn, or queues a follow-up where supported.

The UI chooses the default based on session status. `Option + Return` can force follow-up when available.

### 8.5 Bash execution mode

If the composer text starts with `!` or `!!`, Picky visually switches into Bash execution mode.

| Prefix | Meaning |
| --- | --- |
| `! command` | Run bash; include output in Pi context. |
| `!! command` | Run bash; exclude output from Pi context. |

Visual cues:

- Composer border changes color.
- Left badge shows **BASH** or **PRIVATE**.
- Send icon changes from paper plane to play icon.

Safety behavior:

- If attachments are present, Picky prevents accidental bash execution by treating the message as a normal prompt.

### 8.6 Slash command autocomplete

Type `/` in the composer to show slash command suggestions.

Controls:

- Up/Down: move selection.
- Tab or Return: accept selected command.
- Escape: dismiss suggestions.

### 8.7 File mention autocomplete

When file mention syntax is detected, Picky suggests files relative to the Pickle cwd.

Controls:

- Up/Down: move selection.
- Tab or Return: accept.
- Escape: dismiss.

Directory suggestions can keep the autocomplete open so you can continue drilling down.

### 8.8 File and image drops

Drop files or screenshots anywhere on the Pickle card to attach their file paths.

Behavior:

- Dropped items become attachment chips above the composer.
- Chips can be removed before sending.
- On submit, attachment paths are appended to the message.

### 8.9 Notify on completion and notes

The composer left column includes:

- Bell button: toggles **Notify on completion** for the Pickle.
- Note button: opens/closes a private Pickle note.

The note is for the user only and is not shared with Pi.

### 8.10 Inline questions and confirmations

When Pi or an extension asks for input, Picky shows an inline question bubble.

Supported controls:

- Confirm: **Allow** / **Cancel**.
- Select: choose one option or cancel.
- Input/editor: type a response and submit.
- askUserQuestion form:
  - radio
  - checkbox
  - free-text
  - optional “Other…” entries

Answered or cancelled question bubbles collapse but can be expanded for review.

### 8.11 Tool History viewer

Click a tool/activity summary in a Pickle card to open **Tool History** in a separate window. Tool History helps inspect what the Pickle actually did.

It can show:

- Tool calls grouped by category, such as read, bash, edit, write, and other.
- Tool status and duration.
- Bash output or generic tool details where available.
- Edit diffs for file changes where available.
- A scope toggle to switch between the current turn and the whole session.

Tool History is a local inspection surface for the current user, so treat visible tool outputs and diffs as potentially sensitive project context.

## 9. Pickle menus

### 9.1 Conversation card ellipsis menu

The Pickle card menu contains:

**QUICK**

| Menu item | Shortcut | Description |
| --- | --- | --- |
| Open Pi terminal | Cmd + Shift + T | Open a separate Pi terminal overlay. |
| Show Pi terminal inline / Show chat UI | Cmd + T | Toggle inline terminal/chat mode. |
| Copy resume command | — | Copy a `pi --session ...` resume command. |
| Sync from Pi session | — | Refresh the HUD card from the on-disk Pi session file. |

**SETTINGS**

| Menu item | Description |
| --- | --- |
| Notify on completion | Toggle whether completion notifies the main Picky flow. |

**SESSION**

| Menu item | Description |
| --- | --- |
| Duplicate | Duplicate this Pickle session. |
| Stop session | Abort the active session. |
| Archive | Archive the Pickle. |

### 9.2 Dock right-click menu

Right-click or Control-click a Pickle dock icon to open a smaller context menu:

- Send Context to This Pickle / Stop Sending Context to This Pickle
- Compact
- Archive
- Stop

Compaction is available only when the session is not currently running and not already compacting.

### 9.3 Compaction UX

Selecting **Compact** asks Pi to compress older session context so the Pickle can continue with a cleaner transcript.

What you will see:

- While compaction is running, the card shows a **Compacting…** overlay and the composer is disabled.
- On success, a **Session compacted** system bubble appears in the conversation.
- On failure, an error bubble explains the reason.

## 10. HUD keyboard shortcuts

These work when a Pickle card/HUD panel is active.

| Shortcut | Action |
| --- | --- |
| Cmd + W | Close the open Pickle card. |
| Escape | Close the card when no text input is focused. |
| Return | Focus the active composer when no text input is focused. |
| Cmd + 1…9 | Open/close the corresponding visible Pickle. |
| Cmd + Shift + `[` | Cycle to previous Pickle. |
| Cmd + Shift + `]` | Cycle to next Pickle. |
| Cmd + R | Open latest agent response as a report. |
| Cmd + T | Toggle inline Pi terminal. |
| Cmd + Shift + T | Open separate Pi terminal overlay. |
| Cmd + N | Toggle Notify on completion. |
| Cmd + E | Toggle Pickle Note. |
| Cmd + K | Toggle screen-context target for the active Pickle. |
| Control + T | Toggle thinking blocks. |

Holding Command can reveal shortcut badges on relevant HUD controls.

## 11. Pi terminal overlay and inline terminal

Picky can open a Pi terminal for Pickles or for the always-on Picky main agent, whenever a Pi session file is available.

Ways to open from a Pickle card:

- Card menu → **Open Pi terminal**.
- `Cmd + Shift + T`.
- Card menu → **Show Pi terminal inline**.
- `Cmd + T`.

Ways to open from the always-on Picky main agent:

- Menu bar panel → **Messages** tab → **Open in Pi**.
- Menu bar panel → **Messages** tab → **Copy resume command** to paste `pi --session ...` into your own shell.

Terminal zoom shortcuts:

| Shortcut | Action |
| --- | --- |
| Cmd + `=` | Zoom in. |
| Cmd + `-` | Zoom out. |
| Cmd + `0` | Reset zoom. |

Closing the terminal syncs the session card from the Pi session file when possible.

## 12. Report viewer

Open a report when you want to inspect a full Markdown response outside the compact HUD card.

Ways to open:

- `Cmd + R` on an active Pickle with a latest response.
- Hover/open affordances on supported response bubbles.

Report viewer features:

- Markdown rendering.
- Open backing report file.
- Copy Markdown to clipboard.
- Persistent zoom.

Report zoom shortcuts:

| Shortcut | Action |
| --- | --- |
| Cmd + `=` | Zoom in. |
| Cmd + `-` | Zoom out. |
| Cmd + `0` | Reset zoom. |

## 13. Settings reference

Settings are stored at:

```text
~/Library/Application Support/Picky/Settings/settings.json
```

### 13.1 General

| Setting | Values | Notes |
| --- | --- | --- |
| App language | System default, English, 한국어 | Most UI retranslates immediately. Some macOS-owned surfaces require relaunch. |

### 13.2 Picky

| Setting | Values / behavior |
| --- | --- |
| Picky cwd | Applies to captured Picky context and the next Picky session. Defaults to the seeded Picky workspace at `~/Library/Application Support/Picky/Workspace`. Must be an existing directory. See **Customizing the Picky workspace** below. |
| Runtime | Pi or OpenAI Realtime, when realtime opt-in is enabled. |
| Pi model | Automatic or a pinned model pattern. |
| Reasoning level | Off, Minimal, Low, Medium, High, Extra High. |
| Screen context | All screens or Focused screen only. Default is **Focused screen only** so Picky captures only the display the cursor is on. |
| Screenshot quality | 1× 1280 px, 1.5× 1920 px, 2× 2560 px longest edge. Captured screenshots are written to the per-user temporary directory (`FileManager.default.temporaryDirectory/Picky/Screenshots`), not the durable Application Support tree. |
| Additional instructions | Extra standing instructions baked into the Picky bootstrap; apply on next Picky session/relaunch. |

#### Customizing the Picky workspace

The Picky main agent runs in a workspace folder so Pi automatically loads any `AGENTS.md`, `.pi/extensions`, `.pi/skills`, and `.pi/prompts` you drop in there. Picky seeds a default `AGENTS.md` with the always-on persona and Pickle delegation policy on first launch.

Default location:

```text
~/Library/Application Support/Picky/Workspace
```

What lives there:

- `AGENTS.md` — Picky's persona and routing rules. Edit freely; Picky never overwrites your changes. Delete the file and relaunch Picky to reseed the default.
- `.pi/extensions/`, `.pi/skills/`, `.pi/prompts/` — optional Pi customization that augments Picky exactly the way Pi loads them in any other cwd.

The seeded `AGENTS.md` instructs the main agent to keep itself in sync with how you talk to Picky:

- Persistent rules and preferences ("from now on do X", "apply this rule", "add/update/remove this instruction") — the agent follows the request for the current turn and edits `AGENTS.md` directly under the most relevant section, then tells you which section was changed.
- Pickle execution guidance (default cwd or repo path for a kind of task, fixed procedures/checklists, preferred skills/MCPs, naming conventions, what to include in `instructions`) — written into a dedicated `## Pickle execution` section so it is loaded on every main-agent turn instead of stashed in memory.
- One-off facts and scratch notes — routed to the built-in memory tool when one is available; otherwise the agent creates a sibling file next to `AGENTS.md` (for example `NOTES.md` or `notes/<topic>.md`) and adds a short pointer under a `## Notes` section in `AGENTS.md`.

In practice you can shape Picky just by talking to it ("always start Pickles for the picky repo from `~/Documents/picky` and follow the AGENTS guide there") and let Picky persist the rule. You can still hand-edit `AGENTS.md` whenever you want full control.

To run Picky with a completely different persona or workflow set, change **Picky cwd** in Settings to any folder that contains its own `AGENTS.md` and `.pi/*` subdirectories.

Realtime-specific settings, when enabled:

| Setting | Notes |
| --- | --- |
| Realtime provider | OpenAI or Azure OpenAI. |
| API key | Provider API key. |
| Azure Realtime URL | Full Azure Realtime URL; Picky derives deployment/API version/shape. |
| Model | OpenAI realtime model for direct OpenAI. |
| Voice | Realtime voice for direct OpenAI. |
| Realtime effort | Low, Medium, High. |

### 13.3 Pickle

| Setting | Values / behavior |
| --- | --- |
| Default cwd | Default working directory for new Pickles. Must be an existing directory. |
| Pickle model | Automatic or pinned initial model for newly-created Pickles. |
| Reasoning level | Automatic, Off, Minimal, Low, Medium, High, Extra High. Applies as initial setting for new Pickles. |
| Dock size | S, M, L. |

Running Pickles can still cycle model/thinking independently from these defaults.

### 13.4 Notification

| Setting | Default | Meaning |
| --- | --- | --- |
| On success | Off | Show macOS banner when a session completes. |
| On failure | On | Show banner when a session fails. |
| On input request | On | Show banner when a session waits for user input. |

### 13.5 Cursor & Bubbles

| Setting | Default | Meaning |
| --- | --- | --- |
| Show Picky Cursor | On | Shows the cursor buddy overlay. |
| Smooth cursor follow | On | Enables springy cursor-follow animation. |
| Idle animations | On | Enables idle cursor animations. |
| User STT recognition | On | Shows recognized speech bubble. |
| Picky reply text | On | Shows Picky reply bubble. |

If **Show Picky Cursor** is off, smooth follow and idle animations are disabled.

### 13.6 Voice (STT & TTS)

Picky supports four backends for speech recognition and synthesis: Apple/macOS
built-in, OpenAI direct (`api.openai.com`), Azure OpenAI, and ElevenLabs.
Each backend has its own credentials section that appears only when that
provider is selected.

| Setting | Values / behavior |
| --- | --- |
| STT provider | Apple Speech (default), OpenAI, Azure OpenAI, ElevenLabs. Apple Speech uses the on-device `SFSpeechRecognizer` (offline). OpenAI uses `gpt-4o-transcribe` against `api.openai.com`. Azure OpenAI uses your deployment URL. ElevenLabs uses `scribe_v2` against `api.elevenlabs.io` (the legacy `scribe_v1` is deprecated as of 2026). |
| Enable spoken replies (TTS) | On/off. When off, text replies still appear but audio playback is skipped. |
| TTS provider | macOS Speech (default), OpenAI, Azure OpenAI, ElevenLabs. macOS Speech uses the system `NSSpeechSynthesizer` voice. OpenAI uses `gpt-4o-mini-tts` against `api.openai.com`. |
| Open macOS Speech Settings | Opens the system Spoken Content settings for local TTS voice selection. |

OpenAI STT fields (when STT provider = OpenAI):

- OpenAI STT API key (`sk-…`)
- OpenAI STT model — leave blank for the recommended `gpt-4o-transcribe` default
- OpenAI STT preferred language — ISO-639-1 code or empty for auto detect
- OpenAI STT base URL — empty uses `https://api.openai.com`. Set this to point Picky at any OpenAI-compatible HTTP server (LocalAI, openai-edge-tts, Together, Groq, self-hosted inference, etc.). A trailing `/v1` is stripped automatically. Picky speaks the standard `/v1/audio/transcriptions` protocol — proxy stability is your responsibility.

OpenAI TTS fields (when TTS provider = OpenAI):

- OpenAI TTS API key (`sk-…`; leave empty to reuse the STT key, then the `OPENAI_API_KEY` env)
- OpenAI TTS voice — `alloy` (default), `ash`, `ballad`, `coral`, `echo`, `fable`, `onyx`, `nova`, `sage`, `shimmer`, `verse`, `marin`, `cedar`
- OpenAI TTS model — leave blank for `gpt-4o-mini-tts`
- OpenAI TTS base URL — same semantics as STT base URL above

Azure STT fields (when STT provider = Azure OpenAI):

- Azure STT transcription URL — full deployment URL from the Azure portal
- Azure STT API key
- Azure STT preferred language

Azure TTS fields (when TTS provider = Azure OpenAI):

- Azure TTS speech URL
- Azure TTS API key — leave empty to reuse the STT key
- Azure TTS voice

ElevenLabs STT fields (when STT provider = ElevenLabs):

- ElevenLabs STT API key
- ElevenLabs STT model — `scribe_v2` (default); `scribe_v1` is deprecated
- ElevenLabs STT language — ISO-639-1 or 639-3 code, or empty for auto detect

ElevenLabs TTS uses environment variables (`ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID`). A Settings UI for ElevenLabs TTS fields will be added in a later release.

> **Edge TTS / unofficial backends.** Picky does not bundle Microsoft Edge TTS,
> Piper, or other non-public APIs. To use them, run an OpenAI-compatible proxy
> (e.g. [openai-edge-tts](https://github.com/travisvn/openai-edge-tts)) locally
> and point Picky at it via the OpenAI base URL override. Picky speaks only the
> standard OpenAI Audio protocol — proxy maintenance is the user's responsibility.

### 13.7 Shortcuts

| Setting | Default | Notes |
| --- | --- | --- |
| Push to Talk | Control + Option | Hold to start voice; release to send. |
| Quick Input | Double-tap Control | Opens quick text composer near cursor. |

Use **Change**, then **Save** or **Cancel**. Conflicts are rejected. **Reset to defaults** restores both defaults.

### 13.8 Updates

Update controls live in the Status tab.

| Setting | Values / behavior |
| --- | --- |
| Channel | Stable or Beta. |
| Check automatically every 4 hours | Enables Sparkle automatic checks where available. |
| Check Now | Manual update check. |

Alpha builds may not expose Sparkle update controls.

## 14. Common workflows

### 14.1 Ask about the current screen by voice

1. Open the app/page you care about.
2. Hold Push-to-Talk.
3. Speak your request.
4. Optionally draw a mark on the relevant region.
5. Release the shortcut.
6. Picky sends voice transcript + screen context to Pi.

### 14.2 Ask about the current screen by text

1. Trigger Quick Input.
2. Type your request.
3. Optionally mark the screen.
4. Press Return.
5. Picky sends text + screen context to Pi.

### 14.3 Continue a Pickle

1. Click the Pickle in the HUD dock.
2. Read the latest messages.
3. Type a steer or follow-up in the composer.
4. Press Return, or Option + Return for follow-up where supported.

### 14.4 Send next screen context to a specific Pickle

1. Open the Pickle card.
2. Click the status/Pickle badge or press `Cmd + K`.
3. Trigger Push-to-Talk or Quick Input.
4. Send the request.
5. Picky routes that input directly to the Pickle and clears the target.

### 14.5 Inspect or resume in terminal

1. Open the Pickle card.
2. Press `Cmd + T` for inline terminal or `Cmd + Shift + T` for separate terminal.
3. Work in Pi TUI.
4. Close terminal to sync back into the HUD card.

### 14.6 Clean up finished Pickles

1. Long-press a dock icon, or use the menu → Archive.
2. If it was accidental, click **Undo** in the archive toast.

### 14.7 Customize Picky's persona or routing rules

You can customize Picky in two complementary ways:

**By talking to Picky** (no editor required):

1. Send a persistent instruction to the Picky main agent — for example, "from now on, when I ask about the picky repo, start the Pickle in `~/Documents/picky` and follow that AGENTS.md."
2. Picky follows it for the current turn and edits `AGENTS.md` to record the rule. Pickle-specific guidance lands under `## Pickle execution`; other persistent rules land under the most relevant section.
3. Picky tells you which section was changed. The next main session loads the updated rules automatically.

One-off facts ("my OpenAI key lives at `~/.config/foo`") are stored in the built-in memory tool when available, or in a sibling `NOTES.md` referenced from `AGENTS.md` — they do not pollute the persona file.

**By hand-editing the file** (full control):

1. Open `~/Library/Application Support/Picky/Workspace/AGENTS.md` in any editor.
2. Edit the persona, Pickle delegation thresholds, or any other instructions.
3. Save. The next Picky main session picks up the changes.

To experiment without touching the default, point **Settings → Picky → Picky cwd** at a fresh folder containing its own `AGENTS.md` and switch back when you're done.

### 14.8 Resume the main Picky session in a real Pi terminal

1. Open the menu bar panel and switch to the **Messages** tab.
2. Click **Open in Pi** to launch the in-app Pi terminal overlay, or **Copy resume command** to paste `pi --session ...` into an external shell.
3. Work directly in the Pi TUI. Closing the overlay syncs the visible state back into the Picky panel.

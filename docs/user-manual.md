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
| Screen Content | Enables ScreenCaptureKit-based screen context. Picky only surfaces this row after Screen Recording has been granted, since the underlying API requires the parent permission first. |

Speech Recognition is not part of the initial setup gate. If you use Apple Speech STT, macOS may separately request Speech Recognition during dictation.

Setup actions shown in the panel include:

- **Install**: opens `https://pi.dev` when Pi is missing.
- **Recheck**: reruns the local Pi runtime probe.
- **Grant**: requests or opens the matching macOS permission pane.
- **Find App**: reveals Picky in Finder and opens Accessibility settings, useful for unsigned/dev builds.

When all prerequisites are satisfied, Picky shows the main tabs: **Status**, **Extensions**, and **Settings**.

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

The **Updates** section shows the current app version/build and channel on one compact line, plus a **Check Now** button and an inline auto-check toggle. The channel itself is pinned by the installed build (Stable, Beta, or Alpha) — it is not user-switchable. Alpha builds show a static reinstall notice instead of Sparkle update controls.

The Status tab also exposes a **Recent conversation ›** drill-in row that opens the Picky main-agent chat as a Status sub-page (described below). The Status index does not host its own "Send feedback" link — use the footer bug glyph (see [§2.4](#24-footer-controls)) to reach the feedback form from any tab.

#### Recent conversation sub-page

Drills into the Picky main-agent chat. Available actions:

- Review recent prompts and replies.
- Read Markdown-rendered Picky replies.
- Send a direct message via the bottom composer (placeholder `Message Picky…`; Return or click the send icon to submit; empty messages cannot be sent).
- Start a **New session** for the main Picky conversation.
- **Open in Pi** — launches the in-app Pi terminal overlay against the same `pi` session file the daemon is driving. Available once the main agent has run at least one turn.
- **Copy resume command** — copies a `cd <cwd> && pi --session <file>` command to the clipboard so you can resume the main Picky session in any external shell. The button briefly switches to **Copied** to confirm.

Both escape hatches stay hidden until the daemon reports a session file, and they reuse the same overlay/resume command flow as Pickles. Submission from the composer captures current desktop context in the same local-first flow as voice/quick input.

#### Send feedback sub-page

Reached from the footer bug glyph. The feedback form supports:

- Category: Bug, Idea, or Other.
- Message text.
- Up to 5 file attachments, each up to 100 MB and 250 MB total. Image/video previews are shown when supported; unsupported media is attached as a regular file.
- Optional diagnostics: Off, Logs only, or Full diagnostics with API keys masked.

If feedback is not configured in the build/environment, the page explains that the feedback channel is unavailable and disables sending.

### 2.2 Extensions tab

The Extensions tab is where Picky surfaces bundled Pi resources you can install on demand and a curated list of third-party extensions. Picky never modifies your Pi coding-agent directory on launch — each extension or skill is opt-in. By default that directory is `~/.pi/agent`, or the `PI_CODING_AGENT_DIR` configured in Settings/environment.

For every bundled extension or skill the tab shows:

- A short description of what it adds to your local Pi.
- The current state: **Not installed**, **Installed**, or a **Conflict** message when an unrelated entry already lives at the target path.
- An **Install** button when the bundled source exists and the target slot is empty.
- A **Remove** button when Picky's managed copy is installed. Picky never removes a path it did not create.

Currently bundled:

- **Pi handoff command** — adds a `/handoff-to-picky` slash command to local Pi. When the source Pi turn is idle, it pins the conversation to Picky as a completed Pickle card; when Pi is busy, it aborts the source turn, snapshots that Pi session, resumes it as a Pickle, and sends the handoff instruction (default: `continue`). After installing, restart Pi or run `/reload`.
- **Picky CLI skill** — teaches local Pi how to use the `picky` shell command for submitting to Picky, creating/steering Pickles, and controlling Picky push-to-talk.

A **Curated extensions** section under the bundled list lists a small set of useful third-party Pi extensions. Each row shows the extension name, the command or tool it adds, a short description, and an install/remove control that installs the extension from npm into the local Pi setup. Examples include `/diff-review` for native diff review, `ask_user_question` for structured clarification forms, `show_widget` for native generative UI windows, and `/delay` for scheduling a one-shot follow-up prompt after a chosen delay.

### 2.3 Settings tab

Settings are grouped in the index:

- **General**: General, Pi login (OAuth), Shortcuts
- **Agents**: Main Agent, Pickle, Built-in Tools
- **Surface**: Voice (STT & TTS), Overlay & Notifications

The **Pi login** page lets you sign in to your Pi account from Picky. Use it to connect your local Pi to your Pi account so account-bound features stay in sync. The section header shows the current login status.

Most toggles and pickers save immediately. Directory and provider text fields show a section-level **Save changes** / **Saved** indicator.

### 2.4 Footer controls

Footer controls are always visible:

- **Quit**: asks for confirmation before terminating Picky.
- **Hide Dock / Show Dock**: hides or restores only the HUD dock on the display where the companion panel is open, without stopping Pickles or disconnecting their sessions. Each display's choice persists independently across relaunches. Clicking a Pickle notification explicitly restores the Dock so the requested conversation can open.
- **Send feedback (bug glyph)**: opens the feedback form regardless of which tab you are on. Routes the panel to Status → Send feedback so the back chevron lands on a familiar surface afterward.
- **Light/Dark icons**: click the sun or moon directly to select and persist the Picky UI appearance. The selected icon uses a quiet highlighted background.

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
6. Replies appear in the Picky cursor bubble, the Status → Recent conversation sub-page, or the Pickle HUD depending on routing.
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
6. By default, the input is delivered as a **follow-up** so it waits for the Pickle's current turn to finish. Change **Settings → Picky → Armed Pickle delivery** to **Steer** if you want armed Push-to-Talk and Quick Input to interrupt the current turn instead.
7. A one-shot target clears after delivery; a locked target stays armed.
8. When that armed delivery includes at least one screenshot, the Pickle receives the visual annotation DSL for that response only and may draw grounded `RECT`, `LINE`, or `PATH` annotations on the captured screen. Text-only deliveries never enable the DSL.
9. Clearing the one-shot armed badge does not cancel the response already in flight. Its turn-scoped visual capability remains valid unless a newer screen-context submission supersedes it, the turn is cancelled, or the captured scene no longer matches.

## 5. Quick Input text input

Default shortcut: double-tap Control.

Behavior:

1. Trigger Quick Input.
2. A compact pill composer appears near the cursor.
3. Type a message.
4. Press Return or click the up-arrow send button.
5. Press Escape or click `x` to close.

Quick Input captures the current context just like voice input.

Quick Input is suppressed while Push-to-Talk or dictation is active, and also while you are mid-rebind in the shortcut editor, so the two input modes do not fight for focus or hijack capture.

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
- The app underneath does not receive mouse events while Picky owns ink capture. The Quick Input panel and the HUD card stay click-through during **Quick Input** ink capture so you can still interact with them; Push-to-Talk ink capture blocks every surface, Picky's own panels included.
- Marks are neutral context; Picky does not infer workflows from them.
- If **Send screenshots only when drawn** (Settings → Picky) is enabled, the screenshot is sent to the model only after you actually draw a mark. Without a mark, only the transcript and non-visual context fields are sent; the screen capture itself still runs locally so the ink overlay can render.

### 6.1 Picky screen guidance

When a reply refers to a concrete location in a captured screenshot, Picky can point at that location or draw rough rectangles, lines, and freeform paths with labels over the matching display. Rectangles and lines may also use spotlights; paths can combine straight and cubic Bézier segments for trends or graph-like guidance. Visual narration is revealed sentence by sentence, so each pointer or drawing appears alongside the part of the spoken/text response that describes it.

These overlays are grounded in the screenshot captured for the current turn. Picky validates the current screen pixels before revealing them, hides drawings when the referenced area changes substantially, and can restore them if the original scene returns during narration or within the roughly 30-second recovery window afterward. Drawings that remain after narration show a lower-center **Clear drawing** control. Agent-authored overlays are visual-only and are not added to the conversation transcript.

Turn **Screen pointing & drawing** off under Settings → Agents → Tools to disable all agent-authored screen overlays. This does not disable the marks you draw yourself during Push-to-Talk or Quick Input.

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
| Press and hold a Pickle | Archives it after a ~1.2s hold timer; a progress ring fills around the dock icon, and moving the cursor more than ~10pt away cancels the archive before it fires. Archives are recoverable from the undo toast or Settings → Pickle → Archived sessions. |
| Drag a Pickle | Reorders dock Pickles, or drags one into / out of a group. The move is committed when you release. Hold it clearly **outside** the dock for a moment and an **Archive** label appears; release there to archive it (macOS Dock style). |
| Right-click / Control-click | Opens the dock context menu (Send Context / Compact / Archive / Stop). |
| Click the `+` slot | Opens a popover with pinned/recent folders, **Choose Folder…**, and **New Group…**. |
| Drag the dock handle | Move the dock along or across screen edges. The dock may tuck partly off-screen, but its handle slot stays visible so it remains grabbable. |
| Double-click the dock handle | Toggle the dock between vertical and horizontal layouts. |

Number shortcuts (`Cmd + 1`…`9`) apply to the first 9 visible dock slots, top to bottom. A collapsed group counts as one slot: pressing its number **expands the group** instead of opening a Pickle, after which each member gets its own number — so a second press reaches the individual Pickle. While `Cmd` is held, every numbered slot (including collapsed groups) shows its badge.

### 7.3 Creating an empty Pickle

Click the `+` slot in the dock to open the **Recent folders** popover:

- Pick a pinned or recent working folder to start an empty Pickle there immediately.
- Use the pin button on a recent folder to keep it at the top of the list. Pinned folders stay visible ahead of recents and are not removed by the recent-folder cap.
- Use the unpin button to move a pinned folder back into the regular recent list, or the remove button to hide an unpinned recent folder.
- **Choose Folder…** opens the macOS folder picker for any other folder.
- **New Group…** creates a dock group instead of a Pickle (see §7.4).

When you start a Pickle this way, Picky creates an empty Pickle for that folder and, if it is visible, opens it automatically.

### 7.4 Pickle groups

Group related Pickles into a single labeled block in the dock rail.

Create a group:

- Click the `+` slot → **New Group…**, give it a name, and optionally pick initial Pickles and an accent color.
- An empty group shows a dashed `+` tile. Click it to pick a working folder and start a new Pickle that lands directly in that group; the tile also stays a drop target for dragging existing Pickles in.

Manage membership by dragging:

- Drag a Pickle onto a group to move it in; drag it above the first slot or below the last slot to pull it back out to the top level. The dock previews where it will land and commits the move only when you release.
- Drag a group's header to reorder the whole group within the dock. Hold it clearly **outside** the dock and a **Remove** label appears; release there to remove the group (macOS Dock style). A group that still contains Pickles asks for confirmation before archiving them; an empty group is removed immediately.

Collapse and expand:

- Click a group's header (or its chevron) to collapse it into a compact **folder drawer** badge that shows a grid of its members, or to expand it again.
- Collapse state is remembered **per display**, so the same group can stay open on one monitor and collapsed on another.
- Collapsing a group automatically closes any open conversation card that belongs to one of its members.

Right-click a group header — or the collapsed group's **folder drawer** badge — for more actions:

| Action | Behavior |
| --- | --- |
| Rename | Rename the group via a dialog. |
| Color | Pick the group's accent color. |
| Collapse / Expand | Toggle the folder drawer for this display. |
| Ungroup (keep pickles) | Remove the group but keep its Pickles in the dock. |
| Delete group + archive pickles | Remove the group and archive all its Pickles (with confirmation; an empty group is removed immediately with no prompt). |

### 7.5 Archiving and undo

Archive methods:

- Press and hold a Pickle dock icon until the hold timer completes.
- Use the dock right-click menu → **Archive**.
- Use the conversation card menu → **Archive**.

After archiving:

- The Pickle leaves the active dock.
- A screen-level **Session archived** toast appears.
- Click **Undo** within the toast window to restore it.

Restore paths after archiving:

- The screen-level **Undo** toast (immediate, time-limited).
- **Menu bar panel → Settings → Pickle → Archived sessions** (footer disclosure, hidden when empty). Each row has a **Restore** button.
- Asking the Picky main agent to bring it back (e.g. "되살려", "restore that pickle"), which routes through the same `picky_unarchive_pickle` path.

Permanently deleting archives:

- Each row in the archived list has its own **Delete** button with a 4-second confirm.
- The list header also has a **Delete all** button (visible only when the archive is non-empty) that opens a confirmation alert and purges every archived Pickle from both Picky and the local agent's session store in one shot. The action cannot be undone.

## 8. Pickle conversation card

Click a Pickle dock icon to open its card.

The card contains:

- Header with title, status badge, and menu.
- Context line with working folder, Git/PR/link badges.
- Conversation history with Markdown-rendered replies. The latest Picky reply is shown in full in the HUD, including Markdown tables rendered as cell grids; older replies may stay compact and can still be opened as reports.
- Composer for steer/follow-up input.
- Inline question forms when Pi/tools need user input.
- A read-only task-progress indicator when Pi shares a checklist for the active task. Click it to expand or collapse the task list; completed tasks are marked, and the current task shows its in-progress state.
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
- Link badges from artifacts, such as GitHub, Slack, Notion, Jira, Linear, or generic links. Generic web links display the site's favicon when it is available; otherwise they use the standard link icon.

Interactions:

- Click working folder to open Finder.
- Click repository/branch links to open the remote web URL when available.
- Click `↑N` to run `git push`.
- Click `↓N` to run `git pull`.
- Click PR/link badges to open external links.

### 8.3 Composer behavior

The composer stays pinned to the bottom of a resized Pickle card. It changes behavior based on Pickle status.

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

Type `/` in the composer to show slash command suggestions supplied by Pi's built-in and extension autocomplete providers. Picky also adds local HUD commands where useful; for example, `/tree` opens the Pickle message rewind picker instead of sending the text to Pi.

Suggestions follow the caret: they appear whenever the caret sits inside the leading command token, even when more draft text follows. Accepting a suggestion replaces only the typed command part and keeps the rest of your draft, so you can place the caret at the start of an existing message and prepend a command without losing your text.

Controls:

- Up/Down: move selection.
- Tab or Return: accept selected command.
- Escape: dismiss suggestions.

### 8.7 File mention autocomplete

When file mention syntax is detected, Picky suggests files relative to the Pickle cwd.

File search runs on the `fd` binary, resolved from `~/.pi/agent/bin/fd`, Homebrew, or system paths. If `fd` is not installed, the panel shows "File search requires fd (not installed)".

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

### 8.9 Notify on completion

The composer left column includes a **Bell** button that toggles **Notify on completion** for the Pickle. When enabled, Picky surfaces a macOS banner (and the main agent picks up the completion event) the moment the Pickle finishes. The same toggle is exposed via `Cmd + N` on the HUD.

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
| Compact | Ask Pi to compress older session context (see [§9.3](#93-compaction-ux)). Available only when the session is not running or compacting. |
| Rewind message… | Jump the conversation back to an earlier user message (see [§9.4](#94-message-rewind)). Available when the Pickle has a Pi session file. |
| Stop session | Abort the active session. |
| Archive | Archive the Pickle. |

The archived Pickle list lives in **Settings → Pickle → Archived sessions**, not in the card menu — see [§7.5](#75-archiving-and-undo).

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

### 9.4 Message rewind

Selecting **Rewind message…** opens a picker that mirrors Pi's `/tree`: it lists the Pickle's previous user messages (newest marked as the current position), with a short preview and relative time. You can open the same picker by typing `/tree` in the composer and submitting it.

Pick an earlier message and confirm to rewind the conversation to that point:

- The chosen message and everything after it are removed from the card.
- The chosen message's text is restored into the composer so you can edit it and continue from there.
- The earlier branch is preserved in the on-disk Pi session file (recover it with **Sync from Pi session** or the terminal overlay).

Rewind requires a Pi session file, so it is unavailable for sessions that have not produced one yet. If the Pickle is mid-turn, the active turn is stopped before rewinding.

## 10. HUD keyboard shortcuts

These work when a Pickle card/HUD panel is active.

| Shortcut | Action |
| --- | --- |
| Cmd + W | Close the open Pickle card. |
| Escape | Close the card when no text input is focused. |
| Return | Focus the active composer when no text input is focused. |
| Cmd + 1…9 | Open/close the Pickle in that dock slot; if the slot is a collapsed group, expand it instead. |
| Cmd + Shift + `[` | Cycle to previous Pickle. |
| Cmd + Shift + `]` | Cycle to next Pickle. |
| Cmd + R | Open latest agent response as a report. |
| Cmd + T | Toggle inline Pi terminal. |
| Cmd + Shift + T | Open separate Pi terminal overlay. |
| Cmd + N | Toggle Notify on completion. |
| Cmd + E | Toggle the **Extended terminal** — a local shell panel that opens below the card composer while the conversation stays visible above. Distinct from `Cmd + T`, which swaps the entire card body into a Pi terminal. |
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

- Menu bar panel → **Status → Recent conversation** → **Open in Pi**.
- Menu bar panel → **Status → Recent conversation** → **Copy resume command** to paste `pi --session ...` into your own shell.

Throughout this section "terminal overlay" means Picky's in-app Pi terminal panel (`PickyTerminalOverlay`), not an external Terminal.app window.

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
- Outline (table of contents) navigation. When a report has two or more headings, a toggle appears in the header (also `Cmd + Shift + O`) to show a section list; wide reports pin the outline beside the text, narrow reports overlay it. Your last outline visibility choice is remembered.
- In-report search (`Cmd + F`) that highlights matches and jumps between them with Enter / Shift + Enter.
- Open backing report file.
- Copy Markdown to clipboard.
- Persistent zoom.

Where reports live and when they go away:

- Every time you open a report, Picky writes a Markdown copy under `~/Library/Application Support/Picky/GeneratedReports/` named after the source message ID. Opening the same message again overwrites the same file rather than creating a new one.
- On each app launch Picky sweeps that folder and deletes Markdown files older than **30 days** (last modified). Non-`.md` files and subfolders are never touched, so anything you drop in there by hand stays put. The sweep runs in the background and silently no-ops on a fresh install or after a permissions hiccup.

Report shortcuts:

| Shortcut | Action |
| --- | --- |
| Cmd + F | Search within the report. |
| Cmd + Shift + O | Toggle the outline (when the report has 2+ headings). |
| Cmd + `=` | Zoom in. |
| Cmd + `-` | Zoom out. |
| Cmd + `0` | Reset zoom. |

## 13. Settings reference

#### Where your data lives

Picky is local-first and keeps everything under one durable folder:

```text
~/Library/Application Support/Picky/
  Settings/settings.json    — every preference, including API keys (plain JSON)
  Workspace/                — main agent cwd, seeded AGENTS.md, optional .pi/*
  sessions/                 — Pickle session history (active + archived)
  picky.json                — main agent runtime state (compaction summaries, etc.)
  skills/                   — Picky-only skill catalog (<name>/SKILL.md, seeded once,
                              freely hand-authored or deleted afterwards)
  GeneratedReports/         — Markdown copies of reports (swept after 30 days)
  Logs/                     — picky-agentd stdout/stderr logs
```

Only **screenshots** are written outside this tree, to the per-user temporary directory (`FileManager.default.temporaryDirectory/Picky/Screenshots`), so capture bytes do not accumulate in the durable folder.

**API keys typed into Settings are stored in plain JSON** inside `settings.json` (OpenAI/Azure/ElevenLabs keys, custom base URLs). When Picky needs a credential, it resolves it in this order: **(1) the matching `settings.json` field if non-empty, (2) the corresponding environment variable, (3) a consolidated Keychain entry at service `com.jonghakseo.picky.azure-openai` (account `AZURE_OPENAI_VOICE_CONFIG`)** — so env and Keychain are *fallbacks*, not overrides. If you want to keep secrets out of plain JSON, clear the Settings field first, then populate the env var or Keychain entry. Picky never writes to the Keychain itself; you populate the Azure entry by hand (for example with `security add-generic-password`). If you back up or share `settings.json`, scrub the secret fields first.

**Reinstalling Picky.app keeps everything above.** macOS only replaces the bundle in `/Applications`; the Application Support tree and any Keychain entries you populated survive. The Alpha build's "reinstall the latest alpha package" notice does not touch your settings, sessions, or workspace.

---

The Settings tab groups every leaf under one of three headers so the index reads as a short, scannable list rather than a flat menu. Each row also shows a one-line summary built from your current configuration (model, dock size, STT/TTS provider, enabled alert count, etc.) so the index doubles as a status overview.

| Group | Leaves |
| --- | --- |
| General | General, Shortcuts |
| Agents | Picky, Pickle, Tools |
| Surface | Voice, Overlay & Notifications |

The subsections below describe each leaf in the order it appears on the index.

### 13.1 General

| Setting | Values | Notes |
| --- | --- | --- |
| App language | System default, English, 한국어 | Most UI retranslates immediately. Some macOS-owned surfaces require relaunch. |
| Install `picky` shell command | Button | Installs or uninstalls the `picky` launcher in `/usr/local/bin` (or the closest writable directory). Useful because Picky is an `LSUIElement` app whose panels never activate the macOS top menu bar, so a normal "Install Shell Command…" menu item would never be visible. |

After installing the shell command, use it to drive Picky from a terminal or hardware automation:

```bash
picky submit "summarize the current screen"
picky pickle-create "Research" --instructions "Compare the open tabs" --group "Research"
picky pickle-list --archived --query sentry
picky pickle-archive <session-id>
picky pickle-unarchive <session-id>
picky pickle-group-list
picky pickle-followup <session-id> "focus on production impact"
picky ptt press
picky ptt release
```

`picky pickle-create --group <name>` places the new Pickle in the named dock group, creating that group when needed. If multiple groups share the same name, Picky uses the first matching group in dock order. `picky pickle-list --archived` shows Pickles hidden from the dock; add `--query <text>` to search by ID, title, cwd, status, summary, or final answer. `picky pickle-archive <session-id>` hides a Pickle, and `picky pickle-unarchive <session-id>` restores it while it is still inside Picky's current 7-day archived-session retention window. `picky pickle-group-list --json` returns group IDs, names, colors, collapsed state, and member session IDs for scripting.

### 13.2 Shortcuts

| Setting | Default | Notes |
| --- | --- | --- |
| Push to Talk | Control + Option | Hold to start voice; release to send. |
| Quick Input | Double-tap Control | Opens quick text composer near cursor. |

Use **Change**, then **Save** or **Cancel**. Conflicts are rejected. **Reset to defaults** restores both defaults.

### 13.3 Picky

| Setting | Values / behavior |
| --- | --- |
| Picky cwd | Applies to captured Picky context and the next Picky session. Defaults to the seeded Picky workspace at `~/Library/Application Support/Picky/Workspace`. Must be an existing directory. See **Customizing the Picky workspace** below. |
| Pi binary | Optional path to the `pi` executable. Leave empty to auto-discover via `PI_CODING_AGENT_DIR/bin/pi`, then `PATH` (`which pi`), then `~/.pi/agent/bin/pi`. Used when Picky runs `pi install/remove`; install/remove actions pick it up immediately. |
| PI_CODING_AGENT_DIR | Optional Pi coding-agent directory for Pi sessions and extension/skill installs. Leave empty to use the launch environment's `PI_CODING_AGENT_DIR`, then fallback to `~/.pi/agent`. Must be an existing directory when set. Extension/skill installs pick it up immediately; running Picky/Pi sessions apply it after restarting Picky. |
| Pi model | Automatic or a pinned model pattern. |
| Reasoning level | Off, Minimal, Low, Medium, High, Extra High, Maximum. Maximum appears only for Pi models that support it. |
| Screen context | All screens or Focused screen only. Default is **Focused screen only** so Picky captures only the display the cursor is on. |
| Armed Pickle delivery | Follow-up (default) or Steer. Controls how Push-to-Talk and Quick Input are delivered when a Pickle is explicitly armed as the screen-context target. Follow-up waits until the Pickle is idle; Steer interrupts the current turn at the next steering point. |
| Send screenshots only when drawn | Off (default) or On. When **On**, Picky attaches a screenshot to the model turn only if you marked the screen with click and drag during Push-to-Talk or Quick Input. Screen capture still runs locally so the ink overlay can render on top, but the screenshot is omitted from what the model sees. Off keeps the always-attach behavior. |
| Screenshot quality | 1× 1280 px, 1.5× 1920 px, 2× 2560 px longest edge. Captured screenshots are written to the per-user temporary directory (`FileManager.default.temporaryDirectory/Picky/Screenshots`), not the durable Application Support tree. |
| Additional instructions | Extra standing instructions baked into the Picky bootstrap; apply on next Picky session/relaunch. |

When saved changes require a fresh process (currently the effective `PI_CODING_AGENT_DIR` for running Picky/Pi sessions), the footer action changes from **Quit** to **Restart** so you can apply them without manually reopening Picky.

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

### 13.4 Pickle

| Setting | Values / behavior |
| --- | --- |
| Default cwd | Default working directory for new Pickles. Must be an existing directory. |
| Pickle model | Automatic or pinned initial model for newly-created Pickles. |
| Reasoning level | Automatic, Off, Minimal, Low, Medium, High, Extra High, Maximum. Applies as the initial setting for new Pickles; Maximum requires a Pi model that supports it. |
| Dock size | S, M, L. |
| Git chip actions | Optional command bound to the diff and branch chips on each Pickle card. Each slot picks a kind (Pi or shell) and a command string; empty commands leave the chip unconfigured. |
| Archived sessions | Footer disclosure (hidden when empty). Expands to the same restore/delete list available from the HUD, so you can manage archives without leaving Settings. |

Running Pickles can still cycle model/thinking independently from these defaults.

### 13.5 Tools

Built-in tools that the agents can call. Each row is an individual toggle; turning a tool off removes it from the agent's tool list entirely so it cannot be called. **Screen pointing & drawing** controls all agent-authored pointer and shape overlays as one capability.

Changes apply to the main agent immediately and interrupt any in-progress turn. Pickles that started before the change keep their existing tool list until the next turn.

### 13.6 Voice (STT & TTS)

Picky supports Apple/macOS built-in, OpenAI direct (`api.openai.com`), Azure
OpenAI, and ElevenLabs for speech recognition and synthesis. **Edge TTS
(Online)** is an additional playback-only, explicit opt-in provider; it sends
spoken response text to Microsoft Edge Read Aloud through local `picky-agentd`.
Each provider's relevant settings appear only when that provider is selected.

| Setting | Values / behavior |
| --- | --- |
| STT provider | Apple Speech (default), OpenAI, Azure OpenAI, ElevenLabs. Apple Speech uses the on-device `SFSpeechRecognizer` (offline). OpenAI uses `gpt-4o-transcribe` against `api.openai.com`. Azure OpenAI uses your deployment URL. ElevenLabs uses `scribe_v2` against `api.elevenlabs.io` (the legacy `scribe_v1` is deprecated as of 2026). |
| Enable spoken replies (TTS) | On/off. When off, text replies still appear but audio playback is skipped. Long narrated replies can begin playing sentence by sentence while the remaining response is still streaming. |
| TTS provider | macOS Speech (default), OpenAI, Azure OpenAI, ElevenLabs, Edge TTS (Online, explicit opt-in; playback only). macOS Speech uses the system `NSSpeechSynthesizer` voice. OpenAI uses `gpt-4o-mini-tts` against `api.openai.com`. ElevenLabs uses `eleven_multilingual_v2` against `api.elevenlabs.io` by default. Edge TTS sends spoken response text to Microsoft Edge Read Aloud through local `picky-agentd`. |
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

ElevenLabs TTS fields (when TTS provider = ElevenLabs):

- ElevenLabs TTS API key — leave empty to reuse the STT key, then `ELEVENLABS_API_KEY` from the environment
- ElevenLabs TTS voice ID — required unless `ELEVENLABS_VOICE_ID` is set in the environment
- ElevenLabs TTS model — leave blank for `eleven_multilingual_v2`
- ElevenLabs TTS output format — leave blank for `mp3_44100_128`
- ElevenLabs TTS base URL — leave blank for `https://api.elevenlabs.io`

> **Edge TTS (Online, explicit opt-in; playback only).** Choose **Edge TTS
> (Online)** in the TTS provider picker, then select a language and voice. Picky
> sends spoken response text through its local `picky-agentd` adapter to Microsoft
> Edge Read Aloud. This unofficial service may change or become unavailable; Picky
> falls back to macOS Speech if it fails. macOS Speech remains the default. Picky
> uses the MIT-licensed `msedge-tts` package for this adapter.

### 13.7 Overlay & Notifications

Combined page for everything Picky surfaces back to you — cursor overlay, speech bubbles, and macOS notification banners. Inside the page, the three groups are separated by small `Cursor` / `Bubbles` / `Alerts` subgroup headers.

**Cursor**

| Setting | Default | Meaning |
| --- | --- | --- |
| Show Picky Cursor | On | Shows the cursor buddy overlay. |
| Smooth cursor follow | On | Enables springy cursor-follow animation. |
| Idle animations | On | Enables idle cursor animations. |

If **Show Picky Cursor** is off, smooth follow and idle animations are disabled. Picky still shows a minimal waiting indicator near the system cursor while a cursor-side request is in flight, then hides it again when the response arrives or the request ends.

While the Mac App Store is the frontmost app, Picky temporarily hides the cursor overlay and brings it back when you switch away. macOS suppresses secure purchase confirmations whenever another app's window overlaps them, so this keeps App Store purchase sheets working while Picky runs.

**Bubbles**

| Setting | Default | Meaning |
| --- | --- | --- |
| User STT recognition | On | Shows recognized speech bubble. |
| Picky reply text | On | Shows Picky reply bubble. |

**Alerts**

| Setting | Default | Meaning |
| --- | --- | --- |
| On success | Off | Show macOS banner when a session completes. |
| On failure | On | Show banner when a session fails. |
| On input request | On | Show banner when a session waits for user input. |

### 13.8 Updates

Update controls live in the Status tab.

| Control | Values / behavior |
| --- | --- |
| Channel | Pinned by the installed build (Stable, Beta, or Alpha). The Updates row shows the active channel on the build line; there is no in-app channel switcher. To move between channels, install the matching release artifact (DMG for beta/stable, trusted internal zip/package for alpha). |
| Check automatically every 4 hours | Toggle that enables Sparkle automatic checks where available. |
| Check Now | Manual update check. |

Alpha builds replace the controls above with a one-line reinstall notice because the alpha channel is not exposed through Sparkle's appcast — the updater is not started for alpha builds, so installing a new alpha means downloading the next trusted internal alpha zip/package manually.

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
2. Pick the surface that fits the task:
   - `Cmd + T` swaps the card body itself into the Pi terminal (chat is hidden while the terminal owns the card). Closing it syncs the HUD card from the Pi session file.
   - `Cmd + Shift + T` opens the full Pi terminal overlay as a separate Picky window. Same Pi session, same sync behavior.
   - `Cmd + E` toggles the **Extended terminal** — a *local shell* panel below the card composer, **not** the Pi session. Use it for ad-hoc commands in the Pickle cwd; closing it does not affect the Pi session or trigger any sync.
3. For `Cmd + T` / `Cmd + Shift + T`, work in the Pi TUI and close the terminal to sync back into the HUD card.

### 14.6 Clean up finished Pickles

1. Press and hold a dock icon, right-click → **Archive**, or use the card menu → **Archive**.
2. If it was accidental, click **Undo** in the archive toast.
3. After the toast disappears, open **Settings → Pickle → Archived sessions** to restore (or permanently delete) an archived Pickle. Picky also restores archived Pickles when you ask the main agent (e.g. "되살려", "bring back that pickle"), which routes through the same `picky_unarchive_pickle` path.

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

1. Open the menu bar panel, stay on the **Status** tab, and click the **Recent conversation ›** row.
2. Click **Open in Pi** to launch the in-app Pi terminal overlay, or **Copy resume command** to paste `pi --session ...` into an external shell.
3. Work directly in the Pi TUI. Closing the overlay syncs the visible state back into the Picky panel.

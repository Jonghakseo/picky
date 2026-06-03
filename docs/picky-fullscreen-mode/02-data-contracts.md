# 02. Data contracts

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; current data contract reflects the feature-gated implementation.

## Rule

Fullscreen uses existing Pickle data only.

Allowed sources:

- `PickySessionListViewModel`
- `PickySessionListViewModel.SessionCard`
- `PickyAgentSession`
- `PickySessionMessage`
- existing view-model actions
- existing composer state/draft/attachment mechanisms

Do not use one-shot screen context packet fields as if they were session fields.

## `PickyAgentSession` vs `SessionCard`

`PickyAgentSession` is the daemon protocol model. `PickySessionListViewModel.SessionCard` is the SwiftUI-facing projection fullscreen should normally consume.

Do not treat them as identical.

### `PickyAgentSession` fields

```swift
id
title
status
cwd
piSessionFilePath
createdAt
updatedAt
lastSummary
thinkingPreview
finalAnswer
logs
tools
artifacts
changedFiles
messages
queuedSteers
queuedFollowUps
steeringMode
followUpMode
activitySummary
contextUsage
currentAssistantRun
pendingExtensionUiRequest
notifyMainOnCompletion
archived
pinned
```

### `SessionCard` fields

```swift
id
title
status
cwd
createdAt
updatedAt
lastSummary
thinkingPreview
logPreview
lastRequestText
lastRequestAt
tools
artifacts
changedFiles
messages
queuedSteers
queuedFollowUps
steeringMode
followUpMode
activitySummary
lastTerminalSyncOutcome
contextUsage
currentAssistantRun
pendingExtensionUiRequest
piSessionFilePath
notifyMainOnCompletion
pinned
archived
hasRuntimeDetachedFollowUpRejection
isMainAgentHandoff
```

Important: `SessionCard.finalAnswer` does not exist. Fullscreen conversation rendering must derive visible final answer from `session.messages`.

## Message fields

```swift
PickySessionMessage:
- id
- kind
- createdAt
- originatedBy
- text
- question
- cancelledAt
- activitySnapshot
- assistantRun
- errorContext
- errorMessage
- notifyType
- commandReceipt
- attachedImagesCount
```

## Existing composer capabilities

Fullscreen composer may reuse only existing capabilities:

- `viewModel.followUp(text:sessionID:)`
- slash command autocomplete
- file mention autocomplete
- dropped file/screenshot path insertion
- draft per session
- attachments per session
- screen context target chip
- notify on completion toggle
- extended terminal toggle
- send button
- stop button when session is running/waiting with prior messages
- bash/private bash mode triggered by existing syntax
- `viewModel.cycleModel(sessionID:direction:)`
- `viewModel.cycleThinkingLevel(sessionID:)`

## Final answer policy

For a completed/non-current turn:

1. Prefer the last message with `kind == agent_text` as the primary final answer.
2. If no `agent_text` exists, use the last `agent_error`.
3. Render completion/failure system messages as separate compact status rows.
4. If intermediate non-thinking work messages exist and a work duration can be computed, show them only behind the expandable work-summary row.
5. Do not use `PickyTurnGroup.collapsedRepresentativeMessage` directly as the final answer because it can choose a system message.

For a running/current turn:

- show user request
- show live activity/progress rows
- show latest useful assistant text
- show tool activity summary if present

This policy should live in `PickyFullscreenTurnPolicy` and have unit tests.

## Effective assistant run policy

Model/thinking display must use fallback logic consistent with the HUD header:

```swift
let effectiveAssistantRun = session.currentAssistantRun
    ?? session.messages.reversed().compactMap(\.assistantRun).first
```

Use this for the center header model/thinking chip. Context usage is also displayed in the center header, not in the right `변경사항` panel.

## Center changed-files card scope

The center conversation can show a compact changed-files card after a completed turn:

- `변경 파일`: turn-scoped file list derived from fullscreen turn git snapshots and lazy diff resolution.
- `세션 변경 파일`: fallback shown on the last completed turn when no turn snapshot exists and only session-level `PickyChangedFile` data is available.

Both variants use `PickyChangedFile` fields:

```swift
path
status
summary
```

Do not overclaim the source:

- use `변경 파일` only when turn snapshots/diffs scoped it to that turn
- use `세션 변경 파일` for session-level fallback
- do not add fake file summaries
- do not show unstored diff hunks in the center card

The right `변경사항` panel below is allowed to show read-only git/diff metrics separately because it is explicitly labelled as change/worktree metadata.

## Right panel allowed data

The current right panel is labelled `변경사항` and may show read-only data from the selected session and its local `cwd`:

```text
변경사항
├─ session changed files
│  └─ changedFiles path/status/summary
├─ artifacts
│  └─ artifacts kind/title/path/url/updatedAt
├─ branch/worktree summary
│  └─ current branch, upstream/ahead/behind, changed-file counts
├─ line metrics
│  └─ read-only + / - totals from git numstat
└─ per-file rows
   └─ path/status/optional numstat/diff-derived metadata
```

The panel must remain read-only. It may summarize local git metadata, but it must not create, checkout, push, open PRs, or otherwise mutate worktree/cloud state.

## Explicitly unavailable

Do not show these in fullscreen right panel unless a later design intentionally persists them as session/worktree data:

- active app
- active window
- current browser URL/title
- selected text
- screenshot paths
- screen thumbnails
- mutating PR/cloud/worktree controls

Phase 07 tracks the product decision for the boundary between allowed read-only branch/worktree metadata and forbidden IDE/git controls.

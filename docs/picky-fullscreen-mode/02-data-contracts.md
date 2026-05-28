# 02. Data contracts

Status: design only.

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

1. Prefer the last message with `kind == agent_text`.
2. If no `agent_text` exists, use the last `agent_error`.
3. Render completion/failure system messages as separate compact status rows.
4. Do not use `PickyTurnGroup.collapsedRepresentativeMessage` directly as the final answer because it can choose a system message.

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

Use this for:

- header model chip
- header thinking chip
- right-panel runtime row

## Changed files scope

`PickyChangedFile` currently provides session-level data such as:

```swift
path
status
summary
```

MVP must not imply per-turn diff ownership.

UI copy:

- Preferred label: `세션 변경 파일`
- Acceptable alternative: `변경 파일` with a session-scope subtitle

Do not show:

- `+143 -62`
- exact turn association
- unstored diff hunks
- fake file summaries

## Right panel allowed data

`작업 정보` can show only data derived from `SessionCard`:

```text
상태
  status
  createdAt / updatedAt
  notifyMainOnCompletion
  pinned / archived if true

런타임
  effectiveAssistantRun.model
  effectiveAssistantRun.thinkingLevel
  piSessionFilePath exists? resume possible

컨텍스트 사용량
  contextUsage.tokens
  contextUsage.contextWindow
  contextUsage.percent

현재/마지막 턴 활동
  running: session.activitySummary
  completed: latest message.activitySnapshot if available

도구 히스토리
  tools name/status/preview/timestamps

세션 변경 파일
  changedFiles path/status/summary

링크와 산출물
  artifacts kind/title/path/url/updatedAt

대기 중 입력
  pendingExtensionUiRequest
  queuedSteers
  queuedFollowUps
```

## Explicitly unavailable in MVP

Do not show these in fullscreen right panel:

- active app
- active window
- current browser URL/title
- selected text
- screenshot paths
- screen thumbnails
- git branch if not already available through existing HUD context logic
- PR/cloud/worktree status
- line additions/deletions

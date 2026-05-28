# Phase 04. Center conversation rendering

Goal: render a clean LLM chat UI with correct running/completed turn behavior.

## Files

Create:

- `Picky/Fullscreen/Views/PickyFullscreenConversationPaneView.swift`
- `Picky/Fullscreen/Views/PickyFullscreenConversationListView.swift`
- `Picky/Fullscreen/Views/PickyFullscreenTurnView.swift`
- `Picky/Fullscreen/Views/PickyFullscreenChangedFilesCardView.swift`
- `Picky/Fullscreen/Domain/PickyFullscreenTurnPolicy.swift`
- `Picky/Fullscreen/Domain/PickyFullscreenAssistantRunResolver.swift`

Tests:

- `PickyTests/PickyFullscreenTurnPolicyTests.swift`
- `PickyTests/PickyFullscreenAssistantRunResolverTests.swift`

## Design requirements

- Center is an LLM chat, not a log dashboard.
- Running/current turn shows live progress.
- Completed/non-current turns show final assistant answer only.
- System status rows are separate from final answer.
- Changed files card is labelled as session-level data.

## Turn policy

Completed/non-current turn:

```text
show user_text / command_receipt
show final assistant answer:
  last agent_text
  else last agent_error
hide agent_thinking
hide agent_activity
hide intermediate agent_text
show compact system rows separately if relevant
```

Running/current turn:

```text
show user_text / command_receipt
show live agent_activity
show visible tool/activity progress
show latest assistant text
show waiting/error state if applicable
```

## Steps

1. Add `PickyFullscreenTurnPolicy` pure helper.
2. Add unit tests for completed turn final answer selection.
3. Add unit tests for running/current turn visibility.
4. Add `PickyFullscreenAssistantRunResolver` tests.
5. Build conversation pane/header using selected session.
6. Add session-level changed files card near latest answer.

## Validation

- completed turns do not show progress noise
- running turns show activity only while running
- `collapsedRepresentativeMessage` is not used as final answer selector
- model/thinking fallback works when `currentAssistantRun == nil`
- changed files card says `세션 변경 파일` or has equivalent session-scope copy

## Exit criteria

- Conversation view is useful for reading final LLM output, not replaying logs.

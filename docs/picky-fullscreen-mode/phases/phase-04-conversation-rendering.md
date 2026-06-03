# Phase 04. Center conversation rendering

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: render a clean LLM chat UI with correct running/completed turn behavior.

## Files

Current files:

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
- Completed/non-current turns show the final assistant answer as the primary body.
- Intermediate completed-turn work logs are hidden behind the expandable work-summary row.
- System status rows are separate from final answer.
- Changed-files cards are labelled by scope: `변경 파일` for turn-scoped git snapshots/diffs, `세션 변경 파일` for session-level fallback.

## Turn policy

Completed/non-current turn:

```text
show user_text / command_receipt
show final assistant answer:
  last agent_text
  else last agent_error
hide agent_thinking
hide agent_activity from the primary body
hide intermediate agent_text from the primary body
show expandable work summary when intermediate work messages/duration exist
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

## Current implementation notes

- Conversation pane/list/turn views and changed-files card are implemented under `Picky/Fullscreen/Views`.
- `PickyFullscreenTurnPolicy` and `PickyFullscreenAssistantRunResolver` have focused tests.
- Keep future changes aligned with the clean-chat rule: completed turns should not replay noisy progress logs inline; use the expandable work summary for optional detail.

## Validation

- completed turns do not show progress noise inline; optional detail stays behind work summary
- running turns show activity only while running
- `collapsedRepresentativeMessage` is not used as final answer selector
- model/thinking fallback works when `currentAssistantRun == nil`
- changed files card says `변경 파일` for turn-scoped diffs or `세션 변경 파일` for session-level fallback

## Exit criteria

- Conversation view is useful for reading final LLM output, with work details available only on demand.

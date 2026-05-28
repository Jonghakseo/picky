# 04. Testing, risks, acceptance

Status: design only.

## Unit tests

Add focused tests where logic is pure:

- `PickyFullscreenStateStoreTests`
  - persists right panel visibility
  - restores selected session ID
- `PickyFullscreenTurnPolicyTests`
  - completed turn chooses last `agent_text`
  - completed turn falls back to `agent_error`
  - completed turn separates system completion rows
  - running turn includes live activity
- `PickyFullscreenAssistantRunResolverTests`
  - prefers `currentAssistantRun`
  - falls back to latest message `assistantRun`
- `PickyFullscreenWorkInfoSnapshotTests`
  - derives only existing fields
  - handles empty tools/artifacts/context usage
- coordinator/mode tests with fakes if practical
  - open hides HUD before showing fullscreen
  - close restores HUD after fullscreen close
  - repeated open/close is idempotent

## Build/test commands

Use targeted validation while iterating:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" build
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test -only-testing:PickyTests/PickyFullscreenTurnPolicyTests
```

Broader validation when phases are integrated:

```bash
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" test
```

Do not restart the running Picky app unless explicitly asked.

## Manual QA checklist

1. Start with multiple Pickles: one running, one completed, one waiting.
2. Click dock expand button.
3. Verify fullscreen opens intended Pickle.
4. Verify HUD dock/panels are hidden.
5. Switch sessions from sidebar.
6. Send follow-up from fullscreen composer.
7. Confirm underlying session updates.
8. Drop file into center pane.
9. Confirm file path appears in composer.
10. Test slash command autocomplete.
11. Test file mention autocomplete.
12. Arm screen context.
13. Confirm screen context chip appears.
14. Run long task.
15. Confirm live progress appears only while running.
16. Confirm completed turn collapses to final answer only.
17. Confirm changed files are labelled as session-level data.
18. Toggle right panel closed/open.
19. Close fullscreen and reopen.
20. Confirm right panel state is remembered.
21. Confirm `⌘W` closes fullscreen, not app.
22. Confirm HUD dock/panels return after fullscreen closes.
23. Confirm HUD dock drag/hover/add Pickle still works after returning.
24. Confirm no permission selector appears.
25. Confirm no plan mode / goal suggestion / plugin menu appears.
26. Confirm no cloud/worktree/PR controls appear.
27. Confirm fullscreen chrome is not recursively captured by screen context.

## Risks and mitigations

### Duplicate composer instances overwrite draft or attachments

Mitigation: dock/fullscreen modes are mutually exclusive. HUD composer unmounts before fullscreen composer mounts, and fullscreen composer unmounts before HUD returns.

### Fullscreen renders unavailable context details

Mitigation: right panel uses only `SessionCard`/`PickyAgentSession` data. Active app/browser/selected text are excluded from MVP.

### Changed files imply exact per-turn data

Mitigation: label as `세션 변경 파일` or use a session-scope subtitle. Do not show line counts or exact turn claims.

### HUD and fullscreen selection fight each other

Mitigation: fullscreen row selection is local. Audit existing view-model actions that may intentionally update global selection.

### True macOS fullscreen conflicts with menu bar app assumptions

Mitigation: start with a large normal `NSWindow` with fullscreen capability. Auto-enter true fullscreen only after shell behavior is stable.

### Performance regression from wider Markdown rendering

Mitigation: lazy rows, scoped Markdown rendering, pure turn policy, profile with existing perf guide before guessing.

## Acceptance criteria

- Dock expand button opens fullscreen for intended Pickle.
- Dock mode is hidden while fullscreen is open.
- Closing fullscreen restores dock mode.
- Center is clean LLM chat UI.
- Running turns show progress only while running.
- Completed turns show final assistant answer only.
- Composer preserves existing Pickle capabilities without copied behavior.
- Right `작업 정보` panel is collapsible and persisted.
- Right panel uses existing session data only.
- Changed files are session-level.
- Fullscreen window is excluded from Picky screen capture.
- No Codex-only controls appear.

# Phase 06. Right work info panel

Goal: add collapsible `작업 정보` panel using existing session data only.

## Files

Create:

- `Picky/Fullscreen/Views/PickyFullscreenWorkInfoPanelView.swift`
- `Picky/Fullscreen/Domain/PickyFullscreenWorkInfoSnapshot.swift`

Modify:

- `Picky/Fullscreen/Views/PickyFullscreenWorkspaceView.swift`
- `Picky/Fullscreen/PickyFullscreenStateStore.swift`

Tests:

- `PickyTests/PickyFullscreenWorkInfoSnapshotTests.swift`

## Design requirements

- Product label: `작업 정보`.
- Panel is read-only.
- Collapsed/open state is persisted globally in MVP.
- Every displayed row is derived from `SessionCard`.
- No unavailable desktop context details.

## Sections

```text
작업 정보
├─ 상태
├─ 런타임
├─ 컨텍스트 사용량
├─ 현재/마지막 턴 활동
├─ 도구 히스토리
├─ 세션 변경 파일
├─ 링크와 산출물
└─ 대기 중 입력
```

## Data classification gate

Before adding a row, classify it:

```text
A. Existing HUD-visible feature reused/rearranged
B. Existing session data newly summarized in fullscreen
C. New data required — not allowed in MVP
```

Only A and B are allowed.

## Steps

1. Add `PickyFullscreenWorkInfoSnapshot` projection from `SessionCard`.
2. Add tests for nil/empty states.
3. Render panel sections with empty-state copy.
4. Add collapse rail.
5. Persist collapsed/open state.
6. Ensure panel width changes do not animate entire conversation list.

## Validation

- no active app/window/browser/selected text rows
- changed files are session-level
- empty tools/artifacts/context usage look intentional
- toggle state survives close/reopen
- VoiceOver labels identify panel and collapse button

## Exit criteria

- Right panel adds useful session context without pretending to know unavailable data.

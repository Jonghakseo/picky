# Phase 06. Right work info panel

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: maintain the collapsible read-only `변경사항` panel for session artifacts, changed files, and local git/diff metadata.

## Files

Current files:

- `Picky/Fullscreen/Views/PickyFullscreenWorkInfoPanelView.swift`
- `Picky/Fullscreen/Domain/PickyFullscreenWorkInfoSnapshot.swift`

Modify:

- `Picky/Fullscreen/Views/PickyFullscreenWorkspaceView.swift`
- `Picky/Fullscreen/PickyFullscreenStateStore.swift`

Tests:

- `PickyTests/PickyFullscreenWorkInfoSnapshotTests.swift`

## Design requirements

- Product label: `변경사항`.
- Panel is read-only.
- Collapsed/open state is persisted globally in MVP.
- Session changed files/artifacts are derived from `SessionCard`; branch/worktree rows are derived read-only from the selected session `cwd`.
- No unavailable desktop context details.

## Sections

```text
변경사항
├─ 브랜치 / 작업 트리 요약
├─ 세션 변경 파일
├─ 브랜치 변경 파일
├─ 링크와 산출물
└─ 접기/펼치기 rail
```

## Data classification gate

Before adding a row, classify it:

```text
A. Existing HUD-visible feature reused/rearranged
B. Existing session data newly summarized in fullscreen
C. New mutating capability required — not allowed without a product decision
```

A and B are allowed. Read-only git/diff metadata is allowed by the current implementation but remains tied to the phase 07 product-decision boundary; mutating branch/worktree/PR/cloud controls are not allowed.

## Current implementation notes

- `PickyFullscreenWorkInfoSnapshot` projects session changed files and artifacts.
- `PickyFullscreenWorkInfoPanelView` renders the `변경사항` panel and collapse rail.
- `PickyFullscreenBranchDiffProvider` / `PickyFullscreenFileDiffProvider` add read-only git/diff metadata from `cwd`.
- Panel visibility is persisted in `PickyFullscreenStateStore`.

## Validation

- no active app/window/browser/selected text rows
- changed files and git/diff metrics are labelled as change/worktree data, not per-turn claims
- empty artifacts or no-git/non-repository states look intentional
- toggle state survives close/reopen
- VoiceOver labels identify panel and collapse button

## Exit criteria

- Right panel adds useful read-only change context without pretending to know transient desktop context or offering mutating IDE/git controls.

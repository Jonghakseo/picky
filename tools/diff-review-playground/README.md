# Picky Diff Review Playground

Standalone SwiftUI playground for iterating on the upcoming Picky built-in changed-files viewer without rebuilding `Picky.app`.

## Run

From the repo root:

```bash
scripts/diff-review-playground.sh fixture
scripts/diff-review-playground.sh repo ~/Documents/picky
scripts/diff-review-playground.sh diff /tmp/some-unified.diff
```

The playground is a separate Swift Package executable under `tools/diff-review-playground`, so UI edits here only rebuild this tiny target.

## What it tests

- GitHub-style changed files layout
- File sidebar with status badges and insertion/deletion counts
- Unified diff rendering with old/new line gutters
- File-level and line-level comment draft flow
- Overall feedback box
- Feedback prompt generation via clipboard
- Safe working-tree snapshot loading with a temporary git index

## Production port notes

When the UX is stable, port the reusable pieces into Picky:

- `DiffReviewModels.swift` -> `Picky/Sessions/PickyGitDiffSnapshot.swift`
- `DiffReviewSource.swift` repo snapshot logic -> `Picky/Sessions/PickyGitDiffSnapshotLoader.swift`
- `UnifiedDiffParser.swift` -> `Picky/Sessions/PickyUnifiedDiffParser.swift`
- `DiffReviewViews.swift` -> `Picky/HUD/PickyDiffReviewViewer.swift`
- `DiffReviewPromptBuilder.swift` -> `Picky/HUD/PickyDiffReviewPromptBuilder.swift`

In Picky, replace the playground's clipboard action with a composer draft insertion for the selected session.

# Phase 08. Polish, animation, accessibility, performance

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; keep this phase doc as historical notes plus current validation pointers.

Goal: make the fullscreen workspace feel native and stable without fragile cross-window effects.

## Files

Modify:

- fullscreen views
- dock expand button view
- accessibility labels where needed
- focused performance hotspots if profiling indicates issues

## Animation rules

- Keep transitions simple: hide dock, show fullscreen window, mount workspace.
- Avoid matched geometry across `NSPanel` and `NSWindow`.
- Use explicit `.animation(..., value:)` on local state only.
- Respect reduced motion.
- Do not animate the entire session list or conversation list on every message update.

## Accessibility rules

- Expand button has clear label: “Open fullscreen workspace”.
- Close/collapse controls have labels and keyboard focus.
- Sidebar rows expose title/status.
- Right panel is labelled `변경사항`, including expanded/collapsed accessibility labels.
- Composer keeps existing accessibility behavior.
- Keyboard navigation supports common app behavior:
  - `⌘W` closes fullscreen window, not app
  - `Esc` may close transient menus, not necessarily fullscreen
  - tab order: sidebar → conversation → composer → right panel

## Performance rules

- Avoid recomputing turn grouping for every unrelated state update.
- Keep Markdown rendering scoped to message rows.
- Use lazy stacks for long conversations.
- Avoid expensive shadows/blur over full-window surfaces.
- Profile HUD/fullscreen lag with existing `docs/perf-profiling.md` before guessing.

## Current implementation notes

- Dock expand, close/collapse controls, `⌘W`, reduced motion handling, and lazy conversation rendering are implemented.
- Keep this phase as the polish checklist for future changes: accessibility labels, scoped animation, long conversation performance, and recursive screen-capture checks.

## Validation

- `⌘W` closes fullscreen
- dock returns after close
- VoiceOver can identify key controls
- long conversations remain scrollable
- running updates do not cause dock/sidebar jumpiness
- no recursive screenshot of fullscreen chrome

## Exit criteria

- Workspace feels stable enough for alpha testing.

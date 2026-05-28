# Phase 08. Polish, animation, accessibility, performance

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
- Right panel is labelled `작업 정보`.
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

## Steps

1. Add labels and keyboard shortcuts.
2. Add reduced-motion friendly transitions.
3. Audit implicit animations.
4. Test long conversation scroll performance.
5. Test running task live updates.
6. Polish visual spacing, panel widths, empty states.

## Validation

- `⌘W` closes fullscreen
- dock returns after close
- VoiceOver can identify key controls
- long conversations remain scrollable
- running updates do not cause dock/sidebar jumpiness
- no recursive screenshot of fullscreen chrome

## Exit criteria

- Workspace feels stable enough for alpha testing.

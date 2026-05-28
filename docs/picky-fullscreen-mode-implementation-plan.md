# Picky fullscreen workspace implementation plan

Status: design and implementation plan only. Do not implement until explicitly approved.

This document is now an index. Detailed planning lives under `docs/picky-fullscreen-mode/` so each phase can be reviewed and implemented independently.

## Product decision

Picky fullscreen mode is a focused workspace for an existing Pickle session.

Hard UX rule:

- Dock mode and fullscreen mode are mutually exclusive.
- Opening fullscreen hides the HUD dock/panels and unmounts the compact Pickle composer.
- Closing fullscreen restores dock mode.
- UI mode changes must never cancel, reset, or mutate Pickle sessions.

## Document map

| Document | Purpose |
| --- | --- |
| [`docs/picky-fullscreen-mode/README.md`](picky-fullscreen-mode/README.md) | Scope, success criteria, and review order |
| [`00-product-ux.md`](picky-fullscreen-mode/00-product-ux.md) | Final UX shape and non-goals |
| [`01-swift-architecture.md`](picky-fullscreen-mode/01-swift-architecture.md) | Swift/AppKit/SwiftUI architecture, module responsibilities, ownership boundaries |
| [`02-data-contracts.md`](picky-fullscreen-mode/02-data-contracts.md) | Existing data only, `PickyAgentSession` vs `SessionCard`, rendering policy |
| [`03-interactions-state.md`](picky-fullscreen-mode/03-interactions-state.md) | Mode transitions, session selection, composer lifecycle, persistence |
| [`phases/phase-01-shell-window-lifecycle.md`](picky-fullscreen-mode/phases/phase-01-shell-window-lifecycle.md) | Fullscreen shell, strong window ownership, capture exclusion |
| [`phases/phase-02-dock-entry-mode-transition.md`](picky-fullscreen-mode/phases/phase-02-dock-entry-mode-transition.md) | Dock expand entry point and dock/fullscreen mode switching |
| [`phases/phase-03-sidebar-session-selection.md`](picky-fullscreen-mode/phases/phase-03-sidebar-session-selection.md) | Left sidebar and local fullscreen selection |
| [`phases/phase-04-conversation-rendering.md`](picky-fullscreen-mode/phases/phase-04-conversation-rendering.md) | LLM chat rendering and completed/running turn policy |
| [`phases/phase-05-composer-reuse.md`](picky-fullscreen-mode/phases/phase-05-composer-reuse.md) | Reuse existing Pickle composer safely |
| [`phases/phase-06-work-info-panel.md`](picky-fullscreen-mode/phases/phase-06-work-info-panel.md) | Right `작업 정보` panel from existing session data |
| [`phases/phase-07-new-pickle-lifecycle-polish.md`](picky-fullscreen-mode/phases/phase-07-new-pickle-lifecycle-polish.md) | New Pickle affordance and lifecycle polish |
| [`phases/phase-08-polish-animation-accessibility.md`](picky-fullscreen-mode/phases/phase-08-polish-animation-accessibility.md) | Animation, accessibility, keyboard, performance polish |
| [`04-testing-risk-acceptance.md`](picky-fullscreen-mode/04-testing-risk-acceptance.md) | Unit/UI/manual QA, risks, acceptance criteria |

## Recommended review sequence

1. Approve [`00-product-ux.md`](picky-fullscreen-mode/00-product-ux.md).
2. Approve [`01-swift-architecture.md`](picky-fullscreen-mode/01-swift-architecture.md).
3. Approve [`02-data-contracts.md`](picky-fullscreen-mode/02-data-contracts.md) and [`03-interactions-state.md`](picky-fullscreen-mode/03-interactions-state.md).
4. Implement phases in order from phase 01 to phase 08.
5. Validate against [`04-testing-risk-acceptance.md`](picky-fullscreen-mode/04-testing-risk-acceptance.md).

## MVP acceptance criteria

- Dock has a clear fullscreen expand button that does not conflict with add Pickle.
- Clicking it hides dock mode and opens a fullscreen-capable workspace for the intended Pickle.
- Center is a clean LLM chat UI.
- Running turns show live progress.
- Completed turns show final assistant answer only, with system status rows separated.
- Composer supports the same Pickle features as HUD composer: follow-up, slash/file autocomplete, drops, screen context chip, notify, terminal, send/stop, model/thinking cycling.
- Right `작업 정보` panel can be collapsed and remembers state.
- Right panel uses only existing session data and does not invent active app/browser/selected-text details.
- Changed files are labelled as session-level data.
- Closing fullscreen restores dock mode without cancelling or resetting Pickles.
- No permission selector, plan mode, goal suggestion, plugin menu, cloud/worktree/PR controls, or other Codex-only controls appear.

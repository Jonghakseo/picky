# Picky fullscreen workspace implementation plan

Status: implemented behind `PICKY_FULLSCREEN_ENABLED`; this document is now an index plus rollout checklist.

Detailed current behavior and phase notes live under `docs/picky-fullscreen-mode/`. Use the phase documents as historical implementation notes and update them when feature-gated behavior changes.

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
| [`phases/phase-06-work-info-panel.md`](picky-fullscreen-mode/phases/phase-06-work-info-panel.md) | Right `변경사항` panel with read-only changes/git/diff metadata |
| [`phases/phase-07-new-pickle-lifecycle-polish.md`](picky-fullscreen-mode/phases/phase-07-new-pickle-lifecycle-polish.md) | New Pickle affordance and lifecycle polish |
| [`phases/phase-08-polish-animation-accessibility.md`](picky-fullscreen-mode/phases/phase-08-polish-animation-accessibility.md) | Animation, accessibility, keyboard, performance polish |
| [`04-testing-risk-acceptance.md`](picky-fullscreen-mode/04-testing-risk-acceptance.md) | Unit/UI/manual QA, risks, acceptance criteria |

## Current rollout / review sequence

1. Run with `PICKY_FULLSCREEN_ENABLED=1` and validate against [`04-testing-risk-acceptance.md`](picky-fullscreen-mode/04-testing-risk-acceptance.md).
2. Keep [`00-product-ux.md`](picky-fullscreen-mode/00-product-ux.md), [`02-data-contracts.md`](picky-fullscreen-mode/02-data-contracts.md), and phase 06 aligned with the implemented `변경사항` panel.
3. Resolve the phase 07 product-decision gate before adding any mutating branch/worktree/PR/cloud controls.
4. Remove or keep the feature flag only after manual QA and release acceptance are updated.

## MVP acceptance criteria

- Dock has a clear fullscreen expand button that does not conflict with add Pickle.
- Clicking it hides dock mode and opens a fullscreen-capable workspace for the intended Pickle.
- Center is a clean LLM chat UI.
- Running turns show live progress.
- Completed turns show final assistant answer as the primary body, with system status rows separated and optional work summary collapsed by default.
- Composer supports the same Pickle features as HUD composer: follow-up, slash/file autocomplete, drops, screen context chip, notify, terminal, send/stop, model/thinking cycling.
- Right `변경사항` panel can be collapsed and remembers state.
- Right panel remains read-only and must not invent active app/browser/selected-text details.
- Changed files and git/diff metadata are labelled as change/worktree data, not per-turn claims.
- Closing fullscreen restores dock mode without cancelling or resetting Pickles.
- No permission selector, plan mode, goal suggestion, plugin menu, mutating cloud/worktree/PR controls, or other Codex-only controls appear. Read-only branch/worktree metadata remains a phase 07 product-decision gate.

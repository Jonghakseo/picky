# Picky fullscreen workspace

Status: design and implementation plan only. Do not implement until explicitly approved.

## Intent

Fullscreen mode gives an existing Pickle session a focused workspace: left Pickle list, center LLM chat, bottom composer, and right `작업 정보` panel.

It must stay Picky-shaped:

- local-first
- session-control oriented
- no SaaS backend
- no Codex-only permission/plan/plugin/cloud/worktree controls
- no fake data
- no app restart during development unless explicitly requested

## Hard UX rule

Fullscreen and dock mode are mutually exclusive.

```text
Dock mode
  ├─ HUD dock/panels visible
  ├─ fullscreen window closed
  └─ compact HUD composer may be mounted

Open fullscreen
  ├─ resolve target session
  ├─ hide HUD dock/panels
  ├─ unmount compact HUD composer
  └─ mount fullscreen workspace/composer

Fullscreen mode
  ├─ HUD dock/panels hidden
  ├─ fullscreen window visible
  └─ only fullscreen composer may be mounted

Close fullscreen
  ├─ unmount fullscreen workspace/composer
  ├─ persist fullscreen UI state
  └─ restore HUD dock/panels
```

This avoids duplicate composer instances for the same session and prevents draft/attachment races.

## Documents

1. [`00-product-ux.md`](00-product-ux.md) — UX and non-goals
2. [`01-swift-architecture.md`](01-swift-architecture.md) — architecture and module responsibilities
3. [`02-data-contracts.md`](02-data-contracts.md) — data inventory and rendering policy
4. [`03-interactions-state.md`](03-interactions-state.md) — mode transitions and state persistence
5. [`phases/`](phases/) — implementation phases
6. [`04-testing-risk-acceptance.md`](04-testing-risk-acceptance.md) — tests, risks, acceptance criteria

## Phase order

| Phase | Document | Outcome |
| --- | --- | --- |
| 1 | [`phase-01-shell-window-lifecycle.md`](phases/phase-01-shell-window-lifecycle.md) | Strong-owned fullscreen shell exists and is screen-capture excluded |
| 2 | [`phase-02-dock-entry-mode-transition.md`](phases/phase-02-dock-entry-mode-transition.md) | Dock expand button opens fullscreen and hides/restores dock mode |
| 3 | [`phase-03-sidebar-session-selection.md`](phases/phase-03-sidebar-session-selection.md) | Sidebar lists Pickles and controls fullscreen-local selection |
| 4 | [`phase-04-conversation-rendering.md`](phases/phase-04-conversation-rendering.md) | Center renders clean LLM chat with correct running/completed behavior |
| 5 | [`phase-05-composer-reuse.md`](phases/phase-05-composer-reuse.md) | Existing composer is reused without duplicate mounting |
| 6 | [`phase-06-work-info-panel.md`](phases/phase-06-work-info-panel.md) | Right panel shows existing session data only |
| 7 | [`phase-07-new-pickle-lifecycle-polish.md`](phases/phase-07-new-pickle-lifecycle-polish.md) | New Pickle and lifecycle polish are integrated |
| 8 | [`phase-08-polish-animation-accessibility.md`](phases/phase-08-polish-animation-accessibility.md) | Animation, accessibility, keyboard, performance polish |

## Review gates

- Product UX gate: `00-product-ux.md`
- Architecture gate: `01-swift-architecture.md`
- Data correctness gate: `02-data-contracts.md`
- State/lifecycle gate: `03-interactions-state.md`
- Implementation gate: phase document for the current phase
- Release gate: `04-testing-risk-acceptance.md`

# Utility panel: Terminal + Artifacts

Status: superseded (2026-08-30). This file records the two-tab implementation that shipped on 2026-08-17, but the current Pickle utility panel is terminal-only (`Picky/HUD/PickyHUDUtilityPanel.swift`). The Artifacts tab and persisted tab selection were later removed. `PickySessionArtifactsView` remains in source but is not mounted by the current utility panel; link/report artifacts remain available from conversation surfaces.

The sections below preserve the historical Terminal + Artifacts contract and must not be used as the current HUD specification.

## Historical product decisions

- Keep the utility panel focused on two concrete jobs: interacting with the local terminal and reopening files produced by the Pickle.
- Do not auto-switch tabs on completion; use the Artifacts badge only.
- The conversation artifact tray keeps rendering links/reports and never renders file artifacts.
- File artifacts have **write-only provenance**. A local path merely mentioned in an assistant answer is never registered.
- Activity timelines, progress summaries, turn grouping, inline diffs, and raw tool filters do not belong in the utility panel.

## File artifact contract

A file artifact is an allowed non-source file Pi saved successfully with its file-writing tool. Structured `write` events provide the normalized path; display previews are never parsed for provenance.

- Existing files overwritten by `write` are included.
- Source files, hidden paths, dependency/build output, and system temporary paths are excluded.
- macOS `/var/...` and `/private/var/...` temporary-directory aliases are both excluded.
- Rewriting the same path updates its existing artifact with a strictly monotonic `updatedAt`, so the unseen badge re-arms even when the clock repeats or moves backward.
- Link materialization behavior is unchanged.

## Historical utility UI state

- Persisted `activity`, `progress`, and `changes` selections fall back to `terminal`.
- The terminal remains mounted across tab changes, requests focus only while selected, and resigns hidden terminal focus when the Artifacts tab becomes active.
- Artifact seen state advances only to the latest rendered file timestamp while the corresponding `NSPanel` is actually visible. Empty tabs do not advance the watermark.
- Artifact rows preserve separate Open, Finder, and Copy Path actions for VoiceOver.

## Test coverage

- Swift tests cover the two-tab policy, stale selection fallback, terminal focus eligibility/resignation, actual panel visibility, delayed artifact delivery, file sorting/filtering, and tray isolation.
- agentd tests cover structured write provenance, deterministic ids, monotonic rewrites, clock rollback, and temporary-path exclusion.

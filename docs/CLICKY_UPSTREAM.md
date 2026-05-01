# Public Clicky Upstream Provenance

- Upstream repository: https://github.com/farzaa/clicky/
- Local source used: `/tmp/clicky-re/upstream`
- Commit SHA: `a80fa80721a8aebe51a170a7780705024ebc6e46`
- License: MIT (`LICENSE` copied from public upstream)
- Imported for: macOS shell foundation for Picky (menu bar app, global push-to-talk, screen capture, overlays, permission handling).

## Clean-room note

Public Clicky source is MIT licensed and may be copied into Picky with attribution. The locally installed private Clicky app is a product/UX reference only and must not be used as an implementation source.

## Import exclusions

- Upstream `.git/` metadata.
- Upstream agent-instruction files (`AGENTS.md`, `CLAUDE.md`) so this repository's Picky-specific `AGENTS.md` remains authoritative.
- Upstream hosted backend package, because Picky Phase 1 keeps only the macOS app shell and local agent boundary.

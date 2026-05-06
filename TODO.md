# Portability TODOs

The following items remain after removing the neutral fixture/company-domain leakage, unused camera entitlement, and local-path references from planning docs.

## High priority

- [ ] Package `picky-agentd` for non-development installs.
  - Release builds should not require a source checkout, `pnpm`, or `tsx`.
  - Bundle a built daemon (`dist/index.js` plus production dependencies) or a standalone executable in `Picky.app/Contents/Resources/agentd`.
  - Make `PickyAgentDaemonLauncher` choose a bundled release command outside development.
- [ ] Make Pi runtime discovery installation-agnostic.
  - Do not assume the Pi SDK lives under a single global npm prefix.
  - Prefer discovering `pi` from PATH and resolving `@mariozechner/pi-coding-agent` from the daemon dependency graph or user-configured location.
- [ ] Move app signing and bundle identifiers out of the Xcode project defaults.
  - Use `.xcconfig` or script overrides for `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM`.
  - Keep defaults contributor-friendly and team-neutral.
- [ ] Generalize external terminal handoff.
  - Picky now has an in-app Pi terminal overlay and can copy the `pi --session ...` resume command.
  - Add optional external launch targets for Terminal.app, iTerm2, Ghostty, and a custom command template.

## Medium priority

- [ ] Revisit speech locale ordering.
  - Prefer current system locale by default, with explicit settings/env override for Korean or other languages.
- [ ] Make launch-at-login explicit opt-in.
  - Ask during onboarding/settings before calling `SMAppService.register()`.
- [ ] Expand browser context capture support beyond the current partial coverage.
  - Current AppleScript support covers Safari, Chrome, and Arc.
  - Current Accessibility fallback covers Safari, Chrome, Arc, Brave, and Edge, with URL extraction for Chrome/Brave/Edge.
  - Add Vivaldi and Firefox support/fallbacks, and consider AX URL extraction for Safari/Arc.
  - Keep browser target definitions configurable or easy to extend.

## Low priority

- [ ] Avoid a fixed daemon port where possible.
  - Support free-port allocation or conflict recovery while preserving local-only binding and token auth.

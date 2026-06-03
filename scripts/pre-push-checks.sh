#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

HOST_ARCH="$(uname -m)"
DESTINATION="${PICKY_XCODE_DESTINATION:-platform=macOS,arch=${HOST_ARCH}}"

require_command() {
  local command_name="$1"
  local install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "❌ pre-push: '$command_name' is required. $install_hint" >&2
    exit 127
  fi
}

run_step() {
  local label="$1"
  shift
  echo
  echo "▶ $label"
  "$@"
}

require_command pnpm "Install pnpm 10.15.1 or run Corepack setup."
require_command swiftlint "Install it with: brew install swiftlint"
require_command xcodebuild "Install Xcode command line tools / Xcode."

run_step "agentd: typecheck" pnpm --dir agentd run typecheck
run_step "agentd: lint" pnpm --dir agentd run lint
run_step "agentd: tests (serial)" pnpm --dir agentd run test:serial
run_step "architecture guard" pnpm run check:architecture
run_step "SwiftLint warning-first rules" swiftlint lint --config .swiftlint.yml --quiet
run_step "Picky app build" xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" build

# `-parallel-testing-enabled NO` forces a single xctest runner process. When xcodebuild
# shards PickyTests across two runners (the default), both host processes initialize the
# shared Speech/Audio/agentd-launcher frameworks at the same time and one of them
# occasionally trips a malloc double-free inside those system frameworks, killing the
# runner and reporting every still-scheduled test in that shard as a failure (observed
# ~20% of consecutive runs). Serializing the runners avoids the cross-process collision
# and trades ~5-9s for deterministic results.
run_step "Picky test suite" xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" -parallel-testing-enabled NO test

echo
echo "✅ pre-push: all local quality checks passed."

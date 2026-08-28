#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

HOST_ARCH="$(uname -m)"
DESTINATION="${PICKY_XCODE_DESTINATION:-platform=macOS,arch=${HOST_ARCH}}"
PRE_PUSH_REFS="$(mktemp "${TMPDIR:-/tmp}/picky-pre-push-refs.XXXXXX")"
trap 'rm -f "$PRE_PUSH_REFS"' EXIT
if [ ! -t 0 ]; then
  cat > "$PRE_PUSH_REFS"
fi

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

# Lower-only ratchet for SwiftLint error-severity violations. The `.swiftlint.yml`
# error thresholds are themselves pinned just above the current worst offenders,
# so any violation here means a genuine regression. Never raise this baseline;
# see docs/refactoring-principles.md section 3.1 before changing a threshold.
SWIFTLINT_ERROR_VIOLATION_BASELINE=0

run_swiftlint_warning_first() {
  echo
  echo "▶ SwiftLint warning-first rules"
  local output
  local status
  local errors
  set +e
  output="$(swiftlint lint --config .swiftlint.yml --quiet 2>&1)"
  status=$?
  set -e
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
  # A here-string, not a pipe: with `set -o pipefail` an early-exiting `grep -q`
  # makes the producer fail with SIGPIPE, which silently skipped this check.
  errors="$(grep -Ec ':[0-9]+(:[0-9]+)?: error:' <<<"$output" || true)"
  if [ "$errors" -gt "$SWIFTLINT_ERROR_VIOLATION_BASELINE" ]; then
    echo "❌ pre-push: SwiftLint error-severity violations rose to ${errors}, above ratchet ${SWIFTLINT_ERROR_VIOLATION_BASELINE}. Fix the new violation; do not raise the ratchet." >&2
    return 1
  fi
  if [ "$errors" -gt 0 ]; then
    echo "SwiftLint reports ${errors} pre-existing error-severity violation(s) at ratchet ${SWIFTLINT_ERROR_VIOLATION_BASELINE}; shrink them when touching these files."
  fi
  if [ "$status" -ne 0 ]; then
    echo "SwiftLint returned $status with warnings only; continuing per warning-first policy."
  fi
}

require_command git "Install Git."
require_command node "Install Node.js 22.19.0."
require_command python3 "Install Python 3."

# Fail fast on architectural regressions, including the file-size ratchet, before
# invoking any slower dependency checks, builds, or test suites.
run_step "architecture guard" node scripts/check-architecture-rules.js
run_step "test environment isolation guard" python3 scripts/check-test-environment-isolation.py
run_step "UI design token guard" python3 scripts/lint-ui-design-tokens.py
run_step "UI design token baseline provenance" python3 scripts/lint-ui-design-tokens.py --verify-baseline
run_step "release helper tests" python3 -m unittest discover -s scripts/tests -p 'test_*.py'

require_command pnpm "Install pnpm 10.15.1 or run Corepack setup."
require_command swiftlint "Install it with: brew install swiftlint"
require_command xcodebuild "Install Xcode command line tools / Xcode."

if [ -s "$PRE_PUSH_REFS" ]; then
  while IFS= read -r local_sha; do
    run_step "agentd: outgoing commit lint ${local_sha:0:12}" "$ROOT/scripts/check-agentd-lint-snapshot.sh" --commit "$local_sha"
  done < <(awk '$2 !~ /^0+$/ { print $2 }' "$PRE_PUSH_REFS" | sort -u)
fi

run_step "agentd: typecheck" pnpm --dir agentd run typecheck
run_step "agentd: lint (zero warnings)" pnpm --dir agentd run lint
run_step "ESLint suppression guard" pnpm run check:eslint-suppressions
# Most files run in Vitest's parallel pool. The WebSocket-heavy server and
# session-supervisor suites have load-sensitive delivery deadlines, so test:ci
# runs those two files in a second, serial phase.
run_step "agentd: tests (parallel + isolated server)" pnpm --dir agentd run test:ci
run_swiftlint_warning_first
run_step "Picky app build" xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" build

# `-parallel-testing-enabled NO` forces a single xctest runner process. When xcodebuild
# shards PickyTests across two runners (the default), both host processes initialize the
# shared Speech/Audio/agentd-launcher frameworks at the same time and one of them
# occasionally trips a malloc double-free inside those system frameworks, killing the
# runner and reporting every still-scheduled test in that shard as a failure (observed
# ~20% of consecutive runs). Serializing the runners avoids the cross-process collision
# and trades ~5-9s for deterministic results.
# WindowServer-dependent tests are disabled in every ordinary test invocation.
# The pre-push gate is their single opt-in execution and deliberately runs the
# Swift suite once, without retries or test-plan repetitions.
run_step "Picky test suite" env TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS=1 xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" -parallel-testing-enabled NO test

echo
echo "✅ pre-push: all local quality checks passed."

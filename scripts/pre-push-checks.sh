#!/usr/bin/env bash
set -euo pipefail

# Helpers come from this checkout; tests come from the cwd checkout. Resolve
# the script path before changing directories, including relative invocations.
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
usage() {
  echo "Usage: $0 [--swift-tests|--ui-effects|--hub-focus-perf|--hub-focus-perf-calibrate]" >&2
}
if [ "$#" -gt 1 ]; then usage; exit 64; fi
TEST_MODE="${1:-local}"
HUB_FOCUS_PERF_ONLY=false
HUB_FOCUS_PERF_MODE=gate
case "$TEST_MODE" in
  local|--swift-tests) ;;
  --ui-effects) ;;
  --hub-focus-perf) HUB_FOCUS_PERF_ONLY=true ;;
  --hub-focus-perf-calibrate) HUB_FOCUS_PERF_ONLY=true; HUB_FOCUS_PERF_MODE=calibrate ;;
  *) usage; exit 64 ;;
esac

# CI=true (or a self-hosted runner on a developer laptop) is not isolation.
# Refuse before starting Xcode, reading stdin, or touching the desktop.
UI_EFFECTS=false
if [ "$TEST_MODE" = --ui-effects ] || [ "$HUB_FOCUS_PERF_ONLY" = true ]; then
  if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
    echo "❌ UI-effect tests require a GitHub-hosted macOS VM. Use the Isolated UI tests workflow; local tests never take focus." >&2
    exit 78
  fi
  UI_EFFECTS=true
fi

HOST_ARCH="$(uname -m)"
DESTINATION="${PICKY_XCODE_DESTINATION:-platform=macOS,arch=${HOST_ARCH}}"
# Reuse the agent cache instead of contending with a GUI Xcode build.
DERIVED_DATA_PATH="${PICKY_DERIVED_DATA_PATH:-/private/tmp/PickyAgentDD}"

# shellcheck source=scripts/lib/pinned-toolchain.sh
. "$SCRIPT_ROOT/scripts/lib/pinned-toolchain.sh"
picky_require_pinned_toolchain "pre-push"
PRE_PUSH_REFS="$(mktemp "${TMPDIR:-/tmp}/picky-pre-push-refs.XXXXXX")"
PICKY_TEST_LOG=""
cleanup() {
  rm -f "$PRE_PUSH_REFS"
}
trap cleanup EXIT
# Git supplies a finite refs stream. Narrow performance runs never read stdin,
# so invoking them manually cannot block on a terminal or open pipe.
if [ "$TEST_MODE" = local ] && [ ! -t 0 ]; then
  while IFS= read -r ref; do
    printf '%s\n' "$ref"
  done > "$PRE_PUSH_REFS"
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

HUB_FOCUS_PERF_REPORT="${PICKY_HUB_FOCUS_PERF_REPORT_PATH:-$ROOT/build/perf/hub-focus/pre-push.json}"
# Explicit zeros override leaked shell flags. A bare xcodebuild remains
# fail-closed in Swift too: opt-in AND an isolated session are both required.
UI_EFFECT_TEST_ENV=(
  "PICKY_PRE_PUSH_UI_EFFECT_TESTS=0"
  "PICKY_UI_TEST_SESSION="
  "TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS=0"
  "TEST_RUNNER_PICKY_UI_TEST_SESSION="
  "TEST_RUNNER_PICKY_HUB_FOCUS_PERF_PROFILE="
)
if [ "$UI_EFFECTS" = true ]; then
  UI_EFFECT_TEST_ENV=(
    "TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS=1"
    "TEST_RUNNER_PICKY_UI_TEST_SESSION=isolated"
    "TEST_RUNNER_PICKY_HUB_FOCUS_PERF_PROFILE=github-hosted"
    "TEST_RUNNER_PICKY_HUB_FOCUS_PERF_REPORT_PATH=$HUB_FOCUS_PERF_REPORT"
    "TEST_RUNNER_PICKY_HUB_FOCUS_PERF_MODE=$HUB_FOCUS_PERF_MODE"
  )
fi

run_picky_tests() {
  local selected_test="${1:-}"
  local selector=("-skip-testing:PickyTests/PickyHubFocusPerformanceTests")
  local label="Picky offscreen test suite (desktop activation prohibited)"
  mkdir -p "$(dirname "$HUB_FOCUS_PERF_REPORT")"
  PICKY_TEST_LOG="${HUB_FOCUS_PERF_REPORT%.json}.suite.log"
  if [ -n "$selected_test" ]; then
    selector=("-only-testing:PickyTests/$selected_test")
    label="Isolated UI contract: $selected_test"
    local log_name="${selected_test//\//-}"
    PICKY_TEST_LOG="${HUB_FOCUS_PERF_REPORT%.json}.${log_name}.log"
  fi
  if [ "$HUB_FOCUS_PERF_ONLY" = true ]; then
    selector=("-only-testing:PickyTests/PickyHubFocusPerformanceTests")
    label="Isolated Hub focus performance gate"
    PICKY_TEST_LOG="${HUB_FOCUS_PERF_REPORT%.json}.log"
    # A previous run must never satisfy the current invocation's artifact check.
    if [ -f "$HUB_FOCUS_PERF_REPORT" ]; then
      mv "$HUB_FOCUS_PERF_REPORT" "${HUB_FOCUS_PERF_REPORT%.json}.previous.json"
    fi
  fi
  echo
  echo "▶ $label"
  set +e
  env "${UI_EFFECT_TEST_ENV[@]}" xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA_PATH" -parallel-testing-enabled NO test "${selector[@]}" 2>&1 | tee "$PICKY_TEST_LOG"
  local xcode_status=${PIPESTATUS[0]}
  set -e
  if [ "$xcode_status" -ne 0 ]; then return "$xcode_status"; fi
  if [ -n "$selected_test" ]; then
    python3 "$SCRIPT_ROOT/scripts/validate-ui-effect-test-log.py" --selector "$selected_test" --log "$PICKY_TEST_LOG"
  fi
  if [ "$HUB_FOCUS_PERF_ONLY" = true ]; then
    python3 "$SCRIPT_ROOT/scripts/tests/test_hub_focus_perf_runner.py" \
      --report "$HUB_FOCUS_PERF_REPORT" \
      --xcode-log "$PICKY_TEST_LOG" \
      --profile github-hosted
  fi
}

# Lower-only ratchet for SwiftLint error-severity violations. The `.swiftlint.yml`
# error thresholds are themselves pinned just above the current worst offenders,
# so any violation here means a genuine regression. Never raise this baseline;
# see docs/refactoring-principles.md section 3.1 before changing a threshold.
SWIFTLINT_ERROR_VIOLATION_BASELINE=0

run_swiftlint_warning_first() {
  echo
  echo "▶ SwiftLint warning-first rules"
  local app_output
  local app_status
  local test_output
  local test_status
  local output
  local status
  local errors
  set +e
  app_output="$(swiftlint lint --config .swiftlint.yml --quiet 2>&1)"
  app_status=$?
  test_output="$(swiftlint lint --config .swiftlint-tests.yml --quiet 2>&1)"
  test_status=$?
  set -e
  output="$(printf '%s\n%s\n' "$app_output" "$test_output")"
  if [ "$app_status" -ne 0 ] || [ "$test_status" -ne 0 ]; then
    status=1
  else
    status=0
  fi
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
require_command python3 "Install Python 3."

if [ "$UI_EFFECTS" = true ]; then
  require_command xcodebuild "Install Xcode."
  if [ "$HUB_FOCUS_PERF_ONLY" = true ]; then
    run_picky_tests
  else
    # Read all selectors before running any test; discovery failure cannot be
    # masked by process substitution. Each contract gets a fresh test host.
    ui_selectors="$(python3 "$SCRIPT_ROOT/scripts/check-test-environment-isolation.py" --ui-effect-selectors --source-root "$ROOT")"
    while IFS= read -r selected_test; do
      if [[ "$selected_test" == PickyHubFocusPerformanceTests/* ]]; then
        HUB_FOCUS_PERF_ONLY=true run_picky_tests "$selected_test"
      else
        run_picky_tests "$selected_test"
      fi
    done <<< "$ui_selectors"
  fi
  echo "✅ isolated UI checks passed."
  exit 0
fi

if [ "$TEST_MODE" = --swift-tests ]; then
  require_command xcodebuild "Install Xcode."
  run_step "test environment isolation guard" python3 "$SCRIPT_ROOT/scripts/check-test-environment-isolation.py"
  run_picky_tests
  echo "✅ offscreen Swift checks passed; real UI checks belong to isolated CI."
  exit 0
fi

require_command node "Install Node.js 22.19.0."

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
run_step "Picky app build" xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA_PATH" build

# `-parallel-testing-enabled NO` forces a single xctest runner process. When xcodebuild
# shards PickyTests across two runners (the default), both host processes initialize the
# shared Speech/Audio/agentd-launcher frameworks at the same time and one of them
# occasionally trips a malloc double-free inside those system frameworks, killing the
# runner and reporting every still-scheduled test in that shard as a failure (observed
# ~20% of consecutive runs). Serializing the runners avoids the cross-process collision
# and trades ~5-9s for deterministic results.
# Real UI contracts run in isolated-ui-tests.yml, never on the user's desktop.
# Release packaging depends on that workflow's successful UI job.
run_picky_tests

echo
echo "✅ pre-push: local checks passed. Real UI/latency validation is required separately in isolated CI."

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

run_with_retry() {
  local attempts="$1"
  local label="$2"
  shift 2
  local attempt=1
  while true; do
    echo
    echo "▶ ${label} (attempt ${attempt}/${attempts})"
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      return 1
    fi
    attempt=$((attempt + 1))
    echo "↻ ${label} failed; retrying once for known async test flakiness."
  done
}

run_swiftlint_warning_first() {
  echo
  echo "▶ SwiftLint warning-first rules"
  local output
  local status
  set +e
  output="$(swiftlint lint --config .swiftlint.yml --quiet 2>&1)"
  status=$?
  set -e
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
  if printf '%s\n' "$output" | grep -Eq ':[0-9]+(:[0-9]+)?: error:'; then
    return "$status"
  fi
  if [ "$status" -ne 0 ]; then
    echo "SwiftLint returned $status with warnings only; continuing per warning-first policy."
  fi
}

require_command git "Install Git."
require_command node "Install Node.js 22.19.0."

# Fail fast on architectural regressions, including the file-size ratchet, before
# invoking any slower dependency checks, builds, or test suites.
run_step "architecture guard" node scripts/check-architecture-rules.js

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
run_with_retry 5 "agentd: tests (serial)" pnpm --dir agentd run test:serial
run_swiftlint_warning_first
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

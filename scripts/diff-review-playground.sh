#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/tools/diff-review-playground"
EXECUTABLE="$PACKAGE_DIR/.build/debug/diff-review-playground"
LOG_PATH="/tmp/picky-diff-review-playground.log"
MODE="${1:-repo}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/diff-review-playground.sh fixture
  scripts/diff-review-playground.sh repo [cwd]
  scripts/diff-review-playground.sh diff <path-to-unified.diff>

Examples:
  scripts/diff-review-playground.sh fixture
  scripts/diff-review-playground.sh repo ~/Documents/picky
  git diff HEAD -- > /tmp/picky.diff && scripts/diff-review-playground.sh diff /tmp/picky.diff
USAGE
}

launch_direct() {
  swift build --package-path "$PACKAGE_DIR" >/tmp/picky-diff-review-playground-build.log 2>&1
  "$EXECUTABLE" "$@" >"$LOG_PATH" 2>&1 &
  local pid=$!
  echo "Started Picky Diff Review Playground (PID $pid). Log: $LOG_PATH"
}

case "$MODE" in
  fixture)
    launch_direct --fixture
    ;;
  repo)
    CWD="${2:-$ROOT_DIR}"
    launch_direct --cwd "$CWD"
    ;;
  diff)
    if [[ $# -lt 2 ]]; then
      usage >&2
      exit 2
    fi
    launch_direct --diff "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

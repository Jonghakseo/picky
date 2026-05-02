#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/derived/Build/Products/Debug/Picky.app"
LOG="${PICKY_TERMINAL_DEBUG_LOG:-/tmp/picky-terminal-debug.log}"

SESSION_FILE="${1:-${PICKY_TERMINAL_DEBUG_SESSION:-}}"
if [[ -z "$SESSION_FILE" ]]; then
  cat >&2 <<'USAGE'
Usage:
  scripts/run-terminal-debug.sh <pi-session-jsonl>

Optional env:
  PICKY_TERMINAL_DEBUG_CWD=/path/to/cwd
  PICKY_TERMINAL_DEBUG_TITLE="title"
  PICKY_TERMINAL_DEBUG_LOG=/tmp/picky-terminal-debug.log
  PICKY_TERMINAL_DEBUG_IME_LOG=1
USAGE
  echo >&2
  echo "Recent Pi sessions:" >&2
  find "$HOME/.pi/agent/sessions" -name '*.jsonl' -mtime -2 -print0 \
    | xargs -0 ls -lt 2>/dev/null \
    | head -12 >&2 || true
  exit 2
fi

SESSION_FILE="$(python3 - <<'PY' "$SESSION_FILE"
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
)"
if [[ ! -f "$SESSION_FILE" ]]; then
  echo "Missing Pi session file: $SESSION_FILE" >&2
  exit 1
fi

CWD_VALUE="${PICKY_TERMINAL_DEBUG_CWD:-$PWD}"
TITLE_VALUE="${PICKY_TERMINAL_DEBUG_TITLE:-Pi terminal debug}"

printf 'Building Picky Debug app...\n'
xcodebuild \
  -project "$ROOT/Picky.xcodeproj" \
  -scheme Picky \
  -configuration Debug \
  -derivedDataPath "$ROOT/build/derived" \
  build >/tmp/picky-terminal-debug-build.log

if pgrep -x Picky >/dev/null; then
  osascript -e 'tell application "Picky" to quit' >/dev/null 2>&1 || pkill -x Picky || true
fi
for _ in {1..20}; do
  pgrep -x Picky >/dev/null || break
  sleep 0.2
done
if pgrep -x Picky >/dev/null; then
  pkill -x Picky || true
  sleep 0.5
fi

printf 'Launching terminal-only Picky debug mode...\n'
printf '  session: %s\n' "$SESSION_FILE"
printf '  cwd:     %s\n' "$CWD_VALUE"
printf '  title:   %s\n' "$TITLE_VALUE"
printf '  log:     %s\n' "$LOG"

PICKY_TERMINAL_DEBUG_SESSION="$SESSION_FILE" \
PICKY_TERMINAL_DEBUG_CWD="$CWD_VALUE" \
PICKY_TERMINAL_DEBUG_TITLE="$TITLE_VALUE" \
nohup "$APP/Contents/MacOS/Picky" >"$LOG" 2>&1 &
PID=$!
echo "$PID" >/tmp/picky-terminal-debug.pid
printf '  pid:     %s\n' "$PID"

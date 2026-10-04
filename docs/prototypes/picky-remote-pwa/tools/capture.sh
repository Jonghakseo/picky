# shellcheck shell=bash
# Shared headless Chrome capture for shoot.sh and shoot-board.sh. Source this file.
#
# picky_capture <url> <out.png> <width> <height> [extra Chrome flags...]
#
# Every capture uses a throwaway profile, so the user's browser session is never touched.
# Headless Chrome on macOS writes the PNG promptly but may keep running afterwards
# (updater wake-ups), so this waits for the "written to file" log line and then stops
# only the processes that use that throwaway profile.

PICKY_CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

picky_capture() {
  local url="$1" out="$2" width="$3" height="$4"
  shift 4
  local profile log pid
  [ -x "$PICKY_CHROME" ] || { echo "Google Chrome not found at $PICKY_CHROME" >&2; return 1; }
  profile="$(mktemp -d "${TMPDIR:-/tmp}/picky-pwa-shot.XXXXXX")"
  log="$profile.log"
  rm -f "$out"
  "$PICKY_CHROME" --headless=new --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$profile" --window-size="$width,$height" "$@" \
    --screenshot="$out" "$url" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 120); do
    if grep -q "written to file" "$log" 2>/dev/null; then break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  kill "$pid" 2>/dev/null || true
  pkill -f -- "--user-data-dir=$profile" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$profile" "$log"
  [ -s "$out" ] || { echo "screenshot failed: $out" >&2; return 1; }
  echo "$out"
}

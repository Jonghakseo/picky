#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TARGET="${1:-}"
HOST_ARCH="$(uname -m)"
DESTINATION="${PICKY_XCODE_DESTINATION:-platform=macOS,arch=${HOST_ARCH}}"

if [ "$TARGET" = "conversation-context" ]; then
  OUTPUT="$ROOT/build/render-gallery/conversation-context"
  REQUEST_FILE="$ROOT/build/render-gallery/.conversation-context-output-path"
  EXPECTED=(
    context-control-ready-dark-ko.png
    context-popover-ready-dark-ko.png
    context-popover-ready-light-ko.png
    context-popover-unavailable-dark-ko.png
    context-popover-compacting-dark-ko.png
  )

  rm -rf "$OUTPUT"
  mkdir -p "$OUTPUT"
  printf '%s\n' "$OUTPUT" > "$REQUEST_FILE"
  trap 'rm -f "$REQUEST_FILE"' EXIT

  echo "Rendering conversation-context gallery offscreen to $OUTPUT"
  xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" \
    test -only-testing:PickyTests/PickyConversationHeaderRenderGalleryTests

  python3 - "$OUTPUT" "${EXPECTED[@]}" <<'PY'
import json
import struct
import sys
from pathlib import Path

output = Path(sys.argv[1])
expected = sys.argv[2:]
manifest_path = output / "manifest.json"
if not manifest_path.is_file() or manifest_path.stat().st_size == 0:
    raise SystemExit("render gallery is missing a non-empty manifest.json")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
entries = {scene["file"]: scene for scene in manifest.get("scenes", [])}
if set(entries) != set(expected):
    raise SystemExit(f"manifest scenes differ from expected matrix: {sorted(entries)}")

signature = b"\x89PNG\r\n\x1a\n"
for name in expected:
    path = output / name
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"missing or empty render: {path}")
    data = path.read_bytes()
    if data[:8] != signature or data[12:16] != b"IHDR":
        raise SystemExit(f"invalid PNG: {path}")
    width, height = struct.unpack(">II", data[16:24])
    scene = entries[name]
    if width != scene["pixelWidth"] or height != scene["pixelHeight"]:
        raise SystemExit(f"manifest dimension mismatch for {name}: PNG={width}x{height}")

print(f"Validated {len(expected)} conversation-context PNG renders.")
PY

  printf 'Render gallery artifacts:\n  %s\n  %s\n' "$OUTPUT" "$OUTPUT/manifest.json"
  exit 0
fi

if [ "$TARGET" != "dock-group" ]; then
  echo "Usage: $0 {dock-group|conversation-context}" >&2
  exit 64
fi

OUTPUT="$ROOT/build/render-gallery/dock-group"
REQUEST_FILE="$ROOT/build/render-gallery/.dock-group-output-path"
EXPECTED=(
  folder-small-dark-100.png
  folder-medium-dark-100.png
  folder-large-light-100.png
  folder-selected-medium-dark-100.png
  folder-selected-large-light-100.png
  folder-targeted-medium-dark-100.png
  folder-small-dark-130-cjk.png
  folder-empty-small-dark-100.png
  folder-empty-targeted-large-light-100.png
  list-five-selected-small-dark-100.png
  list-five-selected-medium-dark-100.png
  list-five-selected-large-light-100.png
  list-five-selected-small-dark-130.png
  list-four-idle-medium-dark-100.png
  list-five-highlighted-small-dark-130.png
  list-two-selected-medium-dark-100.png
  list-one-selected-medium-dark-100.png
  combined-folder-panel-medium-dark-100.png
  external-drag-feedback-medium-dark-100.png
  external-drag-top-level-large-light-130.png
)

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
printf '%s\n' "$OUTPUT" > "$REQUEST_FILE"
trap 'rm -f "$REQUEST_FILE"' EXIT

echo "Rendering dock-group gallery offscreen to $OUTPUT"
xcodebuild -project Picky.xcodeproj -scheme Picky -destination "$DESTINATION" \
  test -only-testing:PickyTests/PickyHUDDockGroupRenderGalleryTests

python3 - "$OUTPUT" "${EXPECTED[@]}" <<'PY'
import json
import struct
import sys
from pathlib import Path

output = Path(sys.argv[1])
expected = sys.argv[2:]
manifest_path = output / "manifest.json"
index_path = output / "index.html"
if not manifest_path.is_file() or manifest_path.stat().st_size == 0:
    raise SystemExit("render gallery is missing a non-empty manifest.json")
if not index_path.is_file() or index_path.stat().st_size == 0:
    raise SystemExit("render gallery is missing a non-empty index.html")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
entries = {scene["file"]: scene for scene in manifest.get("scenes", [])}
if set(entries) != set(expected):
    raise SystemExit(f"manifest scenes differ from expected matrix: {sorted(entries)}")

signature = b"\x89PNG\r\n\x1a\n"
for name in expected:
    path = output / name
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"missing or empty render: {path}")
    data = path.read_bytes()
    if data[:8] != signature or data[12:16] != b"IHDR":
        raise SystemExit(f"invalid PNG: {path}")
    width, height = struct.unpack(">II", data[16:24])
    scene = entries[name]
    if width != scene["pixelWidth"] or height != scene["pixelHeight"]:
        raise SystemExit(
            f"manifest dimension mismatch for {name}: "
            f"PNG={width}x{height}, manifest={scene['pixelWidth']}x{scene['pixelHeight']}"
        )
    if width <= 0 or height <= 0:
        raise SystemExit(f"non-positive PNG dimensions: {path}")

print(f"Validated {len(expected)} PNG renders and manifest dimensions.")
PY

printf 'Render gallery artifacts:\n  %s\n  %s\n  %s\n' \
  "$OUTPUT" "$OUTPUT/index.html" "$OUTPUT/manifest.json"

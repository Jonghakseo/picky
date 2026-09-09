#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <exported-statistics.json> <output-directory> [exported-pi-packages.json]" >&2
  exit 2
fi
if pgrep -x xcodebuild >/dev/null; then
  echo "Another xcodebuild is running. Run again after it finishes." >&2
  exit 1
fi
REQUEST="$ROOT/build/render-gallery/.hub-audit-request.json"
mkdir -p "$(dirname "$REQUEST")"
# Exclusive creation avoids borrowing another audit's input or cleanup ownership.
python3 - "$1" "$2" "$REQUEST" "${3:-}" <<'PY'
import json, pathlib, sys
snapshot = pathlib.Path(sys.argv[1]).resolve(strict=True)
output = pathlib.Path(sys.argv[2]).resolve()
if output.exists() and any(output.iterdir()):
    raise SystemExit('Choose an empty output directory; old images must not count as new evidence.')
packages = str(pathlib.Path(sys.argv[4]).resolve(strict=True)) if sys.argv[4] else None
with open(sys.argv[3], 'x') as f:
    json.dump({'snapshot': str(snapshot), 'output': str(output), 'packages': packages}, f)
PY
trap 'rm -f "$REQUEST"' EXIT
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Picky.xcodeproj -scheme Picky \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath /private/tmp/PickyAgentDD -parallel-testing-enabled NO \
  test -only-testing:PickyTests/PickyHubRenderGalleryTests \
  -only-testing:PickyTests/PickyHubLayoutPolicyTests
python3 - "$2" <<'PY'
import json, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
assert len(manifest['scenes']) == 9
for scene in manifest['scenes']:
    data = (root / scene['file']).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', data[16:24]) == (scene['pixelWidth'], scene['pixelHeight'])
print(f'Validated {len(manifest["scenes"])} production full-page renders in {root}')
PY

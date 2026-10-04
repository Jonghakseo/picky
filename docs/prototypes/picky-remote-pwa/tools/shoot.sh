#!/usr/bin/env bash
# Screenshot one prototype part at iPhone width (390pt, 2x) in light and dark.
#
# Usage: tools/shoot.sh <part> [height] [scale]
#   tools/shoot.sh chat-bubbles          -> build/render-gallery/remote-pwa-prototype/chat-bubbles-{light,dark}.png
#   tools/shoot.sh composer 1200 1.3     -> 1200pt tall, app font scale 1.3
set -euo pipefail

PROTO="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$PROTO/../../.." && pwd)"
OUT="$REPO/build/render-gallery/remote-pwa-prototype"
# shellcheck source=capture.sh
. "$PROTO/tools/capture.sh"

part="${1:?usage: tools/shoot.sh <part> [height] [scale]}"
height="${2:-1600}"
scale="${3:-}"
page="$PROTO/$part.html"
[ -f "$page" ] || { echo "no such part: $page" >&2; exit 1; }
mkdir -p "$OUT"

suffix=""
query_scale=""
if [ -n "$scale" ]; then
  suffix="-scale$scale"
  query_scale="&scale=$scale"
fi

for theme in light dark; do
  picky_capture "file://$page?theme=$theme$query_scale" "$OUT/$part-$theme$suffix.png" 390 "$height" \
    --force-device-scale-factor=2
done

#!/usr/bin/env bash
# Screenshot one review-board section: the prototype next to its HUD reference images.
#
# Usage: tools/shoot-board.sh <part> [height] [width]
#   tools/shoot-board.sh chat-bubbles      -> build/render-gallery/remote-pwa-prototype/board-chat-bubbles-{light,dark}.png
set -euo pipefail

PROTO="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$PROTO/../../.." && pwd)"
OUT="$REPO/build/render-gallery/remote-pwa-prototype"
# shellcheck source=capture.sh
. "$PROTO/tools/capture.sh"

part="${1:?usage: tools/shoot-board.sh <part> [height] [width]}"
height="${2:-1800}"
width="${3:-1600}"
mkdir -p "$OUT"

for theme in light dark; do
  # The virtual time budget lets the iframe load and report its height before capture.
  picky_capture "file://$PROTO/index.html?theme=$theme&part=$part" "$OUT/board-$part-$theme.png" "$width" "$height" \
    --force-device-scale-factor=1 --virtual-time-budget=5000
done

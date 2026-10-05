#!/bin/bash
# Regenerates web/public/icons/ from the Mac app icon so the Home Screen icon is
# the app icon, not a second drawing that can drift from it.
#
#   agentd/web/tools/make-icons.sh
#
# Plain sizes come from `sips`. The maskable icon needs the glyph composited on
# an opaque square (Android masks cut the rounded corners away), which `sips`
# cannot do, so headless Chrome renders that one. The PNGs are committed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
web="$(dirname "$here")"
repo="$(cd "$web/../.." && pwd)"
source_icon="$repo/Picky/Assets.xcassets/AppIcon.appiconset/1024-mac.png"
out="$web/public/icons"
# --ds-color-surface1 (light) from web/src/styles/tokens.css: the icon's own backdrop.
maskable_background="#ffffff"

mkdir -p "$out"
for size in 192 512; do
  sips -s format png -z "$size" "$size" "$source_icon" --out "$out/icon-$size.png" >/dev/null
done
sips -s format png -z 180 180 "$source_icon" --out "$out/apple-touch-icon.png" >/dev/null
sips -s format png -z 72 72 "$source_icon" --out "$out/badge-72.png" >/dev/null

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$chrome" ]]; then
  echo "maskable icon skipped: Google Chrome not found" >&2
  exit 0
fi

work="$(mktemp -d /private/tmp/picky-icons.XXXXXX)"
trap 'rm -rf "$work"' EXIT
cp "$source_icon" "$work/icon.png"
cat > "$work/maskable.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;width:512px;height:512px;background:$maskable_background}
  /* Android's mask keeps a circle of about 80% of the canvas; the glyph stays inside it. */
  img{position:absolute;inset:11%;width:78%;height:78%}
</style>
<img src="icon.png">
HTML
# headless Chrome on macOS often does not exit after writing the screenshot, so
# it runs in the background and only its own temp profile is killed afterwards.
"$chrome" --headless=new --disable-gpu --hide-scrollbars \
  --screenshot="$out/icon-512-maskable.png" --window-size=512,512 \
  --user-data-dir="$work/profile" "file://$work/maskable.html" >/dev/null 2>&1 &
for _ in $(seq 1 40); do
  [[ -s "$out/icon-512-maskable.png" ]] && break
  sleep 0.5
done
pkill -f "$work/profile" 2>/dev/null || true
wait 2>/dev/null || true

ls -la "$out"

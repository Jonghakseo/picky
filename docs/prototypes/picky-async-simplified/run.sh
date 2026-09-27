#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build/design-prototypes/async-simplified"
APP="$OUT/Picky Async UI Study.app"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.picky.async-ui-study</string>
<key>CFBundleName</key><string>Picky Async UI Study</string>
<key>CFBundleExecutable</key><string>AsyncWorkStudy</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -framework SwiftUI -framework AppKit \
  "$ROOT/docs/prototypes/picky-async-simplified/AsyncWorkStudy.swift" \
  -o "$APP/Contents/MacOS/AsyncWorkStudy"
if [[ "${1:-}" == "--render" ]]; then
  "$APP/Contents/MacOS/AsyncWorkStudy" --render "$OUT/renders"
else
  open "$APP"
fi

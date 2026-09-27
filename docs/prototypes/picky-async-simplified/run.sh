#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD=/private/tmp/PickyAgentDD
OUT="$ROOT/build/design-prototypes/async-simplified/production"
PRODUCTS="$DD/Build/Products/Debug"
APP="$OUT/Picky Async UI Study.app"
mkdir -p "$OUT"
# --reuse-build is for the same source revision after a successful agent-owned build.
if [[ "${1:-}" == "--reuse-build" ]]; then
  shift
else
  if pgrep -x xcodebuild >/dev/null; then
    echo 'An Xcode build is already running. Wait for its result before running this study.' >&2
    exit 75
  fi
  xcodebuild -project Picky.xcodeproj -scheme Picky -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DD" build > "$OUT/production-build.log" 2>&1
fi
python3 docs/prototypes/picky-async-simplified/prepare.py "$PRODUCTS"
xcrun swiftc -parse-as-library -swift-version 5 -enable-testing \
  -I "$PRODUCTS" -F "$PRODUCTS" -F "$PRODUCTS/Picky.app/Contents/Frameworks" \
  -framework SwiftUI -framework AppKit \
  "$PRODUCTS/Picky.app/Contents/MacOS/Picky.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/Picky.app/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/Picky.app/Contents/Frameworks" \
  "$ROOT/docs/prototypes/picky-async-simplified/AsyncWorkStudy.swift" \
  "$OUT/ProductionConversationCard.swift" "$OUT/PickyRunningTaskFooterView.swift" \
  "$ROOT/PickyTests/PickyRenderGalleryRasterizer.swift" \
  -o "$APP/Contents/MacOS/AsyncWorkStudy"
git apply --check "$OUT/apply-to-production.patch"
case "${1:-}" in
  --render) "$APP/Contents/MacOS/AsyncWorkStudy" --render "$OUT/renders" ;;
  --verify) "$APP/Contents/MacOS/AsyncWorkStudy" --verify ;;
  --build-only) ;;
  *) open "$APP" ;;
esac

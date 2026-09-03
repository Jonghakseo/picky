#!/usr/bin/env bash
# Resolve a toolchain this project can actually build with and export it as
# DEVELOPER_DIR, so nested xcodebuild/swift invocations inherit it instead of
# following whatever `xcode-select` happens to point at.
#
# Swift 6.2 makes deinit of a MainActor-isolated class implicitly isolated, and
# SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor applies that to nearly every class
# here. Xcode 26.3 miscompiles it: Release crashes swift-frontend, and a Debug
# app dies with SIGBUS seconds after launch.
# See docs/known-issues/xcode-26-3-isolated-deinit.md.
#
# Source this file, then call `picky_require_pinned_toolchain`.

picky_require_pinned_toolchain() {
  local label="${1:-toolchain}"
  local developer_dir="${PICKY_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  local swift_binary="${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

  if [ ! -x "$swift_binary" ]; then
    echo "❌ ${label}: no Xcode toolchain at ${developer_dir}." >&2
    echo "   Set PICKY_DEVELOPER_DIR to an Xcode 16.x Contents/Developer path." >&2
    return 127
  fi

  local swift_version
  swift_version="$("$swift_binary" -version 2>/dev/null |
    sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"

  if [ -n "$swift_version" ] &&
     [ "$(printf '%s\n6.2\n' "$swift_version" | sort -V | head -1)" = "6.2" ]; then
    echo "❌ ${label}: ${developer_dir} ships Swift ${swift_version}." >&2
    echo "   Swift 6.2+ miscompiles this project's implicit isolated deinit." >&2
    echo "   See docs/known-issues/xcode-26-3-isolated-deinit.md." >&2
    return 1
  fi

  export DEVELOPER_DIR="$developer_dir"
  echo "▶ Toolchain: Swift ${swift_version} (${developer_dir})"
}

#!/usr/bin/env bash
#
# Build a styled, distributable Picky DMG.
#
# Produces an UDZO-compressed read-only DMG with:
#   - Picky-branded background image (scripts/dmg/background.png)
#   - Custom window size, icon positions, and view options
#   - Sidebar/toolbar/status bar hidden
#   - "Applications" symlink so users can drag the app in
#
# The output is NOT signed, notarized, or stapled — the caller does that on
# the resulting .dmg path. This script only handles the layout.
#
# Usage:
#   scripts/dmg/create-styled-dmg.sh \
#     --app    path/to/Picky.app \
#     --output path/to/Picky-1.2.3.dmg \
#     [--volname "Picky"] \
#     [--background scripts/dmg/background.png]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP=""
OUTPUT=""
VOLNAME="Picky"
# Prefer the multi-rep TIFF: Finder will pick the @2x rep on Retina
# displays. Falls back to PNG if a caller overrides with --background.
BACKGROUND="${SCRIPT_DIR}/background.tiff"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --volname)
      VOLNAME="$2"
      shift 2
      ;;
    --background)
      BACKGROUND="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 64
      ;;
  esac
done

if [[ -z "${APP}" || -z "${OUTPUT}" ]]; then
  echo "Usage: $0 --app <Picky.app> --output <output.dmg> [--volname NAME] [--background PNG]" >&2
  exit 64
fi

if [[ ! -d "${APP}" ]]; then
  echo "App bundle not found: ${APP}" >&2
  exit 1
fi
if [[ ! -f "${BACKGROUND}" ]]; then
  echo "Background image not found: ${BACKGROUND}" >&2
  echo "Run: swift ${SCRIPT_DIR}/generate-background.swift" >&2
  exit 1
fi

BG_BASENAME="$(basename "${BACKGROUND}")"

APP_NAME="$(basename "${APP}" .app)"
OUTPUT_DIR="$(dirname "${OUTPUT}")"
mkdir -p "${OUTPUT_DIR}"

# Use mktemp so concurrent CI jobs don't trip on each other.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/picky-dmg.XXXXXX")"
STAGING="${WORK}/staging"
RW_DMG="${WORK}/picky-rw.dmg"

cleanup() {
  if [[ -n "${MOUNT_DEV:-}" ]]; then
    /usr/bin/hdiutil detach "${MOUNT_DEV}" -force >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

wait_for_finder_metadata() {
  local ds_store="${MOUNT_PATH}/.DS_Store"
  local last_state=""
  local stable_polls=0

  for ((attempt = 1; attempt <= 50; attempt += 1)); do
    sync
    if [[ -s "${ds_store}" ]]; then
      local current_state
      if ! current_state="$(/usr/bin/stat -f '%z:%m' "${ds_store}"):$({ /usr/bin/shasum -a 256 "${ds_store}" || true; } | awk '{print $1}')" || [[ "${current_state}" == *: ]]; then
        last_state=""
        stable_polls=0
        sleep 0.2
        continue
      fi
      if [[ "${current_state}" == "${last_state}" ]]; then
        stable_polls=$((stable_polls + 1))
      else
        last_state="${current_state}"
        stable_polls=1
      fi

      if [[ ${stable_polls} -ge 3 ]]; then
        return 0
      fi
    else
      last_state=""
      stable_polls=0
    fi
    sleep 0.2
  done

  echo "Finder did not flush stable ${ds_store}; refusing to create an unstyled DMG." >&2
  return 1
}

mkdir -p "${STAGING}"

echo "Staging app bundle..."
/usr/bin/ditto "${APP}" "${STAGING}/${APP_NAME}.app"
ln -s /Applications "${STAGING}/Applications"

echo "Installing background image..."
mkdir -p "${STAGING}/.background"
cp "${BACKGROUND}" "${STAGING}/.background/${BG_BASENAME}"

# Estimate DMG size (app size + 50MB headroom) so the RW image isn't oversized.
APP_KB="$(/usr/bin/du -sk "${STAGING}" | awk '{print $1}')"
SIZE_MB=$(( (APP_KB / 1024) + 80 ))

echo "Creating writable DMG (${SIZE_MB} MB)..."
/usr/bin/hdiutil create \
  -srcfolder "${STAGING}" \
  -volname "${VOLNAME}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "${RW_DMG}" >/dev/null

echo "Mounting for styling..."
# Let macOS auto-mount under /Volumes/<volname> so Finder can address the disk
# by name in AppleScript.
MOUNT_OUTPUT="$(/usr/bin/hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}")"
MOUNT_DEV="$(echo "${MOUNT_OUTPUT}" | awk '/Apple_HFS|Apple_APFS/ {print $1; exit}')"
MOUNT_PATH="/Volumes/${VOLNAME}"
if [[ ! -d "${MOUNT_PATH}" ]]; then
  echo "Expected mount point not found: ${MOUNT_PATH}" >&2
  echo "${MOUNT_OUTPUT}" >&2
  exit 1
fi

# Give Finder a moment to register the volume before AppleScripting it.
sleep 2

echo "Applying Finder layout..."
/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        -- bounds is {left, top, right, bottom}; content area is 660x400,
        -- macOS adds ~28pt for the title bar.
        set the bounds of container window to {200, 140, 860, 568}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set background picture of viewOptions to file (".background:" & "${BG_BASENAME}")

        -- Match scripts/dmg/generate-background.swift layout.
        set position of item "${APP_NAME}.app" of container window to {175, 220}
        set position of item "Applications" of container window to {485, 220}

        update without registering applications
        close
    end tell
end tell
APPLESCRIPT

# Make sure Finder has flushed .DS_Store to the volume before we unmount.
echo "Waiting for Finder metadata..."
wait_for_finder_metadata

echo "Detaching..."
/usr/bin/hdiutil detach "${MOUNT_DEV}" -force >/dev/null
MOUNT_DEV=""

echo "Converting to compressed UDZO..."
rm -f "${OUTPUT}"
/usr/bin/hdiutil convert "${RW_DMG}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "${OUTPUT}" >/dev/null

echo "Wrote ${OUTPUT}"

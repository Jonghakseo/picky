#!/usr/bin/env bash
set -euo pipefail

# Build a signed local Picky.app package without changing project defaults.
#
# The final app embeds picky-agentd under Contents/Resources/agentd and re-signs
# the mutated bundle, so beta testers do not need pnpm/tsx or the source tree at
# launch time. Node itself is intentionally expected to come from the user's Pi
# installation.
#
# Defaults to ad-hoc "Sign to Run Locally" signing so contributors can verify
# bundle sealing and app launch without an Apple Developer certificate. For a
# Developer ID build, pass:
#
#   PICKY_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
#   PICKY_DEVELOPMENT_TEAM="TEAMID" \
#   ./scripts/package-signed-app.sh
#
# This script intentionally does not notarize or publish. It is the safe local
# package/signing smoke used before a future full release pipeline.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PICKY_PROJECT_PATH:-${ROOT_DIR}/Picky.xcodeproj}"
SCHEME="${PICKY_SCHEME:-Picky}"
CONFIGURATION="${PICKY_CONFIGURATION:-Release}"
APP_NAME="${PICKY_APP_NAME:-Picky}"
BUILD_ROOT="${PICKY_PACKAGE_BUILD_DIR:-${ROOT_DIR}/build/package}"
DERIVED_DATA_PATH="${PICKY_DERIVED_DATA_PATH:-${BUILD_ROOT}/DerivedData}"
EXPORT_DIR="${PICKY_EXPORT_DIR:-${BUILD_ROOT}/export}"
CODE_SIGN_IDENTITY="${PICKY_CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${PICKY_DEVELOPMENT_TEAM:-}"
DESTINATION="${PICKY_DESTINATION:-platform=macOS}"
CREATE_ZIP="${PICKY_CREATE_ZIP:-1}"
PACKAGE_AGENTD="${PICKY_PACKAGE_AGENTD:-1}"
AGENTD_RUNTIME_DIR="${PICKY_AGENTD_RUNTIME_DIR:-${BUILD_ROOT}/agentd-runtime}"

read_project_setting() {
  local key="$1"
  /usr/bin/awk -v key="${key}" '
    $1 == key && $2 == "=" {
      value = $3
      gsub(/;/, "", value)
      print value
      exit
    }
  ' "${PROJECT_PATH}/project.pbxproj"
}

sanitize_version_part() {
  printf '%s' "$1" | /usr/bin/sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

MARKETING_VERSION="${PICKY_MARKETING_VERSION:-$(read_project_setting MARKETING_VERSION)}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0}"
BUILD_NUMBER="${PICKY_BUILD_NUMBER:-$(git -C "${ROOT_DIR}" rev-list --count HEAD 2>/dev/null || true)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
RELEASE_CHANNEL="${PICKY_RELEASE_CHANNEL:-alpha}"
GIT_SHA="${PICKY_GIT_SHA:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || true)}"
GIT_SHA="${GIT_SHA:-nogit}"
BUILD_TIMESTAMP="${PICKY_BUILD_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
BUILD_LABEL="${PICKY_BUILD_LABEL:-${RELEASE_CHANNEL}.${BUILD_NUMBER}-${GIT_SHA}-${BUILD_TIMESTAMP}}"
SAFE_BUILD_LABEL="$(sanitize_version_part "${BUILD_LABEL}")"
ENTITLEMENTS_PLIST="${BUILD_ROOT}/${APP_NAME}-${CONFIGURATION}.entitlements.plist"

APP_PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
BUILT_APP="${APP_PRODUCTS_DIR}/${APP_NAME}.app"
PACKAGED_APP="${EXPORT_DIR}/${APP_NAME}.app"
ZIP_PATH="${PICKY_ZIP_PATH:-${BUILD_ROOT}/${APP_NAME}-${MARKETING_VERSION}-${SAFE_BUILD_LABEL}.zip}"
BUILD_INFO_PATH="${PACKAGED_APP}/Contents/Resources/PickyBuildInfo.json"

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "❌ Xcode project not found: ${PROJECT_PATH}" >&2
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/agentd/package.json" ]]; then
  echo "❌ agentd/package.json not found. Run this script from the Picky repository." >&2
  exit 1
fi

mkdir -p "${BUILD_ROOT}"
rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"

if [[ "${PICKY_CLEAN:-1}" == "1" ]]; then
  rm -rf "${DERIVED_DATA_PATH}"
fi

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  MARKETING_VERSION="${MARKETING_VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "❌ Build succeeded but app bundle was not found: ${BUILT_APP}" >&2
  exit 1
fi

/usr/bin/ditto "${BUILT_APP}" "${PACKAGED_APP}"

/usr/bin/python3 - "${BUILD_INFO_PATH}" "${APP_NAME}" "${MARKETING_VERSION}" "${BUILD_NUMBER}" "${RELEASE_CHANNEL}" "${GIT_SHA}" "${BUILD_TIMESTAMP}" "${BUILD_LABEL}" "${CONFIGURATION}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
keys = ["appName", "marketingVersion", "buildNumber", "releaseChannel", "gitSha", "buildTimestamp", "buildLabel", "configuration"]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(dict(zip(keys, sys.argv[2:])), indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if [[ "${PACKAGE_AGENTD}" == "1" ]]; then
  PICKY_PACKAGE_BUILD_DIR="${BUILD_ROOT}" \
  PICKY_AGENTD_RUNTIME_DIR="${AGENTD_RUNTIME_DIR}" \
    "${ROOT_DIR}/scripts/package-agentd-runtime.sh"

  rm -rf "${PACKAGED_APP}/Contents/Resources/agentd"
  mkdir -p "${PACKAGED_APP}/Contents/Resources"
  /usr/bin/ditto "${AGENTD_RUNTIME_DIR}" "${PACKAGED_APP}/Contents/Resources/agentd"
fi

# Bundle pi-extensions so PickyExtensionInstaller can symlink them into
# ~/.pi/agent/extensions on first launch. Read-only at runtime; pi loads the
# .ts source directly so no compile step is required.
if [[ -d "${ROOT_DIR}/pi-extensions" ]]; then
  rm -rf "${PACKAGED_APP}/Contents/Resources/pi-extensions"
  /usr/bin/ditto "${ROOT_DIR}/pi-extensions" "${PACKAGED_APP}/Contents/Resources/pi-extensions"
fi

# Mutating the bundle after xcodebuild signing invalidates the resource seal.
# Re-sign the final app exactly as it will be distributed while preserving the
# entitlements Xcode generated for this configuration/signing identity.
CODESIGN_ARGS=(--force --deep --options runtime --sign "${CODE_SIGN_IDENTITY}")
if /usr/bin/codesign -d --entitlements :- "${BUILT_APP}" > "${ENTITLEMENTS_PLIST}" 2>/dev/null \
  && /usr/bin/grep -q "<plist" "${ENTITLEMENTS_PLIST}"; then
  CODESIGN_ARGS+=(--entitlements "${ENTITLEMENTS_PLIST}")
else
  rm -f "${ENTITLEMENTS_PLIST}"
fi
if [[ "${CODE_SIGN_IDENTITY}" == "-" ]]; then
  CODESIGN_ARGS+=(--timestamp=none)
fi
/usr/bin/codesign "${CODESIGN_ARGS[@]}" "${PACKAGED_APP}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${PACKAGED_APP}"

if [[ "${CREATE_ZIP}" == "1" ]]; then
  rm -f "${ZIP_PATH}"
  (
    cd "${EXPORT_DIR}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${ZIP_PATH}"
  )
fi

cat <<EOF
✅ Signed Picky package is ready.

App: ${PACKAGED_APP}
Version: ${MARKETING_VERSION} (${BUILD_NUMBER})
Build label: ${BUILD_LABEL}
Signature: ${CODE_SIGN_IDENTITY}
Configuration: ${CONFIGURATION}
Build info: ${BUILD_INFO_PATH}
$(if [[ "${PACKAGE_AGENTD}" == "1" ]]; then printf 'Bundled agentd: %s\n' "${PACKAGED_APP}/Contents/Resources/agentd"; fi)
$(if [[ -d "${PACKAGED_APP}/Contents/Resources/pi-extensions" ]]; then printf 'Bundled pi-extensions: %s\n' "${PACKAGED_APP}/Contents/Resources/pi-extensions"; fi)
$(if [[ "${CREATE_ZIP}" == "1" ]]; then printf 'Zip: %s\n' "${ZIP_PATH}"; fi)

Smoke tip:
  env PICKY_AGENTD_RUNTIME=mock "${PACKAGED_APP}/Contents/MacOS/${APP_NAME}"
EOF

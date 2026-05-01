#!/usr/bin/env bash
set -euo pipefail

# Build a signed local Picky.app package without changing project defaults.
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

APP_PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
BUILT_APP="${APP_PRODUCTS_DIR}/${APP_NAME}.app"
PACKAGED_APP="${EXPORT_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_ROOT}/${APP_NAME}-${CONFIGURATION}-signed.zip"

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
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "❌ Build succeeded but app bundle was not found: ${BUILT_APP}" >&2
  exit 1
fi

/usr/bin/ditto "${BUILT_APP}" "${PACKAGED_APP}"

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
Signature: ${CODE_SIGN_IDENTITY}
Configuration: ${CONFIGURATION}
$(if [[ "${CREATE_ZIP}" == "1" ]]; then printf 'Zip: %s\n' "${ZIP_PATH}"; fi)

Smoke tip:
  PICKY_AGENTD_RUNTIME=mock PICKY_AGENTD_ROOT="${ROOT_DIR}/agentd" \
    "${PACKAGED_APP}/Contents/MacOS/${APP_NAME}"
EOF

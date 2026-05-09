#!/usr/bin/env bash
set -euo pipefail

# Build and relaunch a development-signed Picky.app from a stable path.
#
# Why this exists:
# macOS TCC permissions (Microphone / Accessibility / Screen Recording) are tied
# to the app identity. Launching the ad-hoc DerivedData Debug app after each
# rebuild can make macOS treat it like a new app and ask for permissions again.
# This script keeps both the signing identity and launch path stable.
#
# Optional overrides:
#   PICKY_CODE_SIGN_IDENTITY="Apple Development: Name (TEAMID)" ./scripts/run-dev-signed-app.sh
#   PICKY_DEVELOPMENT_TEAM="TEAMID" ./scripts/run-dev-signed-app.sh
#   PICKY_SKIP_LAUNCH=1 ./scripts/run-dev-signed-app.sh
#   PICKY_ALLOW_ADHOC=1 ./scripts/run-dev-signed-app.sh  # not recommended for TCC stability

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${PICKY_APP_NAME:-Picky}"
BUNDLE_ID="${PICKY_BUNDLE_ID:-com.jonghakseo.picky}"
BUILD_ROOT="${PICKY_PACKAGE_BUILD_DIR:-${ROOT_DIR}/build/dev-signed}"
EXPORT_DIR="${PICKY_EXPORT_DIR:-${BUILD_ROOT}/export}"
PACKAGED_APP="${EXPORT_DIR}/${APP_NAME}.app"
CONFIGURATION="${PICKY_CONFIGURATION:-Debug}"
CREATE_ZIP="${PICKY_CREATE_ZIP:-0}"
CLEAN="${PICKY_CLEAN:-0}"
SKIP_QUIT="${PICKY_SKIP_QUIT:-0}"
SKIP_LAUNCH="${PICKY_SKIP_LAUNCH:-0}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./scripts/run-dev-signed-app.sh

Build and relaunch Picky from build/dev-signed/export/Picky.app using a stable
Apple code-signing identity so macOS TCC permissions are not reset on every
Debug rebuild.

Useful overrides:
  PICKY_CODE_SIGN_IDENTITY="Apple Development: Name (TEAMID)"
  PICKY_DEVELOPMENT_TEAM="TEAMID"
  PICKY_SKIP_LAUNCH=1
  PICKY_SKIP_QUIT=1
  PICKY_CLEAN=1
EOF
  exit 0
fi

choose_identity_record() {
  if [[ -n "${PICKY_CODE_SIGN_IDENTITY:-}" ]]; then
    printf '%s|%s\n' "${PICKY_CODE_SIGN_IDENTITY}" "${PICKY_CODE_SIGN_IDENTITY}"
    return 0
  fi

  local developer_id=""
  local developer_name=""
  local mac_developer_id=""
  local mac_developer_name=""
  local line=""
  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40})[[:space:]]+\"(Apple[[:space:]]Development:[^\"]+)\" ]]; then
      printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
    if [[ -z "${developer_id}" && "${line}" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40})[[:space:]]+\"(Developer[[:space:]]ID[[:space:]]Application:[^\"]+)\" ]]; then
      developer_id="${BASH_REMATCH[1]}"
      developer_name="${BASH_REMATCH[2]}"
    fi
    if [[ -z "${mac_developer_id}" && "${line}" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40})[[:space:]]+\"(Mac[[:space:]]Developer:[^\"]+)\" ]]; then
      mac_developer_id="${BASH_REMATCH[1]}"
      mac_developer_name="${BASH_REMATCH[2]}"
    fi
  done < <(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)

  if [[ -n "${developer_id}" ]]; then
    printf '%s|%s\n' "${developer_id}" "${developer_name}"
    return 0
  fi
  if [[ -n "${mac_developer_id}" ]]; then
    printf '%s|%s\n' "${mac_developer_id}" "${mac_developer_name}"
    return 0
  fi

  return 1
}

derive_team_id() {
  local identity="$1"
  if [[ -n "${PICKY_DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s\n' "${PICKY_DEVELOPMENT_TEAM}"
    return 0
  fi
  if [[ "${identity}" =~ \(([A-Z0-9]{10})\)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

quit_existing_app() {
  echo "⏹️  Quitting existing ${APP_NAME} processes..."
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

  local waited=0
  while /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; do
    if (( waited >= 50 )); then
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done

  if /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "⚠️  ${APP_NAME} did not quit in time; terminating remaining processes."
    /usr/bin/killall "${APP_NAME}" >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

IDENTITY_RECORD="$(choose_identity_record || true)"
CODE_SIGN_IDENTITY="${IDENTITY_RECORD%%|*}"
CODE_SIGN_DISPLAY_NAME="${IDENTITY_RECORD#*|}"
if [[ -z "${IDENTITY_RECORD}" || -z "${CODE_SIGN_IDENTITY}" ]]; then
  cat >&2 <<'EOF'
❌ No valid Apple code signing identity was found.

Run this to inspect available identities:
  security find-identity -v -p codesigning

Then rerun with:
  PICKY_CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  PICKY_DEVELOPMENT_TEAM="TEAMID" \
  ./scripts/run-dev-signed-app.sh
EOF
  exit 1
fi

if [[ "${CODE_SIGN_IDENTITY}" == "-" && "${PICKY_ALLOW_ADHOC:-0}" != "1" ]]; then
  cat >&2 <<'EOF'
❌ Ad-hoc signing was requested, but this script is meant to preserve macOS permissions.
Use an Apple Development or Developer ID Application identity instead.

If you really want ad-hoc signing, set:
  PICKY_ALLOW_ADHOC=1
EOF
  exit 1
fi

DEVELOPMENT_TEAM="$(derive_team_id "${CODE_SIGN_DISPLAY_NAME}" || true)"

if [[ "${SKIP_QUIT}" != "1" ]]; then
  quit_existing_app
fi

echo "🔐 Building ${APP_NAME}.app with stable development signing..."
echo "   identity: ${CODE_SIGN_DISPLAY_NAME}"
echo "   identity sha1: ${CODE_SIGN_IDENTITY}"
echo "   team: ${DEVELOPMENT_TEAM:-<not set>}"
echo "   configuration: ${CONFIGURATION}"
echo "   output: ${PACKAGED_APP}"

PICKY_CONFIGURATION="${CONFIGURATION}" \
PICKY_PACKAGE_BUILD_DIR="${BUILD_ROOT}" \
PICKY_EXPORT_DIR="${EXPORT_DIR}" \
PICKY_CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
PICKY_DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
PICKY_CREATE_ZIP="${CREATE_ZIP}" \
PICKY_CLEAN="${CLEAN}" \
PICKY_REALTIME_OPT_IN="${PICKY_REALTIME_OPT_IN:-0}" \
  "${ROOT_DIR}/scripts/package-signed-app.sh"

if [[ "${SKIP_LAUNCH}" == "1" ]]; then
  echo "✅ Built dev-signed app: ${PACKAGED_APP}"
  exit 0
fi

echo "🚀 Launching ${PACKAGED_APP}"
/usr/bin/open "${PACKAGED_APP}"
sleep 1

if /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "✅ ${APP_NAME} is running."
  /usr/bin/pgrep -fl "${APP_NAME}" || true
else
  echo "⚠️  Launch command returned, but ${APP_NAME} is not running yet. Check Console.app for launch errors." >&2
  exit 1
fi

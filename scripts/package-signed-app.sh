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
# Optional in-app feedback wiring:
#
#   PICKY_SLACK_BOT_TOKEN="xoxb-..." \
#   PICKY_SLACK_CHANNEL_ID="C0123456789" \
#   ./scripts/package-signed-app.sh
#
# This script intentionally does not notarize or publish. It is the safe local
# package/signing smoke used before a future full release pipeline.

SCRIPT_START_TS=${SECONDS}
PICKY_STEP_TIMINGS=()
__picky_current_step=""
__picky_current_step_ts=0

step_start() {
  __picky_current_step="$1"
  __picky_current_step_ts=${SECONDS}
  printf '⏱️  [start] %s\n' "${__picky_current_step}"
}

step_end() {
  if [[ -n "${__picky_current_step}" ]]; then
    local elapsed=$(( SECONDS - __picky_current_step_ts ))
    PICKY_STEP_TIMINGS+=("${__picky_current_step}|${elapsed}")
    printf '⏱️  [end]   %s — %ds\n' "${__picky_current_step}" "${elapsed}"
    __picky_current_step=""
  fi
}

print_step_timings() {
  step_end
  local total=$(( SECONDS - SCRIPT_START_TS ))
  printf '\n⏱️  Step timings (total %ds):\n' "${total}"
  local entry name secs
  for entry in "${PICKY_STEP_TIMINGS[@]}"; do
    name=${entry%%|*}
    secs=${entry##*|}
    printf '   %5ds  %s\n' "${secs}" "${name}"
  done
}
trap print_step_timings EXIT

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
# Keep SwiftPM checkouts/artifacts outside DerivedData so a clean rebuild
# (PICKY_CLEAN=1) does not invalidate the SPM cache. CI restores this path
# from actions/cache.
CLONED_SOURCE_PACKAGES_DIR="${PICKY_CLONED_SOURCE_PACKAGES_DIR:-${BUILD_ROOT}/spm-cache}"

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
REALTIME_OPT_IN="${PICKY_REALTIME_OPT_IN:-0}"
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
mkdir -p "${EXPORT_DIR}"

# Refuse to repackage while a Picky launched from EXPORT_DIR is still alive.
# Removing or replacing Contents/Resources/agentd under a running daemon makes
# its node child crash with `ENOENT: uv_cwd` next time it calls process.cwd(),
# which silently kills any in-flight Pickle session. Set PICKY_PACKAGE_FORCE=1
# to override (e.g. when you have already quit the app yourself).
#
# Match the main binary and the agentd entry point exactly, not any process
# whose command line happens to mention the .app path. macOS system services
# (mdworker, lsd, tccd, quicklookd) briefly touch the bundle while signing
# settles and would otherwise be flagged as "Picky still running".
MAIN_BINARY="${EXPORT_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
AGENTD_ENTRY="${EXPORT_DIR}/${APP_NAME}.app/Contents/Resources/agentd/dist/index.js"
find_live_picky_pids() {
  /bin/ps -A -o pid=,command= 2>/dev/null \
    | /usr/bin/awk -v main="${MAIN_BINARY}" -v entry="${AGENTD_ENTRY}" \
        '{
          cmd = $0
          sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", cmd)
          n = split(cmd, parts, /[[:space:]]+/)
          for (i = 1; i <= n; i++) {
            if (parts[i] == main || parts[i] == entry) {
              printf "%s ", $1
              next
            }
          }
        }'
}
# Sample twice with a short delay so we don't trip on transient PIDs from
# Spotlight / Launch Services / signature validation that briefly exec the
# binary right after a quit. Only flag a PID that survives both samples.
LIVE_PICKY_PIDS="$(find_live_picky_pids)"
LIVE_PICKY_PIDS="${LIVE_PICKY_PIDS%% }"
if [[ -n "${LIVE_PICKY_PIDS}" ]]; then
  sleep 0.6
  SECOND_SAMPLE="$(find_live_picky_pids)"
  SECOND_SAMPLE="${SECOND_SAMPLE%% }"
  STABLE_PIDS=""
  for _pid in ${LIVE_PICKY_PIDS}; do
    case " ${SECOND_SAMPLE} " in
      *" ${_pid} "*) STABLE_PIDS="${STABLE_PIDS}${_pid} ";;
    esac
  done
  LIVE_PICKY_PIDS="${STABLE_PIDS%% }"
fi
if [[ -n "${LIVE_PICKY_PIDS}" ]]; then
  if [[ "${PICKY_PACKAGE_FORCE:-0}" == "1" ]]; then
    echo "⚠️  Packaging forced while ${APP_NAME}.app is running (pids: ${LIVE_PICKY_PIDS}); the running daemon will likely crash." >&2
  else
    echo "❌ ${APP_NAME}.app is running from ${EXPORT_DIR} (pids: ${LIVE_PICKY_PIDS})." >&2
    for _pid in ${LIVE_PICKY_PIDS}; do
      _cmd="$(/bin/ps -A -o pid=,command= 2>/dev/null | /usr/bin/awk -v pid="${_pid}" '$1 == pid { sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); print; exit }')"
      echo "   pid=${_pid} cmd=${_cmd:-<exited>}" >&2
    done
    echo "   Quit it first, or rerun with PICKY_PACKAGE_FORCE=1 to proceed anyway." >&2
    exit 1
  fi
fi

if [[ "${PICKY_CLEAN:-1}" == "1" ]]; then
  rm -rf "${DERIVED_DATA_PATH}"
  rm -rf "${EXPORT_DIR:?}"/*
fi
mkdir -p "${CLONED_SOURCE_PACKAGES_DIR}"

# Cache guard: skip the agentd repackage step when nothing relevant changed.
# The hash covers TS sources, package metadata, and the workspace lockfile.
agentd_input_hash() {
  (
    cd "${ROOT_DIR}"
    /usr/bin/find \
      agentd/src \
      agentd/package.json \
      agentd/tsconfig.json \
      docs/user-manual.md \
      pnpm-lock.yaml \
      -type f -print0 2>/dev/null \
      | LC_ALL=C sort -z \
      | /usr/bin/xargs -0 /usr/bin/shasum -a 256 \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{print $1}'
  )
}

AGENTD_HASH_FILE="${AGENTD_RUNTIME_DIR}/.picky-agentd-input-hash"
NEEDS_AGENTD_BUILD=1
CURRENT_AGENTD_HASH=""
if [[ "${PACKAGE_AGENTD}" == "1" ]]; then
  CURRENT_AGENTD_HASH="$(agentd_input_hash || true)"
  if [[ -n "${CURRENT_AGENTD_HASH}" \
      && -f "${AGENTD_HASH_FILE}" \
      && -f "${AGENTD_RUNTIME_DIR}/dist/index.js" \
      && -d "${AGENTD_RUNTIME_DIR}/node_modules" ]]; then
    CACHED_AGENTD_HASH="$(/bin/cat "${AGENTD_HASH_FILE}" 2>/dev/null || true)"
    if [[ "${CURRENT_AGENTD_HASH}" == "${CACHED_AGENTD_HASH}" ]]; then
      NEEDS_AGENTD_BUILD=0
      echo "♻️  agentd inputs unchanged; reusing ${AGENTD_RUNTIME_DIR}"
    fi
  fi
fi

step_start "build_xcodebuild_and_agentd"
# Run agentd packaging in parallel with xcodebuild when a rebuild is needed.
AGENTD_PID=""
AGENTD_LOG=""
if [[ "${PACKAGE_AGENTD}" == "1" && "${NEEDS_AGENTD_BUILD}" == "1" ]]; then
  AGENTD_LOG="${BUILD_ROOT}/agentd-runtime.log"
  echo "🛠️  Building picky-agentd runtime in parallel (log: ${AGENTD_LOG})..."
  (
    PICKY_PACKAGE_BUILD_DIR="${BUILD_ROOT}" \
    PICKY_AGENTD_RUNTIME_DIR="${AGENTD_RUNTIME_DIR}" \
      "${ROOT_DIR}/scripts/package-agentd-runtime.sh"
  ) >"${AGENTD_LOG}" 2>&1 &
  AGENTD_PID=$!
fi

set +e
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -clonedSourcePackagesDirPath "${CLONED_SOURCE_PACKAGES_DIR}" \
  build \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  MARKETING_VERSION="${MARKETING_VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
XCODEBUILD_STATUS=$?
set -e

if [[ -n "${AGENTD_PID}" ]]; then
  if ! wait "${AGENTD_PID}"; then
    echo "❌ picky-agentd runtime build failed. Last 200 lines:" >&2
    /usr/bin/tail -n 200 "${AGENTD_LOG}" >&2 || true
    exit 1
  fi
  /usr/bin/tail -n 5 "${AGENTD_LOG}" || true
fi

if [[ "${XCODEBUILD_STATUS}" -ne 0 ]]; then
  exit "${XCODEBUILD_STATUS}"
fi

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "❌ Build succeeded but app bundle was not found: ${BUILT_APP}" >&2
  exit 1
fi

if [[ "${PACKAGE_AGENTD}" == "1" && "${NEEDS_AGENTD_BUILD}" == "1" && -n "${CURRENT_AGENTD_HASH}" ]]; then
  printf '%s\n' "${CURRENT_AGENTD_HASH}" > "${AGENTD_HASH_FILE}"
fi
step_end

step_start "stage_app_bundle"
# Sync the freshly built bundle into PACKAGED_APP without wiping cached
# Resources/agentd or Resources/pi-extensions trees that we plan to update
# selectively below. rsync's --delete prunes stale Xcode-produced files only.
mkdir -p "${PACKAGED_APP}"
# macOS /usr/bin/rsync is openrsync, which does not accept the GNU short flag
# -X. Use --extended-attributes (supported by both openrsync and Apple rsync
# 2.6.9) so com.apple.* xattrs survive the copy; codesign will re-seal anyway.
/usr/bin/rsync -a --extended-attributes --delete \
  --exclude '/Contents/Resources/agentd/' \
  --exclude '/Contents/Resources/pi-extensions/' \
  "${BUILT_APP}/" "${PACKAGED_APP}/"

/usr/bin/python3 - "${BUILD_INFO_PATH}" "${APP_NAME}" "${MARKETING_VERSION}" "${BUILD_NUMBER}" "${RELEASE_CHANNEL}" "${GIT_SHA}" "${BUILD_TIMESTAMP}" "${BUILD_LABEL}" "${CONFIGURATION}" "${REALTIME_OPT_IN}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
keys = ["appName", "marketingVersion", "buildNumber", "releaseChannel", "gitSha", "buildTimestamp", "buildLabel", "configuration", "realtimeOptIn"]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(dict(zip(keys, sys.argv[2:])), indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

# Inject the in-app feedback Slack configuration from environment variables.
# Always write the file (even with empty values) so the bundle layout is stable
# and codesign seals the same set of resources every run. Empty values leave the
# feedback feature disabled at runtime via PickyFeedbackConfiguration.isConfigured.
FEEDBACK_SECRETS_PATH="${PACKAGED_APP}/Contents/Resources/PickyFeedbackSecrets.json"
if [[ -z "${PICKY_SLACK_BOT_TOKEN:-}" ]]; then
  echo "⚠️  PICKY_SLACK_BOT_TOKEN not set; in-app feedback Slack token will be empty (feature disabled)."
fi
if [[ -z "${PICKY_SLACK_CHANNEL_ID:-}" ]]; then
  echo "⚠️  PICKY_SLACK_CHANNEL_ID not set; in-app feedback Slack channel will be empty (feature disabled)."
fi
/usr/bin/python3 - "${FEEDBACK_SECRETS_PATH}" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
token = os.environ.get("PICKY_SLACK_BOT_TOKEN", "").strip()
channel_id = os.environ.get("PICKY_SLACK_CHANNEL_ID", "").strip()
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"slackBotToken": token, "slackChannelID": channel_id}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

# Bundle picky-agentd. The runtime tree contains ~17k node_modules files, so
# rsync's per-file stat compare costs ~8s even on a no-op pass. Two-stage
# optimization:
#   1) If the deployed bundle's hash marker matches CURRENT_AGENTD_HASH, skip
#      the copy entirely.
#   2) Otherwise replace the directory with `cp -Rc`, which uses APFS
#      clonefile and finishes in ~2-3s for the same tree.
if [[ "${PACKAGE_AGENTD}" == "1" ]]; then
  PACKAGED_AGENTD_DIR="${PACKAGED_APP}/Contents/Resources/agentd"
  PACKAGED_AGENTD_HASH_FILE="${PACKAGED_AGENTD_DIR}/.picky-agentd-input-hash"
  AGENTD_DEPLOYED_HASH=""
  if [[ -f "${PACKAGED_AGENTD_HASH_FILE}" ]]; then
    AGENTD_DEPLOYED_HASH="$(/bin/cat "${PACKAGED_AGENTD_HASH_FILE}" 2>/dev/null || true)"
  fi
  if [[ -n "${CURRENT_AGENTD_HASH}" \
      && "${CURRENT_AGENTD_HASH}" == "${AGENTD_DEPLOYED_HASH}" \
      && -f "${PACKAGED_AGENTD_DIR}/dist/index.js" ]]; then
    echo "♻️  Bundled agentd matches input hash; skipping copy"
  else
    rm -rf "${PACKAGED_AGENTD_DIR}"
    mkdir -p "${PACKAGED_APP}/Contents/Resources"
    /bin/cp -Rc "${AGENTD_RUNTIME_DIR}" "${PACKAGED_AGENTD_DIR}"
  fi
fi

# Bundle pi-extensions so PickyExtensionInstaller can symlink them into
# ~/.pi/agent/extensions on first launch. Run outside Xcode's user-script
# sandbox because recursive directory writes under Resources are restricted
# when declared as a single script output directory.
if [[ -d "${ROOT_DIR}/pi-extensions" ]]; then
  rm -rf "${PACKAGED_APP}/Contents/Resources/pi-extensions"
  mkdir -p "${PACKAGED_APP}/Contents/Resources"
  /bin/cp -Rc "${ROOT_DIR}/pi-extensions" "${PACKAGED_APP}/Contents/Resources/pi-extensions"
fi

# Bundle the watchdog alert helper. Kept as a tiny standalone executable so
# the watchdog can spawn a recovery dialog without depending on the main
# process (which is unresponsive by definition when the watchdog fires).
WATCHDOG_HELPER_SRC="${ROOT_DIR}/Picky/Watchdog/PickyWatchdogAlertHelper/main.swift"
if [[ -f "${WATCHDOG_HELPER_SRC}" ]]; then
  WATCHDOG_HELPER_DIR="${PACKAGED_APP}/Contents/Helpers"
  mkdir -p "${WATCHDOG_HELPER_DIR}"
  /usr/bin/xcrun swiftc -O "${WATCHDOG_HELPER_SRC}" \
    -o "${WATCHDOG_HELPER_DIR}/picky-watchdog-alert"
fi
step_end

step_start "codesign"
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
step_end

if [[ "${CREATE_ZIP}" == "1" ]]; then
  step_start "zip"
  rm -f "${ZIP_PATH}"
  (
    cd "${EXPORT_DIR}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${ZIP_PATH}"
  )
  step_end
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

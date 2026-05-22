#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
DEFAULT_CACHE_DIR="${REPO_ROOT}/build/cache/node"
CACHE_DIR="${PICKY_NODE_CACHE_DIR:-${DEFAULT_CACHE_DIR}}"
PACKAGE_JSON="${REPO_ROOT}/agentd/package.json"

error() {
  echo "❌ $*" >&2
}

log() {
  echo "$*" >&2
}

read_package_node_version() {
  awk '
    /"engines"[[:space:]]*:/ { in_engines = 1; next }
    in_engines && /}/ { in_engines = 0 }
    in_engines && /"node"[[:space:]]*:/ {
      line = $0
      sub(/^[^"]*"node"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "${PACKAGE_JSON}"
}

is_exact_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

if [[ -n "${PICKY_NODE_VERSION:-}" ]]; then
  VERSION="${PICKY_NODE_VERSION}"
  if ! is_exact_version "${VERSION}"; then
    error "PICKY_NODE_VERSION must be an exact version like \"22.19.0\", got \"${VERSION}\""
    exit 1
  fi
else
  VERSION="$(read_package_node_version)"
  if [[ -z "${VERSION}" ]]; then
    error "Could not read engines.node from ${PACKAGE_JSON}"
    exit 1
  fi
  if ! is_exact_version "${VERSION}"; then
    error "engines.node must be an exact version like \"22.19.0\", got \"${VERSION}\""
    exit 1
  fi
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "arm64" ]]; then
  error "Only darwin-arm64 is supported, got ${ARCH}"
  exit 1
fi

mkdir -p "${CACHE_DIR}"
CACHE_DIR_ABS="$(cd "${CACHE_DIR}" && pwd -P)"
TARGET_DIR="${CACHE_DIR_ABS}/${VERSION}-arm64"
NODE_BIN="${TARGET_DIR}/bin/node"

if [[ -x "${NODE_BIN}" ]]; then
  log "✅ Using cached Node v${VERSION} darwin-arm64 at ${NODE_BIN}"
  printf '%s\n' "${NODE_BIN}"
  exit 0
fi

TARBALL="node-v${VERSION}-darwin-arm64.tar.gz"
TARBALL_URL="https://nodejs.org/dist/v${VERSION}/${TARBALL}"
SHASUMS_URL="https://nodejs.org/dist/v${VERSION}/SHASUMS256.txt"
TMP_DIR="$(mktemp -d)"
STAGING_DIR="${CACHE_DIR_ABS}/.${VERSION}-arm64.tmp.$$"

cleanup() {
  rm -rf "${TMP_DIR}" "${STAGING_DIR}"
}
trap cleanup EXIT

log "📦 Fetching Node v${VERSION} darwin-arm64..."
curl --fail --location --silent --show-error --output "${TMP_DIR}/${TARBALL}" "${TARBALL_URL}"
curl --fail --location --silent --show-error --output "${TMP_DIR}/SHASUMS256.txt" "${SHASUMS_URL}"

EXPECTED_SHA="$(awk -v file="${TARBALL}" '$2 == file { print $1; exit }' "${TMP_DIR}/SHASUMS256.txt")"
if [[ -z "${EXPECTED_SHA}" ]]; then
  error "Could not find ${TARBALL} in SHASUMS256.txt"
  exit 1
fi

ACTUAL_SHA="$(shasum -a 256 "${TMP_DIR}/${TARBALL}" | awk '{ print $1 }')"
if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
  error "SHA256 mismatch for ${TARBALL}: expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
  exit 1
fi
log "✅ SHA256 verified"

mkdir -p "${TMP_DIR}/extract"
tar -xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}/extract"
EXTRACTED_NODE="${TMP_DIR}/extract/node-v${VERSION}-darwin-arm64/bin/node"
if [[ ! -f "${EXTRACTED_NODE}" ]]; then
  error "Extracted node binary not found at ${EXTRACTED_NODE}"
  exit 1
fi

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/bin"
cp "${EXTRACTED_NODE}" "${STAGING_DIR}/bin/node"
chmod +x "${STAGING_DIR}/bin/node"

CACHED_VERSION="$(${STAGING_DIR}/bin/node --version)"
if [[ "${CACHED_VERSION}" != "v${VERSION}" ]]; then
  rm -f "${STAGING_DIR}/bin/node"
  error "Cached node version mismatch: expected v${VERSION}, got ${CACHED_VERSION}"
  exit 1
fi

rm -rf "${TARGET_DIR}"
mv "${STAGING_DIR}" "${TARGET_DIR}"
log "✅ Cached at ${NODE_BIN}"
printf '%s\n' "${NODE_BIN}"

#!/usr/bin/env bash
set -euo pipefail

# Build a standalone picky-agentd runtime directory for bundling inside Picky.app.
#
# The packaged runtime intentionally depends on a user-provided `node` executable
# but does not require pnpm, tsx, TypeScript, or the agentd source tree at app
# launch time. pnpm is only required on the packager/developer machine.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTD_DIR="${ROOT_DIR}/agentd"
BUILD_ROOT="${PICKY_PACKAGE_BUILD_DIR:-${ROOT_DIR}/build/package}"
RUNTIME_DIR="${PICKY_AGENTD_RUNTIME_DIR:-${BUILD_ROOT}/agentd-runtime}"
PNPM_BIN="${PICKY_PNPM_BIN:-pnpm}"

if [[ ! -f "${AGENTD_DIR}/package.json" ]]; then
  echo "❌ agentd/package.json not found. Run this script from the Picky repository." >&2
  exit 1
fi

if ! command -v "${PNPM_BIN}" >/dev/null 2>&1; then
  echo "❌ ${PNPM_BIN} not found. Install pnpm to package picky-agentd." >&2
  exit 1
fi

mkdir -p "$(dirname "${RUNTIME_DIR}")"
rm -rf "${RUNTIME_DIR}"

if [[ "${PICKY_AGENTD_SKIP_INSTALL:-0}" != "1" ]]; then
  echo "📦 Installing agentd workspace dependencies..."
  "${PNPM_BIN}" --dir "${ROOT_DIR}" install --frozen-lockfile
fi

echo "🛠️  Building picky-agentd TypeScript..."
"${PNPM_BIN}" --dir "${AGENTD_DIR}" run build

echo "📦 Creating production agentd runtime at ${RUNTIME_DIR}..."
(
  cd "${ROOT_DIR}"
  "${PNPM_BIN}" --filter picky-agentd deploy --prod --legacy "${RUNTIME_DIR}"
)

# Keep the bundle focused on files needed by `node dist/index.js`.
rm -rf \
  "${RUNTIME_DIR}/src" \
  "${RUNTIME_DIR}/tsconfig.json" \
  "${RUNTIME_DIR}/node_modules/.bin" \
  "${RUNTIME_DIR}/node_modules/.pnpm/node_modules"

if [[ -d "${RUNTIME_DIR}/dist" ]]; then
  find "${RUNTIME_DIR}/dist" -name "*.test.js" -type f -delete
  find "${RUNTIME_DIR}/dist" -name "__tests__" -type d -prune -exec rm -rf {} +
fi

mkdir -p "${RUNTIME_DIR}/docs"
cp "${ROOT_DIR}/docs/user-manual.md" "${RUNTIME_DIR}/docs/user-manual.md"

# Bundle the seed Picky skills so PickySkillStore can copy them into
# ~/Library/Application Support/Picky/skills/ on first launch. The store
# resolves this directory relative to dist/application/, mirroring the
# user-guide doc lookup above.
mkdir -p "${RUNTIME_DIR}/seeds/picky-skills"
if compgen -G "${ROOT_DIR}/agentd/seeds/picky-skills/*.md" > /dev/null; then
  cp "${ROOT_DIR}/agentd/seeds/picky-skills/"*.md "${RUNTIME_DIR}/seeds/picky-skills/"
fi

# The package metadata is used by Node to preserve ESM mode (`type: module`).
# Remove development-only metadata so the bundled package is easier to inspect.
node - "${RUNTIME_DIR}/package.json" <<'NODE'
const fs = require('node:fs');
const path = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
delete pkg.devDependencies;
delete pkg.scripts;
pkg.main = pkg.main || 'dist/index.js';
fs.writeFileSync(path, `${JSON.stringify(pkg, null, 2)}\n`);
NODE

if [[ ! -f "${RUNTIME_DIR}/dist/index.js" ]]; then
  echo "❌ Packaged agentd runtime is missing dist/index.js: ${RUNTIME_DIR}" >&2
  exit 1
fi

if [[ ! -d "${RUNTIME_DIR}/node_modules" ]]; then
  echo "❌ Packaged agentd runtime is missing node_modules: ${RUNTIME_DIR}" >&2
  exit 1
fi

node --check "${RUNTIME_DIR}/dist/index.js" >/dev/null

cat <<EOF
✅ picky-agentd runtime is ready.

Runtime: ${RUNTIME_DIR}
Entry: ${RUNTIME_DIR}/dist/index.js
Launch: node "${RUNTIME_DIR}/dist/index.js"
EOF

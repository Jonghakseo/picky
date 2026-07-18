#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if ! command -v node >/dev/null 2>&1; then
  echo "❌ pre-commit: 'node' is required. Install Node.js 22.19.0." >&2
  exit 127
fi

exec "$ROOT/scripts/check-agentd-lint-snapshot.sh" --index

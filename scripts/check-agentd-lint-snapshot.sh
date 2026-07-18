#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
MODE="${1:-}"
REVISION="${2:-}"
SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/picky-agentd-lint.XXXXXX")"
trap 'rm -rf "$SNAPSHOT"' EXIT

case "$MODE" in
  --index)
    git checkout-index --all --force --prefix="$SNAPSHOT/"
    LABEL="staged index"
    ;;
  --commit)
    if [ -z "$REVISION" ]; then
      echo "usage: $0 --commit <commit>" >&2
      exit 2
    fi
    git cat-file -e "${REVISION}^{commit}"
    git archive "$REVISION" | tar -x -C "$SNAPSHOT"
    LABEL="outgoing commit ${REVISION:0:12}"
    ;;
  *)
    echo "usage: $0 --index | --commit <commit>" >&2
    exit 2
    ;;
esac

ESLINT="$ROOT/agentd/node_modules/.bin/eslint"
if [ ! -x "$ESLINT" ]; then
  echo "❌ agentd snapshot lint: dependencies are missing. Run 'pnpm install'." >&2
  exit 127
fi
if [ ! -d "$SNAPSHOT/agentd/src" ] || [ ! -f "$SNAPSHOT/agentd/eslint.config.js" ]; then
  echo "❌ agentd snapshot lint: $LABEL does not contain the agentd lint inputs." >&2
  exit 1
fi

ln -s "$ROOT/agentd/node_modules" "$SNAPSHOT/agentd/node_modules"

echo "▶ agentd: lint $LABEL (zero warnings)"
(
  cd "$SNAPSHOT/agentd"
  "$ESLINT" src --max-warnings 0
)

ALLOWLIST="$SNAPSHOT/scripts/eslint-suppressions.json"
if [ ! -f "$ALLOWLIST" ]; then
  ALLOWLIST="$ROOT/scripts/eslint-suppressions.json"
fi
node "$ROOT/scripts/check-eslint-suppressions.js" "$SNAPSHOT" "$ALLOWLIST"

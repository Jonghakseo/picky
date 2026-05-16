#!/usr/bin/env bash
#
# check-localizations.sh
#
# Walks Localizable.xcstrings and reports any keys that don't yet have a
# translation for every known language. Intended to run in CI / pre-commit.
#
# Usage:
#   scripts/check-localizations.sh            # default: en + ko required
#   scripts/check-localizations.sh en ko fr   # require additional languages
#
# Exit codes:
#   0 — all required languages have a translated stringUnit for every key
#   1 — at least one key is missing a translation (offenders printed)
#   2 — the catalog file isn't where we expected it

set -euo pipefail

CATALOG="${PICKY_CATALOG:-Picky/Resources/Localizable.xcstrings}"
REQUIRED_LANGS=("$@")
if [[ ${#REQUIRED_LANGS[@]} -eq 0 ]]; then
    REQUIRED_LANGS=("en" "ko")
fi

if [[ ! -f "$CATALOG" ]]; then
    echo "❌ Catalog not found at $CATALOG" >&2
    exit 2
fi

python3 - "$CATALOG" "${REQUIRED_LANGS[@]}" <<'PY'
import json
import sys

path = sys.argv[1]
required = sys.argv[2:]

with open(path, "r", encoding="utf-8") as handle:
    catalog = json.load(handle)

missing = []
for key, entry in catalog.get("strings", {}).items():
    localizations = entry.get("localizations", {})
    for language in required:
        unit = localizations.get(language, {}).get("stringUnit", {})
        value = unit.get("value", "")
        state = unit.get("state", "")
        if not value or state in {"new", "needs_review"}:
            missing.append((key, language, state or "(no value)"))

if missing:
    print(f"❌ {len(missing)} missing translations across {len(required)} required languages:")
    for key, language, state in sorted(missing):
        print(f"  - {key}  ({language}: {state})")
    sys.exit(1)

print(f"✅ All keys translated for: {', '.join(required)}")
PY

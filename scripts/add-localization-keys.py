#!/usr/bin/env python3
"""Merge en/ko string entries into Localizable.xcstrings.

Usage:
  scripts/add-localization-keys.py <keys.json> [--catalog PATH] [--overwrite]

`keys.json` maps a key to {"en": "...", "ko": "...", "comment": "optional"}.
Existing keys are left untouched unless --overwrite is passed. New keys are
appended in insertion order and the catalog keeps its 2-space layout so the
diff stays reviewable.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_CATALOG = Path(__file__).resolve().parents[1] / "Picky" / "Resources" / "Localizable.xcstrings"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("keys", type=Path)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    entries = json.loads(args.keys.read_text(encoding="utf-8"))
    strings = catalog.setdefault("strings", {})

    added = updated = skipped = 0
    for key, value in entries.items():
        if not isinstance(value, dict) or "en" not in value or "ko" not in value:
            print(f"❌ {key}: needs both 'en' and 'ko'", file=sys.stderr)
            return 1
        entry = {
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": value["en"]}},
                "ko": {"stringUnit": {"state": "translated", "value": value["ko"]}},
            }
        }
        if value.get("comment"):
            entry["comment"] = value["comment"]
        if key in strings:
            if args.overwrite:
                strings[key] = entry
                updated += 1
            else:
                skipped += 1
            continue
        strings[key] = entry
        added += 1

    args.catalog.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"added={added} updated={updated} skipped={skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

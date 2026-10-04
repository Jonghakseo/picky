#!/usr/bin/env python3
"""Keep prototype copy identical to the Mac app's String Catalog.

Every user-facing string in the prototypes carries `data-l10n="<key>"` with the key's
Korean value as its text. The app's `Picky/Resources/Localizable.xcstrings` is the only
source of copy; strings that do not exist there yet are listed in new-strings.md.

Usage:
  python3 tools/l10n.py find <text or key>   search keys and Korean/English values
  python3 tools/l10n.py extract              write strings.ko.json and strings.en.json
  python3 tools/l10n.py check                fail when an element's text differs from its key,
                                             or a data-l10n-new key is missing from new-strings.md
"""

from __future__ import annotations

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

PROTO = Path(__file__).resolve().parent.parent
REPO = PROTO.parents[2]
CATALOG = REPO / "Picky/Resources/Localizable.xcstrings"
NEW_STRINGS = PROTO / "new-strings.md"
NEW_KEY = re.compile(r'data-l10n-new="([^"]+)"')
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


def load_catalog() -> tuple[dict, str]:
    data = json.loads(CATALOG.read_text())
    return data["strings"], data.get("sourceLanguage", "en")


def value(entry: dict, lang: str, key: str, source_lang: str) -> str | None:
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return key if lang == source_lang else None
    if "stringUnit" in loc:
        return loc["stringUnit"]["value"]
    for kind in ("plural", "device"):
        forms = loc.get("variations", {}).get(kind)
        if forms:
            form = forms.get("other") or next(iter(forms.values()))
            return form["stringUnit"]["value"]
    return None


class L10nCollector(HTMLParser):
    """Collects (key, text) for every element that has a data-l10n attribute."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[list] = []  # [tag, key or None, text parts]
        self.found: list[tuple[str, str]] = []

    def handle_starttag(self, tag, attrs):
        if tag in VOID_TAGS:
            return
        key = dict(attrs).get("data-l10n")
        self.stack.append([tag, key, []])

    def handle_endtag(self, tag):
        while self.stack:
            open_tag, key, parts = self.stack.pop()
            text = "".join(parts)
            if self.stack:
                self.stack[-1][2].append(text)
            if key:
                self.found.append((key, " ".join(text.split())))
            if open_tag == tag:
                break

    def handle_data(self, data):
        if self.stack:
            self.stack[-1][2].append(data)


def collect() -> list[tuple[Path, str, str]]:
    results = []
    for path in sorted(PROTO.glob("*.html")):
        parser = L10nCollector()
        parser.feed(path.read_text())
        results += [(path, key, text) for key, text in parser.found]
    return results


def format_regex(template: str) -> re.Pattern:
    """Turns a printf-style catalog value into a pattern that accepts sample values."""
    parts = re.split(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)", template)
    return re.compile("^" + ".+?".join(re.escape(" ".join(p.split())) for p in parts) + "$")


def cmd_find(query: str) -> int:
    strings, source_lang = load_catalog()
    needle = query.lower()
    shown = 0
    for key, entry in strings.items():
        ko = value(entry, "ko", key, source_lang) or ""
        en = value(entry, "en", key, source_lang) or ""
        if needle in key.lower() or needle in ko.lower() or needle in en.lower():
            print(f"{key}\n    ko: {ko}\n    en: {en}")
            shown += 1
            if shown >= 40:
                print("... (first 40 matches)")
                break
    if shown == 0:
        print("no match")
    return 0


def cmd_extract() -> int:
    strings, source_lang = load_catalog()
    keys = sorted({key for _, key, _ in collect()})
    missing = [key for key in keys if key not in strings]
    if missing:
        print("keys not in Localizable.xcstrings: " + ", ".join(missing), file=sys.stderr)
        return 1
    for lang in ("ko", "en"):
        table = {key: value(strings[key], lang, key, source_lang) for key in keys}
        (PROTO / f"strings.{lang}.json").write_text(json.dumps(table, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"wrote strings.ko.json and strings.en.json ({len(keys)} keys)")
    return 0


def cmd_check() -> int:
    strings, source_lang = load_catalog()
    problems = 0
    for path, key, text in collect():
        entry = strings.get(key)
        if entry is None:
            print(f"{path.name}: unknown key {key}")
            problems += 1
            continue
        ko = value(entry, "ko", key, source_lang)
        if ko is None:
            print(f"{path.name}: {key} has no Korean value")
            problems += 1
            continue
        if not format_regex(ko).match(text):
            print(f"{path.name}: {key} text {text!r} differs from catalog {ko!r}")
            problems += 1
    listed = NEW_STRINGS.read_text() if NEW_STRINGS.exists() else ""
    for path in sorted(PROTO.glob("*.html")):
        for key in sorted(set(NEW_KEY.findall(path.read_text()))):
            if key in strings:
                print(f"{path.name}: {key} already exists in the catalog; use data-l10n")
                problems += 1
            elif f"`{key}`" not in listed:
                print(f"{path.name}: new key {key} is not listed in new-strings.md")
                problems += 1
    print("l10n check: " + ("ok" if problems == 0 else f"{problems} problem(s)"))
    return 1 if problems else 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "find":
        return cmd_find(" ".join(argv[1:]))
    if argv == ["extract"]:
        return cmd_extract()
    if argv == ["check"]:
        return cmd_check()
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Static checks for the remote PWA prototypes.

Fails when a prototype file
  - references a CSS custom property that neither tokens.css nor the same file defines,
  - writes a raw hex color outside tokens.css,
  - contains an inline <script>, an inline event handler, or a network resource.

Usage: python3 tools/lint.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PROTO = Path(__file__).resolve().parent.parent
TOKENS = PROTO / "tokens.css"

DEFINE = re.compile(r"(--[A-Za-z0-9_-]+)\s*:")
USE = re.compile(r"var\(\s*(--[A-Za-z0-9_-]+)")
HEX = re.compile(r"(?<![&\w])#[0-9a-fA-F]{3,8}\b")
INLINE_SCRIPT = re.compile(r"<script(?![^>]*\bsrc=)[^>]*>", re.I)
INLINE_HANDLER = re.compile(r"\son[a-z]+\s*=", re.I)
NETWORK = re.compile(r"""(?:src|href)\s*=\s*["']https?://|url\(\s*["']?https?://|@import\s+["']?https?://""", re.I)


def strip_html_text_hex_false_positives(text: str) -> str:
    # Drop HTML character references such as &#123; before scanning for hex colors.
    return re.sub(r"&#x?[0-9a-fA-F]+;", "", text)


def main() -> int:
    token_names = set(DEFINE.findall(TOKENS.read_text()))
    problems: list[str] = []
    files = sorted(p for p in PROTO.glob("*") if p.suffix in {".css", ".html"} and p.name != "tokens.css")
    for path in files:
        text = path.read_text()
        # A part's .html may define a custom property inline (style="--x: 60%") that its
        # .css consumes, so the .html/.css pair with the same stem shares definitions.
        local = set(DEFINE.findall(text))
        for sibling in (path.with_suffix(".html"), path.with_suffix(".css")):
            if sibling != path and sibling.exists():
                local |= set(DEFINE.findall(sibling.read_text()))
        for name in sorted(set(USE.findall(text)) - token_names - local):
            problems.append(f"{path.name}: undefined custom property {name}")
        for match in HEX.finditer(strip_html_text_hex_false_positives(text)):
            line = text[: match.start()].count("\n") + 1
            problems.append(f"{path.name}:{line}: raw hex color {match.group(0)}")
        if path.suffix == ".html":
            for match in INLINE_SCRIPT.finditer(text):
                line = text[: match.start()].count("\n") + 1
                problems.append(f"{path.name}:{line}: inline <script>")
            for match in INLINE_HANDLER.finditer(text):
                line = text[: match.start()].count("\n") + 1
                problems.append(f"{path.name}:{line}: inline event handler")
        for match in NETWORK.finditer(text):
            line = text[: match.start()].count("\n") + 1
            problems.append(f"{path.name}:{line}: network resource")
    for problem in problems:
        print(problem)
    print(f"lint: {len(files)} files, " + ("ok" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

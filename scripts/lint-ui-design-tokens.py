#!/usr/bin/env python3
"""Reject new raw UI design values while preserving a committed legacy baseline.

The baseline stores stable fingerprints made from the repository-relative path,
normalized source expression, and that expression's occurrence ordinal. It never
uses line numbers, so moving legacy code does not invalidate the guard.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SCAN_ROOTS = (
    "Picky/HUD",
    "Picky/QuickInput",
    "Picky/Companion",
    "Picky/App/Settings",
    "Picky/Overlay",
    "Picky/PointerOverlay",
)
EXCLUDED_FILES = frozenset(
    {
        "Picky/DesignSystem.swift",
        "Picky/HUD/PickyHUDTypography.swift",
        "Picky/HUD/PickyHUDLayoutPolicy.swift",
    }
)
BASELINE_PATH = "design/ui-design-token-baseline.json"
EXCEPTION_MARKER = "design-token-exception:"
GENERIC_EXCEPTION_REASONS = frozenset({"", "reason", "exception", "todo", "n/a", "na", "legacy", "temporary", "temp"})

CALL_STARTS = (
    ("font", re.compile(r"\.font\(\.system\(size:")),
    ("padding", re.compile(r"\.padding\(")),
    ("cornerRadius", re.compile(r"\.cornerRadius\(")),
    ("cornerRadius", re.compile(r"RoundedRectangle\(cornerRadius:")),
    ("shadow", re.compile(r"\.shadow\(")),
)
NUMBER = r"[-+]?(?:\d+(?:\.\d+)?|\.\d+)"


@dataclass(frozen=True)
class Occurrence:
    path: str
    line: int
    category: str
    expression: str
    normalized_expression: str
    ordinal: int
    exception_reason: str | None

    @property
    def fingerprint(self) -> str:
        payload = f"{self.path}\0{self.normalized_expression}\0{self.ordinal}".encode()
        return hashlib.sha256(payload).hexdigest()


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def extract_call(source: str, start: int) -> tuple[str, int] | None:
    """Returns the complete balanced call beginning at a known `foo(` start."""
    open_paren = source.find("(", start)
    if open_paren == -1:
        return None
    depth = 0
    quote: str | None = None
    escaped = False
    index = open_paren
    while index < len(source):
        character = source[index]
        if quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
        elif character in ('"', "'"):
            quote = character
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start : index + 1], index + 1
        index += 1
    return None


def remove_comments(expression: str) -> str:
    output: list[str] = []
    index = 0
    quote: str | None = None
    escaped = False
    while index < len(expression):
        character = expression[index]
        next_character = expression[index + 1] if index + 1 < len(expression) else ""
        if quote:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            index += 1
            continue
        if character in ('"', "'"):
            quote = character
            output.append(character)
            index += 1
        elif character == "/" and next_character == "/":
            newline = expression.find("\n", index)
            if newline == -1:
                break
            output.append(" ")
            index = newline + 1
        elif character == "/" and next_character == "*":
            end = expression.find("*/", index + 2)
            index = len(expression) if end == -1 else end + 2
            output.append(" ")
        else:
            output.append(character)
            index += 1
    return "".join(output)


def normalize_expression(expression: str) -> str:
    return re.sub(r"\s+", " ", remove_comments(expression)).strip()


def is_raw(category: str, expression: str) -> bool:
    compact = normalize_expression(expression)
    if category == "font":
        return True
    if category == "padding":
        arguments = compact[compact.find("(") + 1 : -1]
        return re.match(rf"(?:\.(?:horizontal|vertical|top|bottom|leading|trailing)\s*,\s*)?{NUMBER}(?:\s*,|$)", arguments) is not None
    if category == "cornerRadius":
        arguments = compact[compact.find("cornerRadius:") + len("cornerRadius:") :]
        return re.match(rf"\s*{NUMBER}(?:\s*,|\))", arguments) is not None
    if category == "shadow":
        return re.search(rf"(?:radius|x|y):\s*{NUMBER}(?:\s*,|\))", compact) is not None
    raise ValueError(f"Unknown category: {category}")


def inline_exception_reason(source: str, start: int) -> str | None:
    line_end = source.find("\n", start)
    if line_end == -1:
        line_end = len(source)
    line = source[start:line_end]
    marker_index = line.lower().find(EXCEPTION_MARKER)
    if marker_index == -1:
        return None
    return line[marker_index + len(EXCEPTION_MARKER) :].strip()


def paths_for(root: Path, scan_roots: Iterable[str] = SCAN_ROOTS) -> list[Path]:
    files: list[Path] = []
    for relative_root in scan_roots:
        candidate = root / relative_root
        if candidate.is_file() and candidate.suffix == ".swift":
            files.append(candidate)
        elif candidate.is_dir():
            files.extend(candidate.rglob("*.swift"))
    return sorted(path for path in files if path.relative_to(root).as_posix() not in EXCLUDED_FILES)


def scan(root: Path, scan_roots: Iterable[str] = SCAN_ROOTS) -> list[Occurrence]:
    provisional: list[Occurrence] = []
    for path in paths_for(root, scan_roots):
        source = path.read_text(encoding="utf-8")
        relative_path = path.relative_to(root).as_posix()
        candidates: list[tuple[int, str, str, str | None]] = []
        for category, pattern in CALL_STARTS:
            for match in pattern.finditer(source):
                extracted = extract_call(source, match.start())
                if extracted is None:
                    continue
                expression, _ = extracted
                if is_raw(category, expression):
                    candidates.append((match.start(), category, expression, inline_exception_reason(source, match.start())))
        for start, category, expression, reason in sorted(candidates):
            provisional.append(
                Occurrence(
                    path=relative_path,
                    line=line_number(source, start),
                    category=category,
                    expression=expression,
                    normalized_expression=normalize_expression(expression),
                    ordinal=0,
                    exception_reason=reason,
                )
            )

    ordinals: Counter[tuple[str, str]] = Counter()
    occurrences: list[Occurrence] = []
    for occurrence in provisional:
        key = (occurrence.path, occurrence.normalized_expression)
        ordinals[key] += 1
        occurrences.append(
            Occurrence(
                path=occurrence.path,
                line=occurrence.line,
                category=occurrence.category,
                expression=occurrence.expression,
                normalized_expression=occurrence.normalized_expression,
                ordinal=ordinals[key],
                exception_reason=occurrence.exception_reason,
            )
        )
    return occurrences


def baseline_document(root: Path, baseline_commit: str, scan_roots: Iterable[str] = SCAN_ROOTS) -> dict:
    entries = scan(root, scan_roots)
    return {
        "schemaVersion": 1,
        "baselineCommit": baseline_commit,
        "scanRoots": list(scan_roots),
        "excludedFiles": sorted(EXCLUDED_FILES),
        "entries": [
            {
                "fingerprint": occurrence.fingerprint,
                "path": occurrence.path,
                "category": occurrence.category,
                "expression": occurrence.normalized_expression,
                "ordinal": occurrence.ordinal,
            }
            for occurrence in entries
        ],
    }


def write_baseline(root: Path, output: Path, baseline_commit: str, scan_roots: Iterable[str] = SCAN_ROOTS) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(baseline_document(root, baseline_commit, scan_roots), indent=2) + "\n", encoding="utf-8")


def load_baseline(path: Path) -> set[str]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise ValueError(f"Unsupported baseline schema in {path}")
    return {entry["fingerprint"] for entry in document.get("entries", [])}


def valid_exception(reason: str | None) -> bool:
    return reason is not None and reason.strip().lower() not in GENERIC_EXCEPTION_REASONS


def lint(root: Path, baseline_path: Path, scan_roots: Iterable[str] = SCAN_ROOTS) -> list[str]:
    known_fingerprints = load_baseline(baseline_path)
    failures: list[str] = []
    for occurrence in scan(root, scan_roots):
        if occurrence.fingerprint in known_fingerprints:
            continue
        if occurrence.exception_reason is not None:
            if valid_exception(occurrence.exception_reason):
                continue
            failures.append(
                f"{occurrence.path}:{occurrence.line}: invalid {EXCEPTION_MARKER} reason for {occurrence.category}; explain the component-specific constraint."
            )
            continue
        suggestion = {
            "font": "use PickyHUDTypography (or a documented SF Symbol optical-size exception)",
            "padding": "use DS.Spacing.space1...space8 or a documented component metric",
            "cornerRadius": "use DS.CornerRadius.compact/control/surface/panel or a documented component metric",
            "shadow": "use DS.Elevation or a documented component elevation token",
        }[occurrence.category]
        failures.append(
            f"{occurrence.path}:{occurrence.line}: new raw {occurrence.category}: {occurrence.normalized_expression}\n"
            f"  Suggested: {suggestion}. Add `// {EXCEPTION_MARKER} <specific reason>` only for a genuine component exception."
        )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--write-baseline", action="store_true")
    parser.add_argument("--baseline-commit", default="ce27595f")
    args = parser.parse_args()

    root = args.root.resolve()
    baseline = (args.baseline or root / BASELINE_PATH).resolve()
    if args.write_baseline:
        write_baseline(root, baseline, args.baseline_commit)
        return 0

    failures = lint(root, baseline)
    if failures:
        print("UI design-token guard failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("UI design-token guard passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

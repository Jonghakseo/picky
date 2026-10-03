#!/usr/bin/env python3
"""Reject new raw UI design values while preserving a committed legacy baseline.

The baseline stores stable fingerprints made from the repository-relative path,
normalized source expression, and that expression's occurrence ordinal. It never
uses line numbers, so moving legacy code does not invalidate the guard.
"""

from __future__ import annotations

import argparse
import hashlib
import inspect
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

SCAN_ROOTS = (
    "Picky/HUD",
    "Picky/QuickInput",
    "Picky/Companion",
    "Picky/App/Settings",
    "Picky/Overlay",
    # Settings/plugin UI that used to live under Picky/Companion, the main-agent
    # transcript store, and the dock layout model split out of Picky/HUD. They
    # stay in scope so a directory move cannot drop a file out of the guard.
    # (`Picky/PointerOverlay` moved under `Picky/Overlay`, which already covers it.)
    "Picky/Hub/Settings",
    "Picky/Hub/Plugins",
    "Picky/MainAgent",
    "Picky/Sessions/Dock",
)

# Files that moved after the baseline commit. A fingerprint is derived from the
# repository-relative path, so without this map a pure move would drop the
# file's legacy entries and re-report every occurrence as new. Mapping the
# current path back to the recorded one keeps the violation set identical
# without rewriting `design/ui-design-token-baseline.json`, so --verify-baseline
# still reproduces that file from the committed baseline tree.
#
# Only moved files that carry baseline debt belong here; `check_aliases` rejects
# an entry whose source is gone or whose target the baseline never recorded.
BASELINE_PATH_ALIASES = {
    "Picky/HUD/Archive/PickyHUDArchiveUndoToast.swift": "Picky/HUD/PickyHUDArchiveUndoToast.swift",
    "Picky/HUD/Artifacts/PickyReportViewer.swift": "Picky/HUD/PickyReportViewer.swift",
    "Picky/HUD/Artifacts/PickySessionChangesView.swift": "Picky/HUD/PickySessionChangesView.swift",
    "Picky/HUD/Dock/PickyDockGroupCreatorView.swift": "Picky/HUD/PickyDockGroupCreatorView.swift",
    "Picky/HUD/Dock/PickyHUDDockGroupViews.swift": "Picky/HUD/PickyHUDDockGroupViews.swift",
    "Picky/HUD/Dock/PickyHUDDockIconView.swift": "Picky/HUD/PickyHUDDockIconView.swift",
    "Picky/HUD/Dock/PickyRecentPickleFolderPicker.swift": "Picky/HUD/PickyRecentPickleFolderPicker.swift",
    "Picky/HUD/ToolHistory/PickyToolActivityRow.swift": "Picky/HUD/PickyToolActivityRow.swift",
    "Picky/HUD/ToolHistory/PickyToolJSONResultView.swift": "Picky/HUD/PickyToolJSONResultView.swift",
    "Picky/Hub/Plugins/CompanionPanelExtensionsView.swift": "Picky/Companion/CompanionPanelExtensionsView.swift",
    "Picky/Hub/Settings/CompanionPanelExtensionsSection.swift": "Picky/Companion/CompanionPanelExtensionsSection.swift",
    "Picky/Hub/Settings/CompanionPanelMessagesView.swift": "Picky/Companion/CompanionPanelMessagesView.swift",
    "Picky/Hub/Settings/CompanionPanelPrerequisitesView.swift": "Picky/Companion/CompanionPanelPrerequisitesView.swift",
    "Picky/Hub/Settings/CompanionPanelSettingsView.swift": "Picky/Companion/CompanionPanelSettingsView.swift",
    "Picky/Hub/Settings/PickyMainAgentTranscriptRow.swift": "Picky/Companion/PickyMainAgentTranscriptRow.swift",
}
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
    baseline_path: str = ""

    @property
    def fingerprint(self) -> str:
        path = self.baseline_path or self.path
        payload = f"{path}\0{self.normalized_expression}\0{self.ordinal}".encode()
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


def scan(
    root: Path,
    scan_roots: Iterable[str] = SCAN_ROOTS,
    aliases: dict[str, str] | None = None,
) -> list[Occurrence]:
    aliases = BASELINE_PATH_ALIASES if aliases is None else aliases
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
                    baseline_path=aliases.get(relative_path, relative_path),
                )
            )

    ordinals: Counter[tuple[str, str]] = Counter()
    occurrences: list[Occurrence] = []
    for occurrence in provisional:
        key = (occurrence.baseline_path, occurrence.normalized_expression)
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
                baseline_path=occurrence.baseline_path,
            )
        )
    return occurrences


def baseline_document(root: Path, baseline_commit: str, scan_roots: Iterable[str] = SCAN_ROOTS) -> dict:
    # The baseline is always generated from the committed baseline tree, where
    # the pre-move paths are the real ones. Aliases must never reach it, or
    # --verify-baseline would start depending on today's directory layout.
    entries = scan(root, scan_roots, aliases={})
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


def extract_git_archive(archive: tarfile.TarFile, destination: Path) -> None:
    if "filter" in inspect.signature(archive.extractall).parameters:
        archive.extractall(destination, filter="data")
        return

    # Python 3.9 lacks extraction filters. This archive comes directly from a
    # verified local Git commit, so its member names are constrained by Git.
    archive.extractall(destination)


@contextmanager
def committed_tree(root: Path, baseline_commit: str) -> Iterator[Path]:
    """Materialize exactly one committed Git tree, never the working tree."""
    resolved = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--verify", f"{baseline_commit}^{{commit}}"],
        capture_output=True,
        text=True,
    )
    if resolved.returncode != 0:
        detail = resolved.stderr.strip() or resolved.stdout.strip() or "unknown Git error"
        raise ValueError(f"Unable to resolve baseline commit {baseline_commit!r}: {detail}")

    archived = subprocess.run(
        ["git", "-C", str(root), "archive", "--format=tar", baseline_commit],
        capture_output=True,
    )
    if archived.returncode != 0:
        detail = archived.stderr.decode().strip() or "unknown Git error"
        raise ValueError(f"Unable to read baseline commit {baseline_commit!r}: {detail}")

    with tempfile.TemporaryDirectory(prefix="picky-ui-token-baseline-") as temporary:
        tree = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archived.stdout), mode="r:") as archive:
            extract_git_archive(archive, tree)
        yield tree


def baseline_document_for_commit(root: Path, baseline_commit: str, scan_roots: Iterable[str] = SCAN_ROOTS) -> dict:
    with committed_tree(root, baseline_commit) as tree:
        return baseline_document(tree, baseline_commit, scan_roots)


def write_baseline(root: Path, output: Path, baseline_commit: str, scan_roots: Iterable[str] = SCAN_ROOTS) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    document = baseline_document_for_commit(root, baseline_commit, scan_roots)
    output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def verify_baseline(root: Path, baseline_path: Path, baseline_commit: str) -> None:
    actual = json.loads(baseline_path.read_text(encoding="utf-8"))
    declared_commit = actual.get("baselineCommit")
    if declared_commit != baseline_commit:
        raise ValueError(
            f"Baseline declares {declared_commit!r}, but verification requested {baseline_commit!r}."
        )
    scan_roots = tuple(actual.get("scanRoots", ()))
    expected = baseline_document_for_commit(root, baseline_commit, scan_roots)
    if actual != expected:
        raise ValueError(
            f"Baseline provenance mismatch: {baseline_path} does not match committed tree {baseline_commit}. "
            "Regenerate it with --write-baseline."
        )


def load_baseline(path: Path) -> set[str]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise ValueError(f"Unsupported baseline schema in {path}")
    return {entry["fingerprint"] for entry in document.get("entries", [])}


def check_aliases(
    root: Path,
    baseline_path: Path,
    aliases: dict[str, str],
    scan_roots: Iterable[str] = SCAN_ROOTS,
) -> list[str]:
    """Reject aliases that no longer describe a real move of real baseline debt.

    An alias only does its job while the guard still reads the file it names. If
    the file moved again, moved out of SCAN_ROOTS, or became excluded, the alias
    silently stops mattering and the file's legacy debt leaves the guard with it,
    so every one of those states is a failure here.
    """
    document = json.loads(baseline_path.read_text(encoding="utf-8"))
    recorded_paths = {entry["path"] for entry in document.get("entries", [])}
    scanned_paths = {path.relative_to(root).as_posix() for path in paths_for(root, scan_roots)}
    repoint = "Point the alias at the file's current path and widen SCAN_ROOTS to cover it. Deleting the alias instead takes this file's legacy debt out of the guard."
    failures: list[str] = []
    for current, recorded in sorted(aliases.items()):
        if not (root / current).is_file():
            failures.append(f"{current}: aliased to {recorded} but the file no longer exists there. {repoint}")
        elif current not in scanned_paths:
            failures.append(
                f"{current}: aliased to {recorded} but the guard does not scan that path "
                f"(outside SCAN_ROOTS or in EXCLUDED_FILES), so the alias covers nothing. {repoint}"
            )
        if recorded not in recorded_paths:
            failures.append(
                f"{current}: aliased to {recorded}, which {baseline_path.name} never recorded; "
                "name the baseline path this file's entries were actually recorded under, or drop the alias "
                "if the file carries no baseline debt."
            )
    return failures


def valid_exception(reason: str | None) -> bool:
    return reason is not None and reason.strip().lower() not in GENERIC_EXCEPTION_REASONS


def lint(
    root: Path,
    baseline_path: Path,
    scan_roots: Iterable[str] = SCAN_ROOTS,
    aliases: dict[str, str] | None = None,
) -> list[str]:
    known_fingerprints = load_baseline(baseline_path)
    failures: list[str] = []
    for occurrence in scan(root, scan_roots, aliases):
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
    parser.add_argument("--verify-baseline", action="store_true")
    parser.add_argument("--baseline-commit", default="ce27595f")
    args = parser.parse_args()

    root = args.root.resolve()
    baseline = (args.baseline or root / BASELINE_PATH).resolve()
    if args.write_baseline and args.verify_baseline:
        parser.error("--write-baseline and --verify-baseline are mutually exclusive")

    try:
        if args.write_baseline:
            write_baseline(root, baseline, args.baseline_commit)
            return 0
        if args.verify_baseline:
            verify_baseline(root, baseline, args.baseline_commit)
            print("UI design-token baseline provenance verified.")
            return 0
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"UI design-token baseline error: {error}", file=sys.stderr)
        return 1

    failures = check_aliases(root, baseline, BASELINE_PATH_ALIASES) + lint(root, baseline)
    if failures:
        print("UI design-token guard failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("UI design-token guard passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate the Picky design guide skill's canonical document dependencies."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REQUIRED_DOCS = {
    "design/DESIGN.md": ("# Picky Design System", "## 3. Sources of truth"),
    "design/PRINCIPLES.md": ("# Picky Design Principles",),
    "design/TOKENS.md": ("# Picky Design Tokens", "## Color", "## Typography"),
    "design/COMPONENTS.md": ("# Picky Component System",),
    "design/AUDIT.md": ("# Picky Design Audit", "## Criteria", "## Severity"),
    "design/references/APPLE-HIG.md": ("# Apple Platform Design References",),
    "design/references/DESIGN-apple.md": ("## Overview",),
}

MARKDOWN_LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def find_repo_root(start: Path) -> Path | None:
    for candidate in (start, *start.parents):
        if (candidate / "AGENTS.md").exists() and (candidate / "design/DESIGN.md").exists():
            return candidate
    return None


def validate_local_links(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    for target in MARKDOWN_LINK_RE.findall(text):
        if "://" in target or target.startswith(("#", "mailto:")):
            continue
        local = target.split("#", 1)[0]
        if local and not (path.parent / local).resolve().exists():
            errors.append(f"{path}: missing local link {target}")
    return errors


def main() -> int:
    script_path = Path(__file__).resolve()
    repo_root = find_repo_root(script_path.parent)
    if repo_root is None:
        print("ERROR: could not locate the Picky repository root", file=sys.stderr)
        return 1

    errors: list[str] = []
    for relative, headings in REQUIRED_DOCS.items():
        path = repo_root / relative
        if not path.exists():
            errors.append(f"missing required document: {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        for heading in headings:
            if heading not in text:
                errors.append(f"{relative}: missing required heading {heading!r}")
        errors.extend(validate_local_links(path))

    skill_root = script_path.parent.parent
    for relative in (
        "SKILL.md",
        "references/doc-map.md",
        "references/review-templates.md",
        "evals/evals.json",
    ):
        if not (skill_root / relative).exists():
            errors.append(f"missing skill resource: {relative}")

    if errors:
        print("Picky design guide validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Picky design guide validation passed: {repo_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

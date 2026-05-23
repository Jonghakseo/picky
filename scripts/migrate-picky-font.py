#!/usr/bin/env python3
"""
Mass-migrate `.font(.system(size: N, ...))` -> `.pickyFont(size: N, ...)` for the
HUD/Conversation/Bubbles/Report (PR-1) and Companion/Settings/Feedback/ShortcutSettings
(PR-2) scopes only.

Rules:
- Only literal-number `size:` arguments are rewritten. Variable/expression sizes
  (e.g. `size: secondaryFontSize`, `size: max(6.5, 7.5 * metrics.scale)`,
  `size: scaled(Self.bodyBaseSize)`) are left alone so they keep their own
  layout-driven scaling logic.
- `.font(.system(.title))` style enum sizes are not touched (we don't use them).
- The script is idempotent — running twice is a no-op.

Usage:
    scripts/migrate-picky-font.py --pr 1
    scripts/migrate-picky-font.py --pr 2
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PR1_FILES = [
    # HUD root
    "Picky/HUD/PickyHUDView.swift",
    "Picky/HUD/PickyHUDArchiveUndoToast.swift",
    "Picky/HUD/PickyToolHistoryViewer.swift",
    "Picky/HUD/PickyToolActivityRow.swift",
    # Conversation
    "Picky/HUD/Conversation/PickyConversationComposerView.swift",
    "Picky/HUD/Conversation/PickyInlineTerminalCardView.swift",
    "Picky/HUD/Conversation/PickyConversationContextLineView.swift",
    "Picky/HUD/Conversation/PickyConversationHeaderView.swift",
    "Picky/HUD/Conversation/PickyConversationListView.swift",
    "Picky/HUD/Conversation/PickyHUDArchivedSessionsListView.swift",
    "Picky/HUD/Conversation/PickySessionTerminalAddonView.swift",
    "Picky/HUD/Conversation/PickyTurnCardView.swift",
    # Bubbles
    "Picky/HUD/Conversation/Bubbles/PickyQuestionBubbleView.swift",
    "Picky/HUD/Conversation/Bubbles/PickyCompactStatusViews.swift",
    "Picky/HUD/Conversation/Bubbles/PickyConversationMarkdownText.swift",
    "Picky/HUD/Conversation/Bubbles/PickyErrorBubbleView.swift",
    "Picky/HUD/Conversation/Bubbles/PickyActivitySummaryView.swift",
    "Picky/HUD/Conversation/Bubbles/PickyTerminalSyncBanner.swift",
    "Picky/HUD/Conversation/Bubbles/PickyToolCallInlineRow.swift",
    "Picky/HUD/Conversation/Bubbles/PickyAgentBubbleView.swift",
    "Picky/HUD/Conversation/Bubbles/PickyTypingBubbleView.swift",
    "Picky/HUD/Conversation/Bubbles/PickyBatchGroupView.swift",
    "Picky/HUD/Conversation/Bubbles/PickyOpenAsReportHoverIcon.swift",
    "Picky/HUD/Conversation/Bubbles/PickyPendingBubbleView.swift",
    # Report
    "Picky/HUD/PickyReportViewer.swift",
]

PR2_FILES = [
    # Companion
    "Picky/CompanionPanelView.swift",
    "Picky/Companion/CompanionPanelSettingsView.swift",
    "Picky/Companion/CompanionPanelPrerequisitesView.swift",
    "Picky/Companion/CompanionPanelStatusView.swift",
    "Picky/Companion/CompanionPanelMessagesView.swift",
    "Picky/Companion/CompanionPanelExtensionsSection.swift",
    "Picky/Companion/CompanionPanelFooterView.swift",
    "Picky/Companion/CompanionPanelHeaderView.swift",
    "Picky/Companion/Onboarding/OnboardingSkipPanelController.swift",
    "Picky/Companion/Onboarding/OnboardingHighlightViewerPanelController.swift",
    # Feedback (sits inside the Companion panel as a sheet)
    "Picky/Feedback/CompanionPanelFeedbackView.swift",
    # Shortcuts settings (rendered inside the Companion settings view)
    "Picky/Shortcuts/ShortcutSettingsViews.swift",
]

# Matches `.font(.system(size: <NUMBER>[, weight: ...][ , design: ...]))`
# where <NUMBER> is a decimal literal. Captures the entire inner argument string
# after `size: <NUMBER>` so we can preserve weight/design tail verbatim.
FONT_PATTERN = re.compile(
    r"\.font\(\.system\(size:\s*(\d+(?:\.\d+)?)((?:,\s*[^()]*)?)\)\)"
)


def migrate_file(path: Path) -> int:
    text = path.read_text()
    new_text, count = FONT_PATTERN.subn(
        lambda m: f".pickyFont(size: {m.group(1)}{m.group(2)})",
        text,
    )
    if count > 0 and new_text != text:
        path.write_text(new_text)
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pr", type=int, choices=[1, 2], required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    files = PR1_FILES if args.pr == 1 else PR2_FILES
    total = 0
    for rel in files:
        path = ROOT / rel
        if not path.exists():
            print(f"  ! missing: {rel}", file=sys.stderr)
            continue
        if args.dry_run:
            text = path.read_text()
            count = len(FONT_PATTERN.findall(text))
        else:
            count = migrate_file(path)
        if count:
            print(f"  {count:>3}  {rel}")
        total += count
    print(f"\nPR-{args.pr}: {total} sites { 'would be' if args.dry_run else '' } migrated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

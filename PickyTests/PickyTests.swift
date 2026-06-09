//
//  PickyTests.swift
//  PickyTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func screenRecordingRequestHasNoSideEffectInUnitTests() async throws {
        #expect(PickyRuntimeEnvironment.isRunningUnitTests)

        let presentationDestination = WindowPositionManager.requestScreenRecordingPermission()

        #expect(presentationDestination == .alreadyGranted || presentationDestination == .systemPrompt)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func bubbleLayoutUsesContentWidthUntilMaximum() throws {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let maxWidth: CGFloat = 302
        let shortWidth = PickyBubbleLayout.textWidth(for: "OK", font: font, maxWidth: maxWidth)
        let longWidth = PickyBubbleLayout.textWidth(
            for: "This is a deliberately long response that should hit the maximum bubble width.",
            font: font,
            maxWidth: maxWidth
        )

        #expect(shortWidth > 0)
        #expect(shortWidth < 80)
        #expect(longWidth == maxWidth)
    }

    @Test func conversationBubbleWidthFitsInsideDetailContentColumn() throws {
        let contentWidth = PickyHUDDockLayout.detailContentWidth
        let bubbleWidth = PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: PickyHUDDockLayout.detailWidth)
        let occupiedWidth = bubbleWidth
            + PickyConversationBubbleLayout.oppositeSideReserve
            + PickyConversationBubbleLayout.horizontalStackSpacing

        #expect(bubbleWidth == contentWidth * PickyConversationBubbleLayout.defaultMaxWidthFraction)
        #expect(occupiedWidth <= contentWidth)
        #expect(bubbleWidth < PickyHUDDockLayout.detailWidth * PickyConversationBubbleLayout.defaultMaxWidthFraction)
    }

    @Test func conversationBubbleWidthKeepsReserveOnNarrowColumns() throws {
        let detailWidth: CGFloat = 120
        let contentWidth = PickyConversationBubbleLayout.contentWidth(forDetailWidth: detailWidth)
        let bubbleWidth = PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: detailWidth)
        let occupiedWidth = bubbleWidth
            + PickyConversationBubbleLayout.oppositeSideReserve
            + PickyConversationBubbleLayout.horizontalStackSpacing

        #expect(occupiedWidth <= contentWidth)
    }

    @Test func bubbleMarkdownRendersEmphasisWithoutRawDelimiters() throws {
        let attributed = PickyBubbleMarkdown.attributedText(for: "이건 **중요**해요")

        #expect(String(attributed.characters) == "이건 중요해요")
        #expect(PickyBubbleMarkdown.displayString(for: "이건 **중요**해요") == "이건 중요해요")
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    // MARK: - Cursor response bubble truncation
    //
    // Regression coverage for the cursor-following companion response bubble. The previous
    // implementation declared `.lineLimit(N)` on the SwiftUI Text, but the host panel sized
    // itself from `NSHostingView.fittingSize`, which ignored that cap on multi-paragraph
    // AttributedStrings and let the bubble grow to 30+ lines (user-reported regression on
    // 2026-05-24). The pre-truncation + `maxBubbleHeight()` cap below is the source of truth
    // both the SwiftUI view and the panel sizing path consult, so we lock down both helpers.

    @Test func truncatedAttributedTextLeavesShortContentUntouched() throws {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let source = PickyBubbleMarkdown.attributedText(for: "짧은 응답입니다.")
        let truncated = PickyBubbleLayout.truncatedAttributedText(
            source,
            font: font,
            lineSpacing: 3,
            width: 300,
            maxLines: 16
        )

        // Single-line content fits well within the budget, so the helper must round-trip
        // the AttributedString unchanged — no trailing ellipsis, no character loss.
        #expect(String(truncated.characters) == "짧은 응답입니다.")
        #expect(!String(truncated.characters).hasSuffix("\u{2026}"))
    }

    @Test func truncatedAttributedTextCapsLongContentAtVisibleLineBudget() throws {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let lineSpacing: CGFloat = 3
        let width: CGFloat = 300
        // 30 short paragraphs separated by blank lines — mirrors the user-reported scenario
        // where the bubble swelled to dozens of lines despite `.lineLimit(N)`.
        let paragraphs = (1...30).map { "단락 \($0): 이것은 몇 줄 이상이 될 수 있는 긴 한국어 문장입니다." }
        let longText = paragraphs.joined(separator: "\n\n")
        let source = PickyBubbleMarkdown.attributedText(for: longText)

        let truncated = PickyBubbleLayout.truncatedAttributedText(
            source,
            font: font,
            lineSpacing: lineSpacing,
            width: width,
            maxLines: 16
        )

        // The truncated text must end in an ellipsis to signal that content was dropped.
        #expect(String(truncated.characters).hasSuffix("\u{2026}"))
        // It must also be strictly shorter than the source so we know content was actually
        // removed (not just the ellipsis appended).
        #expect(truncated.characters.count < source.characters.count)
        // And the visible-line count for the truncated string must respect the 16-line cap.
        let visibleLines = PickyBubbleLayout.visualLineCount(
            truncated,
            font: font,
            lineSpacing: lineSpacing,
            width: width
        )
        #expect(visibleLines <= 16)
    }

    @Test func truncatedAttributedTextHandlesWrappedSingleParagraph() throws {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let lineSpacing: CGFloat = 3
        let width: CGFloat = 300
        // A single long paragraph that wraps many times — confirms the cap is measured
        // against visual (wrapped) lines, not logical newlines.
        let longParagraph = String(repeating: "단어 ", count: 400)
        let source = PickyBubbleMarkdown.attributedText(for: longParagraph)

        let truncated = PickyBubbleLayout.truncatedAttributedText(
            source,
            font: font,
            lineSpacing: lineSpacing,
            width: width,
            maxLines: 16
        )

        let visibleLines = PickyBubbleLayout.visualLineCount(
            truncated,
            font: font,
            lineSpacing: lineSpacing,
            width: width
        )
        #expect(visibleLines <= 16)
        #expect(String(truncated.characters).hasSuffix("\u{2026}"))
    }

    @Test func maxBubbleHeightScalesWithLineLimit() throws {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let oneLine = PickyBubbleLayout.maxBubbleHeight(font: font, lineSpacing: 3, maxLines: 1, verticalPadding: 10)
        let eightLines = PickyBubbleLayout.maxBubbleHeight(font: font, lineSpacing: 3, maxLines: 8, verticalPadding: 10)
        let sixteenLines = PickyBubbleLayout.maxBubbleHeight(font: font, lineSpacing: 3, maxLines: 16, verticalPadding: 10)

        // Adding lines must monotonically grow the budget so the panel-sizing cap stays
        // consistent with the line-limit knob.
        #expect(oneLine < eightLines)
        #expect(eightLines < sixteenLines)
        // The cap is symmetric padding plus N line heights plus (N-1) line gaps; the
        // delta between 8 and 16 lines must equal the delta between 1 and 9 lines.
        let nineLines = PickyBubbleLayout.maxBubbleHeight(font: font, lineSpacing: 3, maxLines: 9, verticalPadding: 10)
        let deltaEightToSixteen = sixteenLines - eightLines
        let deltaOneToNine = nineLines - oneLine
        #expect(abs(deltaEightToSixteen - deltaOneToNine) <= 1)
    }

    @Test func hudExpansionPolicyKeepsCollapseAndMeasuredExpansionSemantics() throws {
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: false, measuredHeight: 72) == 0)
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: true, measuredHeight: 72) == 72)
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: true, measuredHeight: 0) == nil)
        #expect(PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 200, targetHeight: 180, deferShrink: true))
        #expect(!PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 200, targetHeight: 180, deferShrink: false))
    }

    @Test func dockAddSlotUsesCompactCollapsedHitAreaAndReservesPanelRoomOnly() throws {
        let smallMetrics = PickyHUDDockMetrics(preset: .small)
        let mediumMetrics = PickyHUDDockMetrics(preset: .medium)
        let largeMetrics = PickyHUDDockMetrics(preset: .large)
        #expect(PickyHUDDockLayout.addSlotFrameHeight(isExpanded: false) == mediumMetrics.collapsedAddSlotVisualHeight)
        #expect(PickyHUDDockLayout.addSlotFrameHeight(isExpanded: true) == mediumMetrics.addSlotButtonSide)
        #expect(PickyHUDDockLayout.addSlotCollapsedExpansionReserve == mediumMetrics.addSlotButtonSide - mediumMetrics.collapsedAddSlotVisualHeight)

        #expect(largeMetrics.railWidth == PickyHUDDockLayout.railWidth)
        #expect(largeMetrics.addSlotButtonSide == PickyHUDDockLayout.addSlotButtonSide)
        #expect(smallMetrics.railWidth < mediumMetrics.railWidth)
        #expect(mediumMetrics.railWidth < largeMetrics.railWidth)
        #expect(PickyHUDDockLayout.addSlotFrameHeight(isExpanded: false, metrics: smallMetrics) == smallMetrics.collapsedAddSlotVisualHeight)
        #expect(PickyHUDDockLayout.addSlotFrameHeight(isExpanded: true, metrics: largeMetrics) == largeMetrics.addSlotButtonSide)

        #expect(PickyHUDDockLayout.dockRailSessionsHeight(sessionCount: 0, isAddSlotExpanded: false, metrics: mediumMetrics) == mediumMetrics.addSlotButtonSide)
        #expect(PickyHUDDockLayout.dockRailSessionsHeight(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics) ==
            (3 * mediumMetrics.sessionTileHeight) + (2 * mediumMetrics.sessionSpacing) + mediumMetrics.addSlotTopPadding + mediumMetrics.collapsedAddSlotVisualHeight
        )
        #expect(PickyHUDDockLayout.dockRailHeight(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics) ==
            mediumMetrics.topPadding + mediumMetrics.handleAreaHeight + 2 + PickyHUDDockLayout.dockRailSessionsHeight(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics) + mediumMetrics.bottomPadding
        )
        #expect(PickyHUDDockLayout.dockRailHeight(sessionCount: 3, isAddSlotExpanded: true, metrics: mediumMetrics) - PickyHUDDockLayout.dockRailHeight(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics) == mediumMetrics.addSlotCollapsedExpansionReserve)
        #expect(PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: 3) == CGFloat(3) * (PickyHUDDockGroupHeaderHeight + PickyHUDDockGroupContentSpacing))
        #expect(PickyHUDDockLayout.horizontalDockRailCrossSize(hasGroupHeaders: true, metrics: mediumMetrics) == mediumMetrics.railWidth + PickyHUDDockGroupHeaderHeight + PickyHUDDockGroupContentSpacing)

        let horizontalSessionsAndSlot = (3 * mediumMetrics.sessionTileWidth) + (2 * mediumMetrics.sessionSpacing) + 2 + mediumMetrics.collapsedAddSlotVisualHeight
        #expect(PickyHUDDockLayout.horizontalDockRailLength(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics) ==
            mediumMetrics.topPadding + mediumMetrics.handleAreaHeight + 2 + PickyHUDDockLayout.fullscreenDockControlLength(metrics: mediumMetrics) + horizontalSessionsAndSlot + mediumMetrics.topPadding
        )

        #expect(PickyHUDDockLayout.contentSizeReservingAddSlotExpansion(
            measuredSize: CGSize(width: 50, height: 120),
            activeSessionID: nil,
            hasVisibleSessions: true,
            isAddSlotExpanded: false
        ) == CGSize(width: 50, height: 120 + PickyHUDDockLayout.addSlotCollapsedExpansionReserve))
        #expect(PickyHUDDockLayout.contentSizeReservingAddSlotExpansion(
            measuredSize: CGSize(width: 50, height: 120),
            activeSessionID: nil,
            hasVisibleSessions: true,
            isAddSlotExpanded: true
        ) == CGSize(width: 50, height: 120))
        #expect(PickyHUDDockLayout.contentSizeReservingAddSlotExpansion(
            measuredSize: CGSize(width: 50, height: 120),
            activeSessionID: "session",
            hasVisibleSessions: true,
            isAddSlotExpanded: false
        ) == CGSize(width: 50, height: 120))
    }

    @Test func hudDockLabelCompactsByVisibleDisplayWidth() throws {
        #expect(PickyHUDDockLabelPolicy.compactLabel("ct-cli 부하 개선") == "ct-cli")
        #expect(PickyHUDDockLabelPolicy.compactLabel("부하개선작업") == "부하개선")
        #expect(PickyHUDDockLabelPolicy.compactLabel("login fix") == "loginf")
        #expect(PickyHUDDockLabelPolicy.compactLabel("예약API개선") == "예약API")
        #expect(PickyHUDDockLabelPolicy.compactLabel("   ") == "Pickle")
    }

    @Test func quickInputPanelUsesCompactShadowOutset() throws {
        #expect(QuickInputPanelLayout.mainShadowOpacity == 0.08)
        #expect(QuickInputPanelLayout.mainShadowRadius == 4)
        #expect(QuickInputPanelLayout.mainShadowYOffset == 2)
        #expect(QuickInputPanelLayout.tightShadowOpacity == 0.04)
        #expect(QuickInputPanelLayout.tightShadowRadius == 0.8)
        #expect(QuickInputPanelLayout.tightShadowYOffset == 0.3)
        #expect(QuickInputPanelLayout.shadowOutset == QuickInputPanelLayout.mainShadowRadius + abs(QuickInputPanelLayout.mainShadowYOffset))
        #expect(QuickInputPanelLayout.panelWidth == QuickInputPanelLayout.pillWidth + QuickInputPanelLayout.shadowOutset * 2)
        #expect(QuickInputPanelLayout.estimatedPanelHeight == QuickInputPanelLayout.capsuleHeight + QuickInputPanelLayout.shadowOutset * 2)
    }

    @Test func archiveUndoToastLayoutPinsToScreenBottomRight() throws {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1440, height: 900)
        let panelSize = CGSize(width: 304, height: 78)

        let frame = PickyHUDArchiveUndoToastLayout.panelFrame(visibleFrame: visibleFrame, panelSize: panelSize)

        #expect(frame.origin.x == visibleFrame.maxX - panelSize.width - PickyHUDArchiveUndoToastPolicy.screenMargin)
        #expect(frame.origin.y == visibleFrame.minY + PickyHUDArchiveUndoToastPolicy.screenMargin)
        #expect(frame.size == panelSize)
    }

    @Test func archiveHoldFeedbackStartsAfterShortGracePeriod() throws {
        #expect(PickyHUDArchiveHoldPolicy.feedbackStartDelay == 0.2)
        #expect(PickyHUDArchiveHoldPolicy.feedbackStartDelayNanoseconds == 200_000_000)
        #expect(PickyHUDArchiveHoldPolicy.feedbackAnimationDuration == PickyHUDArchiveHoldPolicy.duration - PickyHUDArchiveHoldPolicy.feedbackStartDelay)
    }

    @Test func pushToTalkShortcutKeepsControlOptionTransitionSemantics() throws {
        let controlOptionFlags: NSEvent.ModifierFlags = [.control, .option]
        let spec = PickyShortcutSpec.defaultPushToTalk

        #expect(BuddyPushToTalkShortcut.displayText(for: spec) == "control + option")
        #expect(BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(controlOptionFlags.rawValue),
            wasShortcutPreviouslyPressed: false,
            spec: spec
        ) == .pressed)
        #expect(BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: 0,
            wasShortcutPreviouslyPressed: true,
            spec: spec
        ) == .released)
    }

    @Test func elevenLabsTTSDefaultsToMultilingualV2Model() throws {
        let configuration = ElevenLabsSpeechConfiguration(apiKey: "test-key", voiceID: "test-voice")

        #expect(configuration.modelID == "eleven_multilingual_v2")
    }

    @Test func elevenLabsTTSMigratesPreviousTurboDefaultToMultilingualV2Model() throws {
        let configuration = ElevenLabsSpeechConfiguration(
            apiKey: "test-key",
            voiceID: "test-voice",
            modelID: " eleven_turbo_v2 "
        )

        #expect(configuration.modelID == "eleven_multilingual_v2")
    }

    @Test func elevenLabsTTSKeepsExplicitNonLegacyModelID() throws {
        let configuration = ElevenLabsSpeechConfiguration(
            apiKey: "test-key",
            voiceID: "test-voice",
            modelID: "eleven_flash_v2_5"
        )

        #expect(configuration.modelID == "eleven_flash_v2_5")
    }

}

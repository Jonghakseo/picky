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

    @Test func narrativeBubbleWidthKeepsRelativeWidthBelowReadingCap() throws {
        let detailWidth: CGFloat = 800
        let structuredWidth = PickyConversationBubbleLayout.maxBubbleWidth(
            forDetailWidth: detailWidth,
            contentKind: .structured
        )
        let narrativeWidth = PickyConversationBubbleLayout.maxBubbleWidth(
            forDetailWidth: detailWidth,
            contentKind: .narrative
        )

        #expect(structuredWidth < PickyConversationBubbleLayout.narrativeMaxWidth)
        #expect(narrativeWidth == structuredWidth)
    }

    @Test func narrativeBubbleWidthClampsAtReadingCapOnWideCards() throws {
        let detailWidth: CGFloat = 1_400
        let structuredWidth = PickyConversationBubbleLayout.maxBubbleWidth(
            forDetailWidth: detailWidth,
            contentKind: .structured
        )
        let narrativeWidth = PickyConversationBubbleLayout.maxBubbleWidth(
            forDetailWidth: detailWidth,
            contentKind: .narrative
        )

        #expect(structuredWidth > PickyConversationBubbleLayout.narrativeMaxWidth)
        #expect(narrativeWidth == PickyConversationBubbleLayout.narrativeMaxWidth)
    }

    @Test func bubbleContentKindPreservesWidthForCodeAndTables() throws {
        #expect(PickyConversationBubbleLayout.contentKind(for: "Narrative prose") == .narrative)
        #expect(PickyConversationBubbleLayout.contentKind(for: "```swift\nlet width = 720\n```") == .structured)
        #expect(PickyConversationBubbleLayout.contentKind(for: "| Name | Value |\n| --- | --- |\n| width | 720 |") == .structured)
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
        #expect(smallMetrics.railWidth < mediumMetrics.railWidth)
        #expect(mediumMetrics.railWidth < largeMetrics.railWidth)

        for metrics in [smallMetrics, mediumMetrics, largeMetrics] {
            let collapsed = PickyHUDDockLayout.addSlotFrameHeight(isExpanded: false, metrics: metrics)
            let expanded = PickyHUDDockLayout.addSlotFrameHeight(isExpanded: true, metrics: metrics)
            // Collapsed slot keeps a compact hit area; expanding claims exactly the
            // room the reserve promised to the panel.
            #expect(collapsed < expanded)
            #expect(metrics.addSlotCollapsedExpansionReserve == expanded - collapsed)
        }
        #expect(PickyHUDDockLayout.addSlotFrameHeight(isExpanded: false) == PickyHUDDockLayout.addSlotFrameHeight(isExpanded: false, metrics: mediumMetrics))
        #expect(PickyHUDDockLayout.addSlotCollapsedExpansionReserve == mediumMetrics.addSlotCollapsedExpansionReserve)

        // An empty dock still reserves full room for the add button.
        #expect(PickyHUDDockLayout.dockRailSessionsHeight(sessionCount: 0, isAddSlotExpanded: false, metrics: mediumMetrics) == mediumMetrics.addSlotButtonSide)
        // Each additional session grows the rail by exactly one tile plus one gap,
        // in both orientations, and the rail chrome around the sessions stays fixed.
        let sessionsThree = PickyHUDDockLayout.dockRailSessionsHeight(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics)
        let sessionsFour = PickyHUDDockLayout.dockRailSessionsHeight(sessionCount: 4, isAddSlotExpanded: false, metrics: mediumMetrics)
        #expect(sessionsFour - sessionsThree == mediumMetrics.sessionTileHeight + mediumMetrics.sessionSpacing)
        let railThree = PickyHUDDockLayout.dockRailHeight(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics)
        let railFour = PickyHUDDockLayout.dockRailHeight(sessionCount: 4, isAddSlotExpanded: false, metrics: mediumMetrics)
        #expect(railFour - railThree == sessionsFour - sessionsThree)
        #expect(railThree > sessionsThree)
        let horizontalThree = PickyHUDDockLayout.horizontalDockRailLength(sessionCount: 3, isAddSlotExpanded: false, metrics: mediumMetrics)
        let horizontalFour = PickyHUDDockLayout.horizontalDockRailLength(sessionCount: 4, isAddSlotExpanded: false, metrics: mediumMetrics)
        #expect(horizontalFour - horizontalThree == mediumMetrics.sessionTileWidth + mediumMetrics.sessionSpacing)

        // Expanding the add slot grows the rail by the reserve and nothing else.
        #expect(PickyHUDDockLayout.dockRailHeight(sessionCount: 3, isAddSlotExpanded: true, metrics: mediumMetrics) - railThree == mediumMetrics.addSlotCollapsedExpansionReserve)
        #expect(PickyHUDDockLayout.horizontalDockRailLength(sessionCount: 3, isAddSlotExpanded: true, metrics: mediumMetrics) - horizontalThree == mediumMetrics.addSlotCollapsedExpansionReserve)

        // Group headers add a fixed per-header length, and the horizontal cross
        // size grows by exactly that one-header extra when headers are present.
        #expect(PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: 0) == 0)
        #expect(PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: 3) == 3 * PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: 1))
        #expect(PickyHUDDockLayout.horizontalDockRailCrossSize(hasGroupHeaders: false, metrics: mediumMetrics) == mediumMetrics.railWidth)
        #expect(PickyHUDDockLayout.horizontalDockRailCrossSize(hasGroupHeaders: true, metrics: mediumMetrics) - PickyHUDDockLayout.horizontalDockRailCrossSize(hasGroupHeaders: false, metrics: mediumMetrics) == PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: 1))

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

    @Test func quickInputPanelReservesRoomForItsShadows() throws {
        // The panel frame must enclose the pill plus the shadow outset on every
        // side, and the outset must cover both shadows' blur and vertical offset,
        // so no shadow gets clipped at the panel edge.
        let outset = QuickInputPanelLayout.shadowOutset
        #expect(outset >= QuickInputPanelLayout.mainShadowRadius + abs(QuickInputPanelLayout.mainShadowYOffset))
        #expect(outset >= QuickInputPanelLayout.tightShadowRadius + abs(QuickInputPanelLayout.tightShadowYOffset))
        #expect(QuickInputPanelLayout.panelWidth >= QuickInputPanelLayout.pillWidth + outset * 2)
        #expect(QuickInputPanelLayout.estimatedPanelHeight >= QuickInputPanelLayout.capsuleHeight + outset * 2)
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
        // The grace delay must sit strictly inside the hold duration so feedback
        // both starts and still has time to animate before the hold commits.
        #expect(PickyHUDArchiveHoldPolicy.feedbackStartDelay > 0)
        #expect(PickyHUDArchiveHoldPolicy.feedbackStartDelay < PickyHUDArchiveHoldPolicy.duration)
        // The nanosecond constant feeds Task.sleep and must agree with the
        // TimeInterval the animation math uses.
        #expect(Double(PickyHUDArchiveHoldPolicy.feedbackStartDelayNanoseconds) == PickyHUDArchiveHoldPolicy.feedbackStartDelay * 1_000_000_000)
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

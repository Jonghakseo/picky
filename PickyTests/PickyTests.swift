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

    @Test func bubbleMarkdownRendersEmphasisWithoutRawDelimiters() throws {
        let attributed = PickyBubbleMarkdown.attributedText(for: "이건 **중요**해요")

        #expect(String(attributed.characters) == "이건 중요해요")
        #expect(PickyBubbleMarkdown.displayString(for: "이건 **중요**해요") == "이건 중요해요")
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    @Test func hudExpansionPolicyKeepsCollapseAndMeasuredExpansionSemantics() throws {
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: false, measuredHeight: 72) == 0)
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: true, measuredHeight: 72) == 72)
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: true, measuredHeight: 0) == nil)
        #expect(PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 200, targetHeight: 180, deferShrink: true))
        #expect(!PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 200, targetHeight: 180, deferShrink: false))
    }

    @Test func quickInputPanelUsesCompactShadowOutset() throws {
        #expect(QuickInputPanelLayout.mainShadowRadius == 9)
        #expect(QuickInputPanelLayout.mainShadowYOffset == 5)
        #expect(QuickInputPanelLayout.tightShadowRadius == 1.5)
        #expect(QuickInputPanelLayout.tightShadowYOffset == 0.5)
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

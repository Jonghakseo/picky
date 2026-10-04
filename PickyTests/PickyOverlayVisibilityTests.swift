//
//  PickyOverlayVisibilityTests.swift
//  PickyTests
//
//  Contracts for the cursor overlay visibility owner and its decision policy.
//

import Testing
@testable import Picky

@MainActor
struct PickyOverlayVisibilityPolicyTests {
    /// The always-on cursor preference is not an in-flight interaction. If it
    /// blocked the transient hide, an overlay brought up while the preference
    /// is off could never fade back out.
    @Test func cursorPreferenceDoesNotBlockTransientHide() {
        #expect(!PickyOverlayVisibilityPolicy.blocksTransientHide([.cursorPreferenceEnabled]))
    }

    @Test func inFlightInteractionsBlockTransientHide() {
        #expect(PickyOverlayVisibilityPolicy.blocksTransientHide([.activeVoiceInput]))
        #expect(PickyOverlayVisibilityPolicy.blocksTransientHide([.activeInkCapture]))
        #expect(PickyOverlayVisibilityPolicy.blocksTransientHide([.speakingResponse]))
        #expect(PickyOverlayVisibilityPolicy.blocksTransientHide([.cursorPreferenceEnabled, .activePointerAnimation]))
    }

    /// A reducer-driven hide is still in progress, so the reason keeps the
    /// overlay on screen until the reducer reports `.hidden`.
    @Test func hidingPhaseStillContributesItsReason() {
        let reasons = PickyOverlayVisibilityPolicy.interactionReasons(
            for: .hiding(timerID: UUID(), reason: .speakingResponse)
        )
        #expect(reasons == [.speakingResponse])
        #expect(PickyOverlayVisibilityPolicy.shouldShowOverlay(for: reasons))
        #expect(PickyOverlayVisibilityPolicy.interactionReasons(for: .hidden).isEmpty)
    }
}

@MainActor
struct PickyOverlayVisibilityControllerTests {
    private final class EffectRecorder {
        var shows = 0
        var hides = 0
        var fades = 0
    }

    private func makeController() -> (PickyOverlayVisibilityController, EffectRecorder) {
        let recorder = EffectRecorder()
        let controller = PickyOverlayVisibilityController()
        controller.windowEffects = PickyOverlayWindowEffects(
            show: { recorder.shows += 1 },
            hide: { recorder.hides += 1 },
            fadeOutAndHide: { recorder.fades += 1 }
        )
        return (controller, recorder)
    }

    @Test func overlayStaysUpWhileAnyReasonHoldsIt() {
        let (controller, recorder) = makeController()

        controller.setLocalReason(.activeInkCapture, visible: true)
        controller.applyInteractionPhase(.visible(reason: [.speakingResponse]))
        #expect(controller.isOverlayVisible)
        #expect(controller.overlayVisibilityReasons == [.activeInkCapture, .speakingResponse])
        #expect(recorder.shows == 1)

        controller.setLocalReason(.activeInkCapture, visible: false)
        #expect(controller.isOverlayVisible)

        controller.applyInteractionPhase(.hidden)
        #expect(!controller.isOverlayVisible)
        #expect(controller.overlayVisibilityReasons.isEmpty)
        #expect(recorder.fades == 1)
        #expect(recorder.hides == 0)
    }

    /// Turning "Show Picky cursor" off must tear the windows down at once; the
    /// fade would leave a ghost cursor on screen after the user opted out.
    @Test func clearingAllReasonsWithoutAnimationHidesImmediately() {
        let (controller, recorder) = makeController()
        controller.setLocalReason(.cursorPreferenceEnabled, visible: true)

        controller.clearAllReasons(animatedHide: false)

        #expect(!controller.isOverlayVisible)
        #expect(controller.overlayVisibilityReasons.isEmpty)
        #expect(recorder.hides == 1)
        #expect(recorder.fades == 0)
    }

    @Test func alreadyHiddenOverlayDoesNotRunWindowTeardownAgain() {
        let (controller, recorder) = makeController()

        controller.clearAllReasons(animatedHide: true)

        #expect(!controller.isOverlayVisible)
        #expect(recorder.fades == 0)
        #expect(recorder.hides == 0)
    }
}

//
//  PickyScreenContextTargetControllerTests.swift
//  PickyTests
//
//  Disarm contract for the armed screen-context target. The session-id and the
//  snapshot entry points share one implementation, so these cases pin the
//  differences that must survive: sticky handling and the revision guard.
//

import Testing
@testable import Picky

private final class StubScreenContextSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky: Bool = false
    private(set) var screenContextTargetRevision: UInt64 = 0

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        let normalizedSticky = sessionID == nil ? false : sticky
        guard screenContextTargetSessionID != sessionID || screenContextTargetSticky != normalizedSticky else { return }
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = normalizedSticky
        screenContextTargetRevision &+= 1
    }
}

@MainActor
struct PickyScreenContextTargetControllerTests {
    private func makeController(
        armed sessionID: String?,
        sticky: Bool = false
    ) -> (PickyScreenContextTargetController, StubScreenContextSelectionStore, PickyOverlayVisibilityController) {
        let store = StubScreenContextSelectionStore()
        if let sessionID {
            store.setScreenContextTarget(sessionID: sessionID, sticky: sticky)
        }
        let overlay = PickyOverlayVisibilityController()
        let controller = PickyScreenContextTargetController(
            selectionStore: store,
            overlayVisibility: overlay
        )
        controller.apply(store.screenContextTargetSessionID)
        return (controller, store, overlay)
    }

    private func armedSnapshot(
        sessionID: String,
        sticky: Bool,
        revision: UInt64
    ) -> PickyVoiceInputTargetSnapshot {
        PickyVoiceInputTargetSnapshot(
            inputID: UUID(),
            target: .pickle(
                sessionID: sessionID,
                origin: .armed(dispatchMode: .followUp, sticky: sticky, revision: revision)
            )
        )
    }

    @Test func armingATargetRaisesTheOverlayReasonAndDisarmingDropsIt() {
        let (controller, _, overlay) = makeController(armed: nil)

        controller.apply("  pickle-a  ", label: "Pickle A")

        #expect(controller.targetSessionID == "pickle-a")
        #expect(controller.targetLabel == "Pickle A")
        #expect(overlay.overlayVisibilityReasons.contains(.screenContextTarget))

        controller.apply(nil)

        #expect(controller.targetSessionID == nil)
        #expect(controller.targetLabel == nil)
        #expect(!overlay.overlayVisibilityReasons.contains(.screenContextTarget))
    }

    /// A label belongs to the session it was armed with; switching targets
    /// without a fresh label must not keep showing the previous Pickle's name.
    @Test func switchingTargetWithoutALabelDropsTheStaleLabel() {
        let (controller, _, _) = makeController(armed: nil)
        controller.apply("pickle-a", label: "Pickle A")

        controller.apply("pickle-b")
        #expect(controller.targetLabel == nil)

        controller.apply("pickle-b", label: "Pickle B")
        controller.apply("pickle-b")
        #expect(controller.targetLabel == "Pickle B")
    }

    @Test func sessionIDDisarmClearsANonStickyTarget() {
        let (controller, store, overlay) = makeController(armed: "pickle-a")

        controller.clearIfCurrent("pickle-a")

        #expect(store.screenContextTargetSessionID == nil)
        #expect(controller.targetSessionID == nil)
        #expect(!overlay.overlayVisibilityReasons.contains(.screenContextTarget))
    }

    @Test func sessionIDDisarmKeepsAStickyTargetArmed() {
        let (controller, store, overlay) = makeController(armed: "pickle-locked", sticky: true)

        controller.clearIfCurrent("pickle-locked")

        #expect(store.screenContextTargetSessionID == "pickle-locked")
        #expect(controller.targetSessionID == "pickle-locked")
        #expect(overlay.overlayVisibilityReasons.contains(.screenContextTarget))
    }

    @Test func sessionIDDisarmIgnoresAnotherSession() {
        let (controller, store, _) = makeController(armed: "pickle-a")

        controller.clearIfCurrent("pickle-b")

        #expect(store.screenContextTargetSessionID == "pickle-a")
        #expect(controller.targetSessionID == "pickle-a")
    }

    @Test func snapshotDisarmKeepsAStickyTargetUnlessTheCallerForcesIt() {
        let (controller, store, _) = makeController(armed: "pickle-locked", sticky: true)
        let revision = store.screenContextTargetRevision
        let snapshot = armedSnapshot(sessionID: "pickle-locked", sticky: true, revision: revision)

        controller.clearIfCurrent(snapshot)
        #expect(store.screenContextTargetSessionID == "pickle-locked")

        controller.clearIfCurrent(snapshot, includingSticky: true)
        #expect(store.screenContextTargetSessionID == nil)
        #expect(controller.targetSessionID == nil)
    }

    /// A late completion must not disarm a target the user re-armed meanwhile.
    @Test func snapshotDisarmIgnoresAStaleRevision() {
        let (controller, store, _) = makeController(armed: "pickle-a")
        let staleRevision = store.screenContextTargetRevision
        store.setScreenContextTarget(sessionID: nil, sticky: false)
        store.setScreenContextTarget(sessionID: "pickle-a", sticky: false)
        controller.apply("pickle-a")

        controller.clearIfCurrent(armedSnapshot(sessionID: "pickle-a", sticky: false, revision: staleRevision))

        #expect(store.screenContextTargetSessionID == "pickle-a")
        #expect(controller.targetSessionID == "pickle-a")
    }

    @Test func snapshotDisarmIgnoresPointerTargets() {
        let (controller, store, _) = makeController(armed: "pickle-a")
        let pointerSnapshot = PickyVoiceInputTargetSnapshot(
            inputID: UUID(),
            target: .pickle(sessionID: "pickle-a", origin: .pointer)
        )

        controller.clearIfCurrent(pointerSnapshot, includingSticky: true)

        #expect(store.screenContextTargetSessionID == "pickle-a")
    }
}

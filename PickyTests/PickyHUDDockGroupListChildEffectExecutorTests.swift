//
//  PickyHUDDockGroupListChildEffectExecutorTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
private final class DockGroupListChildEffectProbe {
    private(set) var events: [String] = []

    func openingEffects() -> PickyHUDDockGroupListChildEffectExecutor.OpeningEffects {
        .init(
            tearDown: { self.events.append("tearDown") },
            updateModel: { self.events.append("updateModel") },
            synchronizeHost: { self.events.append("synchronizeHost") },
            position: { self.events.append("position") },
            present: { self.events.append("present") }
        )
    }

    func synchronizationEffects() -> PickyHUDDockGroupListChildEffectExecutor.SynchronizationEffects {
        .init(
            tearDown: { self.events.append("tearDown") },
            updateModel: { self.events.append("updateModel") },
            updateFocus: { self.events.append("updateFocus") },
            position: { self.events.append("position") }
        )
    }

    func pendingEffects() -> PickyHUDDockGroupListChildEffectExecutor.PendingEffects {
        .init(
            tearDown: { self.events.append("tearDown") },
            updatePendingGroupID: { groupID in self.events.append("pending:\(groupID)") },
            open: { groupID in self.events.append("open:\(groupID)") }
        )
    }
}

@MainActor
struct PickyDockGroupListEffectExecutorTests {
    @Test func initialOpenWithNoVisibleRowsTearsDownBeforeModelHostPositionOrPresentation() {
        let executor = PickyHUDDockGroupListChildEffectExecutor()
        let probe = DockGroupListChildEffectProbe()

        executor.open(groupID: "group", visibleRowIDs: [], effects: probe.openingEffects())

        #expect(probe.events == ["tearDown"])
    }

    @Test func syncFromOneVisibleRowToZeroTearsDownBeforeModelFocusOrPosition() {
        let executor = PickyHUDDockGroupListChildEffectExecutor()
        let probe = DockGroupListChildEffectProbe()

        executor.synchronize(groupID: "group", visibleRowIDs: [], effects: probe.synchronizationEffects())

        #expect(probe.events == ["tearDown"])
    }

    @Test func syncWithOneVisibleRowUpdatesModelFocusAndPositionWithoutTeardown() {
        let executor = PickyHUDDockGroupListChildEffectExecutor()
        let probe = DockGroupListChildEffectProbe()

        executor.synchronize(groupID: "group", visibleRowIDs: ["pickle"], effects: probe.synchronizationEffects())

        #expect(probe.events == ["updateModel", "updateFocus", "position"])
    }

    @Test func pendingRequestThatLosesItsLastVisibleRowTearsDownInsteadOfOpening() {
        let executor = PickyHUDDockGroupListChildEffectExecutor()
        let probe = DockGroupListChildEffectProbe()

        let wasHandled = executor.reconcilePending(
            pendingGroupID: "group",
            existingGroupIDs: ["group"],
            visibleMemberGroupIDs: [],
            effects: probe.pendingEffects()
        )

        #expect(wasHandled)
        #expect(probe.events == ["tearDown"])
    }
}

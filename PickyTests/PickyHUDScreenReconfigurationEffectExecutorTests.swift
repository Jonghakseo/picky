//
//  PickyHUDScreenReconfigurationEffectExecutorTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyHUDScreenReconfigExecutorTests {
    @Test func synchronizesEveryParentBeforeAnySurvivingToast() throws {
        var events: [String] = []
        let executor = PickyHUDScreenReconfigExecutor()

        executor.synchronize(
            liveDisplayIDs: [1, 2],
            parentDisplayIDs: [1, 2],
            toastDisplayIDs: [1, 2],
            effects: .init(
                removeParent: { events.append("removeParent:\($0)") },
                removeToast: { events.append("removeToast:\($0)") },
                synchronizeParent: { events.append("parent:\($0)") },
                synchronizeToast: { events.append("toast:\($0)") }
            )
        )

        let firstToast = try #require(events.firstIndex { $0.hasPrefix("toast:") })
        #expect(events[..<firstToast].allSatisfy { !$0.hasPrefix("toast:") })
        #expect(Set(events.filter { $0.hasPrefix("parent:") }) == ["parent:1", "parent:2"])
        #expect(Set(events.filter { $0.hasPrefix("toast:") }) == ["toast:1", "toast:2"])
    }

    @Test func removesDisconnectedDisplaysBeforeSynchronizingLiveOnes() {
        var events: [String] = []
        let executor = PickyHUDScreenReconfigExecutor()

        executor.synchronize(
            liveDisplayIDs: [1],
            parentDisplayIDs: [1, 2],
            toastDisplayIDs: [2],
            effects: .init(
                removeParent: { events.append("removeParent:\($0)") },
                removeToast: { events.append("removeToast:\($0)") },
                synchronizeParent: { events.append("parent:\($0)") },
                synchronizeToast: { events.append("toast:\($0)") }
            )
        )

        #expect(events == ["removeParent:2", "removeToast:2", "parent:1"])
    }
}

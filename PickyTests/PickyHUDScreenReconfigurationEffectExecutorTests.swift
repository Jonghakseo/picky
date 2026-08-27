//
//  PickyHUDScreenReconfigurationEffectExecutorTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyHUDScreenReconfigExecutorTests {
    @Test func synchronizesEveryParentBeforeAnySurvivingChild() throws {
        var events: [String] = []
        let executor = PickyHUDScreenReconfigExecutor()

        executor.synchronize(
            liveDisplayIDs: [1, 2],
            parentDisplayIDs: [1, 2],
            toastDisplayIDs: [1],
            childDisplayIDs: [1, 2],
            effects: .init(
                removeParent: { events.append("removeParent:\($0)") },
                removeToast: { events.append("removeToast:\($0)") },
                removeChild: { events.append("removeChild:\($0)") },
                synchronizeParent: { events.append("parent:\($0)") },
                synchronizeChild: { events.append("child:\($0)") },
                synchronizeToast: { events.append("toast:\($0)") }
            )
        )

        let firstChild = try #require(events.firstIndex { $0.hasPrefix("child:") })
        #expect(events[..<firstChild].allSatisfy { !$0.hasPrefix("child:") })
        #expect(Set(events.filter { $0.hasPrefix("parent:") }) == ["parent:1", "parent:2"])
        #expect(Set(events.filter { $0.hasPrefix("child:") }) == ["child:1", "child:2"])
    }

    @Test func removesDisconnectedChildBeforeTryingToSynchronizeIt() {
        var events: [String] = []
        let executor = PickyHUDScreenReconfigExecutor()

        executor.synchronize(
            liveDisplayIDs: [1],
            parentDisplayIDs: [1, 2],
            toastDisplayIDs: [2],
            childDisplayIDs: [1, 2],
            effects: .init(
                removeParent: { events.append("removeParent:\($0)") },
                removeToast: { events.append("removeToast:\($0)") },
                removeChild: { events.append("removeChild:\($0)") },
                synchronizeParent: { events.append("parent:\($0)") },
                synchronizeChild: { events.append("child:\($0)") },
                synchronizeToast: { events.append("toast:\($0)") }
            )
        )

        #expect(events.contains("removeParent:2"))
        #expect(events.contains("removeToast:2"))
        #expect(events.contains("removeChild:2"))
        #expect(!events.contains("child:2"))
        #expect(events.contains("parent:1"))
        #expect(events.contains("child:1"))
    }
}

//
//  PickyHUDDockGroupListHostingLifecycleTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
private final class DockGroupListContentHostProbe: PickyHUDDockGroupListContentHost {
    private(set) var contentView: NSView?
    private(set) var assignments: [NSView?] = []

    func setDockGroupListContentView(_ contentView: NSView?) {
        self.contentView = contentView
        assignments.append(contentView)
    }
}

@MainActor
struct PickyHUDDockGroupListHostingLifecycleTests {
    @Test func sameGroupSyncRetainsTheActuallyAssignedContentView() {
        let host = DockGroupListContentHostProbe()
        let lifecycle = PickyHUDDockGroupListHostingLifecycle(host: host)

        let first = lifecycle.synchronize(groupID: "group") { NSView() }
        let second = lifecycle.synchronize(groupID: "group") { NSView() }

        guard case .created(let firstView) = first,
              case .retained(let retainedView) = second
        else {
            Issue.record("Expected creation followed by retention")
            return
        }
        #expect(firstView === retainedView)
        #expect(host.contentView === firstView)
        #expect(host.assignments.count == 1)
        #expect(lifecycle.creationCount == 1)
    }

    @Test func groupReplacementAndTeardownAssignExactlyOneReplacementThenNil() {
        let host = DockGroupListContentHostProbe()
        let lifecycle = PickyHUDDockGroupListHostingLifecycle(host: host)
        _ = lifecycle.synchronize(groupID: "first") { NSView() }
        let replacement = lifecycle.synchronize(groupID: "second") { NSView() }

        guard case .created(let replacementView) = replacement else {
            Issue.record("Changing groups must assign a replacement hosting view")
            return
        }
        #expect(host.contentView === replacementView)
        #expect(host.assignments.count == 2)
        lifecycle.tearDown()
        #expect(host.contentView == nil)
        #expect(host.assignments.count == 3)
        #expect(lifecycle.groupID == nil)
    }
}

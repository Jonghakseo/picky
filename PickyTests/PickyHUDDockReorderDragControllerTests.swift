//
//  PickyHUDDockReorderDragControllerTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockReorderDragControllerTests {
    private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    @Test func cancellationClearsNativeTrackingSoLateDragAndUpCannotEmitOrCommit() throws {
        let monitorToken = NSObject()
        var installedHandlers: [(NSEvent) -> NSEvent?] = []
        var removedMonitorCount = 0
        let controller = PickyDockReorderDragController(
            allowsUserEnvironmentEffects: true,
            installLocalMonitor: { _, handler in
                installedHandlers.append(handler)
                return monitorToken
            },
            removeLocalMonitor: { monitor in
                #expect((monitor as AnyObject) === monitorToken)
                removedMonitorCount += 1
            }
        )

        controller.begin(sessionID: "session", anchorScreenPoint: .zero)
        guard case .dragging(let sessionID, _) = controller.phase else {
            Issue.record("Expected native drag tracking to begin")
            return
        }
        #expect(sessionID == "session")
        #expect(installedHandlers.count == 1)

        controller.reset()
        #expect(controller.phase == .idle)
        #expect(removedMonitorCount == 1)

        _ = installedHandlers[0](try mouseEvent(.leftMouseDragged))
        _ = installedHandlers[0](try mouseEvent(.leftMouseUp))
        #expect(controller.phase == .idle)
        #expect(removedMonitorCount == 1)

        // A later physical mouse-down may hand off a fresh drag normally.
        controller.begin(sessionID: "next-session", anchorScreenPoint: .zero)
        guard case .dragging(let nextSessionID, _) = controller.phase else {
            Issue.record("Expected a later drag to begin normally")
            return
        }
        #expect(nextSessionID == "next-session")
    }

    @Test func cancelledFolderGestureIgnoresLaterChangesUntilItsMatchingEndThenAllowsANewDrag() {
        var lifecycle = PickyDockGroupDragGestureLifecycle()

        let acceptedInitialChange = lifecycle.acceptChange(groupID: "folder")
        lifecycle.cancel()
        let acceptedCancelledChange = lifecycle.acceptChange(groupID: "folder")
        let committedCancelledEnd = lifecycle.finish(groupID: "folder")

        let acceptedNewDrag = lifecycle.acceptChange(groupID: "folder")
        let committedNewDragEnd = lifecycle.finish(groupID: "folder")

        #expect(acceptedInitialChange)
        #expect(!acceptedCancelledChange)
        #expect(!committedCancelledEnd)
        #expect(acceptedNewDrag)
        #expect(committedNewDragEnd)
    }

    @Test func railMouseUpResetsCancelledFolderGestureWhenItsSourceDisappears() throws {
        let monitorToken = NSObject()
        var installedHandlers: [(NSEvent) -> NSEvent?] = []
        var removedMonitorCount = 0
        var lifecycle = PickyDockGroupDragGestureLifecycle()
        let releaseMonitor = PickyDockGroupDragReleaseMonitor(
            allowsUserEnvironmentEffects: true,
            installLocalMonitor: { _, handler in
                installedHandlers.append(handler)
                return monitorToken
            },
            removeLocalMonitor: { monitor in
                #expect((monitor as AnyObject) === monitorToken)
                removedMonitorCount += 1
            }
        )

        let acceptedRemovedFolder = lifecycle.acceptChange(groupID: "removed-folder")
        releaseMonitor.begin {
            lifecycle.finishCancelledGestureOnPhysicalRelease()
        }
        lifecycle.cancel()

        // The source tile has disappeared, so it cannot call `finish` on mouse-up.
        let acceptedSamePressOtherFolder = lifecycle.acceptChange(groupID: "other-folder")
        #expect(acceptedRemovedFolder)
        #expect(!acceptedSamePressOtherFolder)
        #expect(installedHandlers.count == 1)
        _ = installedHandlers[0](try mouseEvent(.leftMouseUp))
        #expect(removedMonitorCount == 1)

        let acceptedLaterOtherFolder = lifecycle.acceptChange(groupID: "other-folder")
        let committedLaterOtherFolder = lifecycle.finish(groupID: "other-folder")
        #expect(acceptedLaterOtherFolder)
        #expect(committedLaterOtherFolder)
        #expect(removedMonitorCount == 1)
    }
}

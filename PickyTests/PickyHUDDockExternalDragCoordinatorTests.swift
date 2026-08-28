//
//  PickyHUDDockExternalDragCoordinatorTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockExternalDragCoordinatorTests {
    private final class PreviewSpy: PickyHUDDockExternalDragPreviewDriving {
        var began = 0
        var destinations: [PickyDockContainer?] = []
        var terminalResults: [Bool] = []

        func begin() { began += 1 }
        func update(destination: PickyDockContainer?) { destinations.append(destination) }
        func finish(committed: Bool) { terminalResults.append(committed) }
    }

    private final class MonitorHarness {
        struct Registration {
            let token: NSObject
            let handler: (NSEvent) -> Void
        }

        var local: [Registration] = []
        var global: [Registration] = []
        var removed: [NSObject] = []

        func installLocal(_: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
            let token = NSObject()
            local.append(.init(token: token, handler: handler))
            return token
        }

        func installGlobal(_: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
            let token = NSObject()
            global.append(.init(token: token, handler: handler))
            return token
        }

        func remove(_ monitor: Any) {
            if let monitor = monitor as? NSObject { removed.append(monitor) }
        }
    }

    private func event(_ type: NSEvent.EventType) throws -> NSEvent {
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

    private func escapeEvent() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))
    }

    private func promotion() -> PickyHUDDockExternalDragPromotion {
        let layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "source", memberSessionIDs: ["dragged"])),
            .session(id: "loose"),
        ])
        let fingerprint = PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose"],
            dockSide: .bottom,
            geometryRevision: 4
        )
        return .init(
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            sessionID: "dragged",
            sourceGroupID: "source",
            frozenLayout: layout,
            fingerprint: fingerprint,
            geometry: .init(
                acceptanceFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
                folderDropFrames: [:],
                slotCandidates: [.init(container: .topLevel(index: 1), center: 150)],
                topLevelInsertionCandidates: [.init(topLevelIndex: 1, center: 100)],
                groupCandidates: [],
                dockSide: .bottom,
                geometryRevision: 4,
                slotPitch: 80
            )
        )
    }

    private func makeCoordinator(
        harness: MonitorHarness,
        mouseLocation: @escaping () -> CGPoint,
        currentFingerprint: @escaping () -> PickyHUDDockLayoutFingerprint,
        preview: PreviewSpy,
        commits: @escaping (String, PickyDockContainer) -> Void
    ) -> PickyHUDDockExternalDragCoordinator {
        PickyHUDDockExternalDragCoordinator(
            installLocalMonitor: { mask, handler in harness.installLocal(mask, handler: handler) },
            installGlobalMonitor: { mask, handler in harness.installGlobal(mask, handler: handler) },
            removeMonitor: harness.remove,
            mouseLocation: mouseLocation,
            currentFingerprint: currentFingerprint,
            preview: preview,
            commit: commits
        )
    }

    @Test func localAndGlobalMouseUpCommitExactlyOnceAndRemoveBothMonitors() throws {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        var commits: [(String, PickyDockContainer)] = []
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { CGPoint(x: 130, y: 50) },
            currentFingerprint: { payload.fingerprint },
            preview: preview,
            commits: { commits.append(($0, $1)) }
        )

        #expect(coordinator.start(payload))
        #expect(preview.began == 1)
        #expect(harness.local.count == 1)
        #expect(harness.global.count == 1)

        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseUp))

        #expect(commits.count == 1)
        #expect(commits.first?.0 == "dragged")
        #expect(commits.first?.1 == .topLevel(index: 1))
        #expect(preview.terminalResults == [true])
        #expect(harness.removed.count == 2)
    }

    @Test func cancellationRemovesEveryMonitorAndRetainedCallbacksStayInert() throws {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        var commits: [(String, PickyDockContainer)] = []
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { CGPoint(x: 100, y: 50) },
            currentFingerprint: { payload.fingerprint },
            preview: preview,
            commits: { commits.append(($0, $1)) }
        )

        #expect(coordinator.start(payload))
        harness.local[0].handler(try escapeEvent())
        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseDragged))

        #expect(commits.isEmpty)
        #expect(preview.terminalResults == [false])
        #expect(harness.removed.count == 2)
    }

    @Test func mouseUpRecomputesFromCurrentMouseLocationInsteadOfLastDragUpdate() throws {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        var mouseLocation = CGPoint(x: 100, y: 50)
        var commits: [(String, PickyDockContainer)] = []
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { mouseLocation },
            currentFingerprint: { payload.fingerprint },
            preview: preview,
            commits: { commits.append(($0, $1)) }
        )

        #expect(coordinator.start(payload))
        harness.local[0].handler(try event(.leftMouseDragged))
        mouseLocation = CGPoint(x: 100, y: 150)
        harness.local[0].handler(try event(.leftMouseUp))

        // The last drag update was valid, but physical release happened below
        // the frozen acceptance frame. Reusing stale drag feedback would commit.
        #expect(preview.destinations.count == 2)
        #expect(preview.destinations[1] == nil)
        #expect(commits.isEmpty)
        #expect(preview.terminalResults == [false])
    }

    @Test func staleFullFingerprintCancelsBeforeCommit() throws {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        var commits: [(String, PickyDockContainer)] = []
        let stale = PickyHUDDockLayoutFingerprint(
            layout: PickyDockLayout(entries: [.session(id: "loose")]),
            activeSessionIDs: ["loose"],
            dockSide: .bottom,
            geometryRevision: 4
        )
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { CGPoint(x: 100, y: 50) },
            currentFingerprint: { stale },
            preview: preview,
            commits: { commits.append(($0, $1)) }
        )

        #expect(coordinator.start(payload))
        harness.local[0].handler(try event(.leftMouseUp))

        #expect(commits.isEmpty)
        #expect(preview.terminalResults == [false])
    }
}

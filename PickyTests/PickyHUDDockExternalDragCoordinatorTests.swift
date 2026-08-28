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
            let mask: NSEvent.EventTypeMask
            let handler: (NSEvent) -> Void
        }

        var local: [Registration] = []
        var global: [Registration] = []
        var removed: [NSObject] = []
        var returnsNilForLocal = false
        var returnsNilForGlobal = false

        func installLocal(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
            let token = NSObject()
            local.append(.init(token: token, mask: mask, handler: handler))
            return returnsNilForLocal ? nil : token
        }

        func installGlobal(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
            let token = NSObject()
            global.append(.init(token: token, mask: mask, handler: handler))
            return returnsNilForGlobal ? nil : token
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

    private func promotion(
        token: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    ) -> PickyHUDDockExternalDragPromotion {
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
            token: token,
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
                layoutFingerprint: fingerprint,
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
        #expect(harness.local[0].mask == [.leftMouseDragged, .leftMouseUp])
        #expect(harness.global[0].mask == [.leftMouseDragged, .leftMouseUp])

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
        coordinator.cancelForEscape()
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

    @Test func geometryMeasuredForOlderLayoutRejectsNewPromotionBeforePreviewOrMonitorsBegin() {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        let currentLayout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "source", memberSessionIDs: ["dragged"])),
            .session(id: "loose"),
            .session(id: "new"),
        ])
        let currentFingerprint = PickyHUDDockLayoutFingerprint(
            layout: currentLayout,
            activeSessionIDs: ["dragged", "loose", "new"],
            dockSide: .bottom,
            geometryRevision: 4
        )
        let staleGeometry = PickyHUDDockExternalDragGeometrySnapshot(
            acceptanceFrame: payload.geometry.acceptanceFrame,
            folderDropFrames: payload.geometry.folderDropFrames,
            slotCandidates: payload.geometry.slotCandidates,
            topLevelInsertionCandidates: payload.geometry.topLevelInsertionCandidates,
            groupCandidates: payload.geometry.groupCandidates,
            dockSide: payload.geometry.dockSide,
            geometryRevision: payload.geometry.geometryRevision,
            layoutFingerprint: payload.geometry.layoutFingerprint,
            slotPitch: payload.geometry.slotPitch
        )
        let inconsistentPromotion = PickyHUDDockExternalDragPromotion(
            token: payload.token,
            sessionID: payload.sessionID,
            sourceGroupID: payload.sourceGroupID,
            frozenLayout: currentLayout,
            fingerprint: currentFingerprint,
            geometry: staleGeometry
        )
        var commits: [(String, PickyDockContainer)] = []
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { CGPoint(x: 100, y: 50) },
            currentFingerprint: { currentFingerprint },
            preview: preview,
            commits: { commits.append(($0, $1)) }
        )

        #expect(!coordinator.start(inconsistentPromotion))
        #expect(preview.began == 0)
        #expect(harness.local.isEmpty)
        #expect(harness.global.isEmpty)
        #expect(commits.isEmpty)
    }

    @Test func unavailableLocalMonitorRejectsPromotionAndRetainedCallbacksStayInert() throws {
        let harness = MonitorHarness()
        harness.returnsNilForLocal = true
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

        #expect(!coordinator.start(payload))
        #expect(preview.began == 0)
        #expect(preview.terminalResults.isEmpty)
        #expect(harness.local.count == 1)
        #expect(harness.global.count == 1)
        #expect(harness.removed.count == 1)
        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseUp))
        #expect(commits.isEmpty)

        harness.returnsNilForLocal = false
        let retryPayload = promotion(token: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        #expect(coordinator.start(retryPayload))
        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseUp))
        #expect(commits.isEmpty)
        coordinator.cancelForTeardown()
        #expect(preview.began == 1)
        #expect(preview.terminalResults == [false])
    }

    @Test func unavailableGlobalMonitorRejectsPromotionAndRetainedCallbacksStayInert() throws {
        let harness = MonitorHarness()
        harness.returnsNilForGlobal = true
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

        #expect(!coordinator.start(payload))
        #expect(preview.began == 0)
        #expect(preview.terminalResults.isEmpty)
        #expect(harness.local.count == 1)
        #expect(harness.global.count == 1)
        #expect(harness.removed.count == 1)
        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseUp))
        #expect(commits.isEmpty)

        harness.returnsNilForGlobal = false
        let retryPayload = promotion(token: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        #expect(coordinator.start(retryPayload))
        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseUp))
        #expect(commits.isEmpty)
        coordinator.cancelForTeardown()
        #expect(preview.began == 1)
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

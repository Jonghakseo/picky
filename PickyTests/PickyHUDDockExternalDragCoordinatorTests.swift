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
        var presentations: [PickyHUDDockExternalDragPreviewPresentation] = []
        var updatePoints: [CGPoint] = []
        var destinations: [PickyDockContainer?] = []
        var terminals: [PickyHUDDockExternalDragTerminal] = []

        func begin(_ presentation: PickyHUDDockExternalDragPreviewPresentation) {
            began += 1
            presentations.append(presentation)
        }
        func update(pointerScreenPoint: CGPoint, destination: PickyDockContainer?) {
            updatePoints.append(pointerScreenPoint)
            destinations.append(destination)
        }
        func finish(terminal: PickyHUDDockExternalDragTerminal) { terminals.append(terminal) }
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

    private func session(id: String) -> PickyHUDDockSession {
        let referenceDate = Date(timeIntervalSince1970: 0)
        return PickyHUDDockSession(session: PickySessionCard.fromAgentSession(PickyAgentSession(
            id: id,
            title: "Preview fixture",
            status: .running,
            cwd: "/tmp",
            createdAt: referenceDate,
            updatedAt: referenceDate,
            lastSummary: "",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )))
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
            previewPresentation: .init(
                token: token,
                sourceGroupID: "source",
                session: session(id: "dragged"),
                sourceFrame: CGRect(x: -20, y: 10, width: 40, height: 40),
                pointerScreenPoint: CGPoint(x: 100, y: 50),
                dockSide: .bottom,
                metrics: PickyHUDDockMetrics(preset: .medium)
            ),
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
        #expect(preview.presentations.first?.session.id == "dragged")
        #expect(preview.presentations.first?.sourceFrame == CGRect(x: -20, y: 10, width: 40, height: 40))
        #expect(preview.presentations.first?.pointerScreenPoint == CGPoint(x: 100, y: 50))
        #expect(harness.local.count == 1)
        #expect(harness.global.count == 1)
        #expect(harness.local[0].mask == [.leftMouseDragged, .leftMouseUp])
        #expect(harness.global[0].mask == [.leftMouseDragged, .leftMouseUp])

        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseUp))

        #expect(commits.count == 1)
        #expect(commits.first?.0 == "dragged")
        #expect(commits.first?.1 == .topLevel(index: 1))
        #expect(preview.terminals == [.commit(.topLevel(index: 1))])
        #expect(harness.removed.count == 2)
    }

    @Test func physicalMouseUpHandoffFinishesOnceWithoutWaitingForANewMonitorEvent() {
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
        #expect(coordinator.finishFromPhysicalMouseUp())
        #expect(!coordinator.finishFromPhysicalMouseUp())
        #expect(commits.count == 1)
        #expect(commits.first?.0 == "dragged")
        #expect(commits.first?.1 == .topLevel(index: 1))
        #expect(preview.terminals == [.commit(.topLevel(index: 1))])
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
        #expect(coordinator.cancelForEscape())
        #expect(!coordinator.cancelForEscape())
        harness.local[0].handler(try event(.leftMouseUp))
        harness.global[0].handler(try event(.leftMouseDragged))

        #expect(commits.isEmpty)
        #expect(preview.terminals == [.cancel(.escape)])
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
        #expect(preview.destinations.count == 3)
        #expect(preview.destinations[2] == nil)
        #expect(commits.isEmpty)
        #expect(preview.terminals == [.cancel(.invalidDrop)])
    }

    @Test func mouseUpUsesOneFinalPointerSampleForResolutionAndPreview() throws {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        var samples = [CGPoint(x: 130, y: 50), CGPoint(x: 100, y: 150)]
        var commits: [(String, PickyDockContainer)] = []
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { samples.removeFirst() },
            currentFingerprint: { payload.fingerprint },
            preview: preview,
            commits: { commits.append(($0, $1)) }
        )

        #expect(coordinator.start(payload))
        harness.local[0].handler(try event(.leftMouseUp))

        #expect(samples.isEmpty)
        #expect(preview.updatePoints == [CGPoint(x: 130, y: 50), CGPoint(x: 100, y: 150)])
        #expect(preview.destinations == [.topLevel(index: 1), nil])
        #expect(commits.isEmpty)
        #expect(preview.terminals == [.cancel(.invalidDrop)])
    }

    @Test func emittedFingerprintCancelsBeforePublishedStorageAdvances() {
        let harness = MonitorHarness()
        let preview = PreviewSpy()
        let payload = promotion()
        let coordinator = makeCoordinator(
            harness: harness,
            mouseLocation: { CGPoint(x: 100, y: 50) },
            currentFingerprint: { payload.fingerprint },
            preview: preview,
            commits: { _, _ in Issue.record("stale drag must not commit") }
        )
        let emittedFingerprint = PickyHUDDockLayoutFingerprint(
            layout: payload.frozenLayout,
            activeSessionIDs: payload.fingerprint.activeSessionIDs,
            dockSide: payload.fingerprint.dockSide,
            geometryRevision: payload.fingerprint.geometryRevision,
            fontScale: 1.3
        )

        #expect(coordinator.start(payload))
        #expect(coordinator.cancelIfFingerprintIsStale(emittedFingerprint))
        #expect(preview.terminals == [.cancel(.staleLayout)])
        #expect(harness.removed.count == 2)
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
            previewPresentation: payload.previewPresentation,
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

    @Test func previewTokenOrSourceGroupMismatchRejectsPromotion() {
        let payload = promotion()
        let tokenMismatch = PickyHUDDockExternalDragPromotion(
            token: payload.token,
            sessionID: payload.sessionID,
            sourceGroupID: payload.sourceGroupID,
            previewPresentation: .init(
                token: UUID(), sourceGroupID: payload.sourceGroupID,
                session: payload.previewPresentation.session, sourceFrame: payload.previewPresentation.sourceFrame,
                pointerScreenPoint: payload.previewPresentation.pointerScreenPoint,
                dockSide: payload.previewPresentation.dockSide, metrics: payload.previewPresentation.metrics
            ), frozenLayout: payload.frozenLayout, fingerprint: payload.fingerprint, geometry: payload.geometry
        )
        let sourceMismatch = PickyHUDDockExternalDragPromotion(
            token: payload.token,
            sessionID: payload.sessionID,
            sourceGroupID: payload.sourceGroupID,
            previewPresentation: .init(
                token: payload.token, sourceGroupID: "other",
                session: payload.previewPresentation.session, sourceFrame: payload.previewPresentation.sourceFrame,
                pointerScreenPoint: payload.previewPresentation.pointerScreenPoint,
                dockSide: payload.previewPresentation.dockSide, metrics: payload.previewPresentation.metrics
            ), frozenLayout: payload.frozenLayout, fingerprint: payload.fingerprint, geometry: payload.geometry
        )

        #expect(!tokenMismatch.isConsistent)
        #expect(!sourceMismatch.isConsistent)
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
        #expect(preview.terminals.isEmpty)
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
        #expect(preview.terminals == [.cancel(.teardown)])
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
        #expect(preview.terminals.isEmpty)
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
        #expect(preview.terminals == [.cancel(.teardown)])
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
        #expect(preview.terminals == [.cancel(.staleLayout)])
    }
}

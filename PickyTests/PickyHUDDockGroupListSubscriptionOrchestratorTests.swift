//
//  PickyHUDDockGroupListSubscriptionOrchestratorTests.swift
//  PickyTests
//

import AppKit
import Combine
import CoreGraphics
import Testing
@testable import Picky

@MainActor
private final class DockGroupListOverlayContentHostProbe: PickyHUDDockGroupListContentHost {
    private(set) var contentView: NSView?

    func setDockGroupListContentView(_ contentView: NSView?) {
        self.contentView = contentView
    }
}

@MainActor
struct PickyHUDDockGroupListSubscriptionOrchestratorTests {
    private func snapshot(groupID: String) -> PickyHUDDockSnapshot {
        PickyHUDDockSnapshot(
            activeSessions: [],
            dockLayout: PickyDockLayout(entries: [.group(PickyDockGroup(id: groupID))]),
            screenContextTargetSessionID: nil,
            screenContextTargetSticky: false,
            screenContextArmCollapseToken: UUID(),
            pendingDoneFlashSessionIDs: [],
            unreadSessionIDs: [],
            pinnedPickleCwds: [],
            recentPickleCwds: [],
            isLoadingInitialSessionSnapshot: false,
            openSessionRequest: nil
        )
    }

    @Test func actualSubscriptionForwardsEmittedSnapshotInsteadOfStaleStorage() {
        let storedSnapshot = snapshot(groupID: "stored")
        let emittedSnapshot = snapshot(groupID: "emitted")
        let snapshots = PassthroughSubject<PickyHUDDockSnapshot, Never>()
        let fontScales = CurrentValueSubject<CGFloat, Never>(1)
        var received: [(PickyHUDDockSnapshot, CGFloat)] = []
        let orchestrator = PickyHUDDockGroupListSubscriptionOrchestrator(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            fontScalePublisher: fontScales.eraseToAnyPublisher()
        ) { snapshot, scale in
            received.append((snapshot, scale))
        }
        _ = orchestrator

        snapshots.send(emittedSnapshot)

        #expect(received.count == 1)
        #expect(received[0].0 == emittedSnapshot)
        #expect(received[0].1 == 1)
        #expect(received[0].0 != storedSnapshot)
    }

    @Test func overlayLifecycleRetainsSubscriptionAndOwnsHostingReplacementAndTeardown() {
        let initialSnapshot = snapshot(groupID: "first")
        let snapshots = CurrentValueSubject<PickyHUDDockSnapshot, Never>(initialSnapshot)
        let fontScales = CurrentValueSubject<CGFloat, Never>(1)
        let host = DockGroupListOverlayContentHostProbe()
        var received: [(PickyHUDDockSnapshot, CGFloat)] = []
        var lifecycle: PickyHUDDockGroupListOverlayLifecycle? = PickyHUDDockGroupListOverlayLifecycle(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            fontScalePublisher: fontScales.eraseToAnyPublisher()
        ) { snapshot, scale in
            received.append((snapshot, scale))
        }

        let first = lifecycle?.synchronize(displayID: 1, host: host, groupID: "first") { NSView() }
        let retained = lifecycle?.synchronize(displayID: 1, host: host, groupID: "first") { NSView() }
        let replacement = lifecycle?.synchronize(displayID: 1, host: host, groupID: "second") { NSView() }
        guard case .created(let firstView)? = first,
              case .retained(let retainedView)? = retained,
              case .created(let replacementView)? = replacement
        else {
            Issue.record("Expected production lifecycle to create, retain, then replace its host")
            return
        }
        #expect(firstView === retainedView)
        #expect(replacementView !== firstView)
        #expect(host.contentView === replacementView)

        let replacementSnapshot = snapshot(groupID: "replacement")
        snapshots.send(replacementSnapshot)
        #expect(received.last?.0 == replacementSnapshot)
        lifecycle?.tearDownAll()
        #expect(host.contentView == nil)
        #expect(lifecycle?.hostedDisplayCount == 0)

        let receivedBeforeRelease = received.count
        lifecycle = nil
        fontScales.send(1.3)
        #expect(received.count == receivedBeforeRelease)
    }

    @Test func actualSubscriptionForwardsEmittedFontScaleInsteadOfStaleStorage() {
        let initialSnapshot = snapshot(groupID: "group")
        let snapshots = CurrentValueSubject<PickyHUDDockSnapshot, Never>(initialSnapshot)
        let fontScales = PassthroughSubject<CGFloat, Never>()
        var received: [(PickyHUDDockSnapshot, CGFloat)] = []
        let orchestrator = PickyHUDDockGroupListSubscriptionOrchestrator(
            snapshotPublisher: snapshots.eraseToAnyPublisher(),
            fontScalePublisher: fontScales.eraseToAnyPublisher()
        ) { snapshot, scale in
            received.append((snapshot, scale))
        }
        _ = orchestrator

        fontScales.send(1.3)

        #expect(received.count == 1)
        #expect(received[0].0 == initialSnapshot)
        #expect(received[0].1 == 1.3)
    }
}

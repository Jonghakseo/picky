//
//  PickyHUDDockGroupListSubscriptionOrchestratorTests.swift
//  PickyTests
//

import Combine
import CoreGraphics
import Testing
@testable import Picky

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

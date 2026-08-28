//
//  PickyHUDDockExternalDragPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockExternalDragPolicyTests {
    private let layout = PickyDockLayout(entries: [
        .session(id: "loose"),
        .group(PickyDockGroup(id: "source", memberSessionIDs: ["dragged", "archived"])),
        .group(PickyDockGroup(id: "target", memberSessionIDs: ["member"])),
    ])

    private func geometry(
        side: PickyHUDDockSide = .bottom,
        acceptanceFrame: CGRect = CGRect(x: -100, y: 20, width: 320, height: 80),
        folderDropFrames: [String: CGRect] = [
            "source": CGRect(x: -50, y: 30, width: 40, height: 40),
            "target": CGRect(x: 50, y: 30, width: 40, height: 40),
        ]
    ) -> PickyHUDDockExternalDragGeometrySnapshot {
        let layoutFingerprint = PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: side,
            geometryRevision: 7
        )
        return PickyHUDDockExternalDragGeometrySnapshot(
            acceptanceFrame: acceptanceFrame,
            folderDropFrames: folderDropFrames,
            slotCandidates: [.init(container: .topLevel(index: 0), center: -80)],
            topLevelInsertionCandidates: [.init(topLevelIndex: 1, center: 0)],
            groupCandidates: [
                .init(groupID: "source", center: -30, halfExtent: 20),
                .init(groupID: "target", center: 70, halfExtent: 20),
            ],
            dockSide: side,
            geometryRevision: 7,
            layoutFingerprint: layoutFingerprint,
            slotPitch: 80
        )
    }

    @Test func layoutFingerprintIncludesEveryOrderedMemberActiveIDSideAndGeometryRevision() {
        let base = PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: .bottom,
            geometryRevision: 7
        )
        var reorderedMembers = layout
        reorderedMembers.updateGroup(id: "source") { $0.memberSessionIDs.reverse() }

        #expect(base != PickyHUDDockLayoutFingerprint(
            layout: reorderedMembers,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: .bottom,
            geometryRevision: 7
        ))
        #expect(base != PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose"],
            dockSide: .bottom,
            geometryRevision: 7
        ))
        #expect(base != PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: .left,
            geometryRevision: 7
        ))
        #expect(base != PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: .bottom,
            geometryRevision: 8
        ))
    }

    @Test func screenPointMustPassTwoDimensionalAcceptanceBeforeAxisResolutionAcrossDockSides() {
        for side in PickyHUDDockSide.allCases {
            let snapshot = geometry(side: side)
            let axisAlignedButOutsideCrossAxis: CGPoint
            switch side.orientation {
            case .horizontal: axisAlignedButOutsideCrossAxis = CGPoint(x: 0, y: 160)
            case .vertical: axisAlignedButOutsideCrossAxis = CGPoint(x: 400, y: 50)
            }

            #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
                draggedSessionID: "dragged",
                sourceGroupID: "source",
                screenPoint: axisAlignedButOutsideCrossAxis,
                geometry: snapshot,
                layout: layout
            ) == nil)
        }
    }

    @Test func negativeOriginFolderFrameAcceptsExactTargetAndRejectsSourceGroup() {
        let snapshot = geometry()

        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: 60, y: 40),
            geometry: snapshot,
            layout: layout
        ) == .group(id: "target", memberIndex: 0))
        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: -40, y: 40),
            geometry: snapshot,
            layout: layout
        ) == nil)
    }

    @Test func acceptedRailGapUsesAxisResolverOnlyAfterTwoDimensionalGate() {
        let snapshot = geometry()

        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: 0, y: 90),
            geometry: snapshot,
            layout: layout
        ) == .topLevel(index: 1))
        // The target's primary-axis center is 70, but its badge only spans
        // y: 30...70. The transparent rail area below it stays top-level.
        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: 70, y: 90),
            geometry: snapshot,
            layout: layout
        ) == .topLevel(index: 1))
    }

    @Test func unknownFolderGeometryNeverFallsBackToTopLevelAppend() {
        let snapshot = geometry(folderDropFrames: [
            "removed": CGRect(x: 120, y: 30, width: 40, height: 40),
        ])

        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: 130, y: 40),
            geometry: snapshot,
            layout: layout
        ) == nil)
    }

    @Test func terminalLeaseAcceptsOnlyOneTerminalEffectAndMakesLateEventsInert() {
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var state = PickyHUDDockExternalDragState()

        let began = state.begin(token: token)
        #expect(began)
        #expect(state.acceptsUpdate(for: token))
        #expect(state.claimTerminal(
            token: token,
            outcome: .commit(.topLevel(index: 1))
        ) == .commit(.topLevel(index: 1)))
        #expect(!state.acceptsUpdate(for: token))
        #expect(state.claimTerminal(token: token, outcome: .cancel(.escape)) == nil)
        state.finishTerminal()
        #expect(state.phase == .idle)
    }

    @Test func cancellationAndFingerprintMismatchNeverClaimASecondTerminalEffect() {
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var state = PickyHUDDockExternalDragState()

        let began = state.begin(token: token)
        #expect(began)
        #expect(state.claimTerminal(token: token, outcome: .cancel(.staleLayout)) == .cancel(.staleLayout))
        #expect(state.claimTerminal(token: token, outcome: .cancel(.invalidDrop)) == nil)
        #expect(!state.acceptsUpdate(for: token))
    }
}

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

    @Test func screenGeometryBuilderConvertsTopLeftHUDCoordinatesAcrossANegativeOriginDisplay() throws {
        let input = PickyHUDDockExternalDragRailGeometryInput(
            slots: [
                .init(target: .session(id: "loose", container: .topLevel(index: 0)), visibleIndex: 0),
                .init(target: .group(id: "source"), visibleIndex: 1),
                .init(target: .group(id: "target"), visibleIndex: 2),
            ],
            slotCenters: ["loose": CGPoint(x: 32, y: 18)],
            topEntryIDs: ["session:loose", "group:source", "group:target"],
            topEntryAxisCenters: ["session:loose": 32, "group:source": 70, "group:target": 100],
            folderDropFrames: [
                "source": CGRect(x: 50, y: 4, width: 40, height: 40),
                "target": CGRect(x: 80, y: 4, width: 40, height: 40),
            ],
            layout: layout,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: .bottom,
            geometryRevision: 11,
            metrics: PickyHUDDockMetrics(preset: .medium),
            fontScale: 1
        )
        let snapshot = try #require(input.screenSnapshot(
            draggedSessionID: "dragged",
            hudRailFrame: CGRect(x: 20, y: 30, width: 180, height: 60),
            hudPanelFrame: CGRect(x: -900, y: 200, width: 300, height: 400)
        ))

        #expect(snapshot.acceptanceFrame == CGRect(x: -880, y: 510, width: 180, height: 60))
        #expect(snapshot.folderDropFrames["target"] == CGRect(x: -800, y: 526, width: 40, height: 40))
        #expect(snapshot.slotCandidates == [.init(container: .topLevel(index: 0), center: -848)])
        #expect(snapshot.topLevelInsertionCandidates == [
            .init(topLevelIndex: 0, center: -902),
            .init(topLevelIndex: 1, center: -829),
            .init(topLevelIndex: 2, center: -795),
            .init(topLevelIndex: 3, center: -726),
        ])
        #expect(snapshot.layoutFingerprint == PickyHUDDockLayoutFingerprint(
            layout: layout,
            activeSessionIDs: ["dragged", "loose", "member"],
            dockSide: .bottom,
            geometryRevision: 11
        ))
    }

    @Test func screenAxisUsesAppKitCoordinatesForEveryDockSide() {
        let panelFrame = CGRect(x: -900, y: 200, width: 300, height: 400)

        for side in PickyHUDDockSide.allCases {
            let axis = PickyHUDDockExternalDragScreenLayout.screenAxis(
                hudAxis: 50,
                dockSide: side,
                hudPanelFrame: panelFrame
            )
            switch side.orientation {
            case .horizontal: #expect(axis == -850)
            case .vertical: #expect(axis == 550)
            }
        }
    }

    @Test func soleSourceGroupExposesTopLevelWhitespaceTargetsOnHorizontalRail() throws {
        let sourceOnly = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "source", memberSessionIDs: ["dragged"])),
        ])
        let input = PickyHUDDockExternalDragRailGeometryInput(
            slots: [.init(target: .group(id: "source"), visibleIndex: 0)],
            slotCenters: [:],
            topEntryIDs: ["group:source"],
            topEntryAxisCenters: ["group:source": 100],
            folderDropFrames: ["source": CGRect(x: 80, y: 5, width: 40, height: 40)],
            layout: sourceOnly,
            activeSessionIDs: ["dragged"],
            dockSide: .bottom,
            geometryRevision: 1,
            metrics: PickyHUDDockMetrics(preset: .medium),
            fontScale: 1
        )
        let snapshot = try #require(input.screenSnapshot(
            draggedSessionID: "dragged",
            hudRailFrame: CGRect(x: 20, y: 30, width: 220, height: 60),
            hudPanelFrame: CGRect(x: -900, y: 200, width: 300, height: 400)
        ))

        #expect(snapshot.topLevelInsertionCandidates == [
            .init(topLevelIndex: 0, center: -834),
            .init(topLevelIndex: 1, center: -726),
        ])
        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: -834, y: 540),
            geometry: snapshot,
            layout: sourceOnly
        ) == .topLevel(index: 0))
        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: -726, y: 540),
            geometry: snapshot,
            layout: sourceOnly
        ) == .topLevel(index: 1))
    }

    @Test func soleSourceGroupExposesTopLevelWhitespaceTargetsOnVerticalRail() throws {
        let sourceOnly = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "source", memberSessionIDs: ["dragged"])),
        ])
        let input = PickyHUDDockExternalDragRailGeometryInput(
            slots: [.init(target: .group(id: "source"), visibleIndex: 0)],
            slotCenters: [:],
            topEntryIDs: ["group:source"],
            topEntryAxisCenters: ["group:source": 100],
            folderDropFrames: ["source": CGRect(x: 10, y: 80, width: 40, height: 40)],
            layout: sourceOnly,
            activeSessionIDs: ["dragged"],
            dockSide: .left,
            geometryRevision: 1,
            metrics: PickyHUDDockMetrics(preset: .medium),
            fontScale: 1
        )
        let snapshot = try #require(input.screenSnapshot(
            draggedSessionID: "dragged",
            hudRailFrame: CGRect(x: 20, y: 30, width: 60, height: 220),
            hudPanelFrame: CGRect(x: -900, y: 200, width: 300, height: 400)
        ))

        #expect(snapshot.topLevelInsertionCandidates == [
            .init(topLevelIndex: 0, center: -524),
            .init(topLevelIndex: 1, center: -416),
        ])
        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: -850, y: 524),
            geometry: snapshot,
            layout: sourceOnly
        ) == .topLevel(index: 0))
        #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: "dragged",
            sourceGroupID: "source",
            screenPoint: CGPoint(x: -850, y: 416),
            geometry: snapshot,
            layout: sourceOnly
        ) == .topLevel(index: 1))
    }

    @Test func verticalExternalAxisKeepsFirstAndLastWhitespaceInPersistedOrderOnBothSides() throws {
        let mixedLayout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "source", memberSessionIDs: ["dragged"])),
        ])

        for side in [PickyHUDDockSide.left, .right] {
            let input = PickyHUDDockExternalDragRailGeometryInput(
                slots: [
                    .init(target: .session(id: "loose", container: .topLevel(index: 0)), visibleIndex: 0),
                    .init(target: .group(id: "source"), visibleIndex: 1),
                ],
                slotCenters: ["loose": CGPoint(x: 30, y: 70)],
                topEntryIDs: ["session:loose", "group:source"],
                topEntryAxisCenters: ["session:loose": 70, "group:source": 170],
                folderDropFrames: ["source": CGRect(x: 10, y: 130, width: 40, height: 40)],
                layout: mixedLayout,
                activeSessionIDs: ["dragged", "loose"],
                dockSide: side,
                geometryRevision: 1,
                metrics: PickyHUDDockMetrics(preset: .medium),
                fontScale: 1
            )
            let snapshot = try #require(input.screenSnapshot(
                draggedSessionID: "dragged",
                hudRailFrame: CGRect(x: 20, y: 20, width: 60, height: 300),
                hudPanelFrame: CGRect(x: -900, y: 200, width: 300, height: 500)
            ))

            #expect(snapshot.slotCandidates == [.init(container: .topLevel(index: 0), center: -610)])
            #expect(snapshot.topLevelInsertionCandidates == [
                .init(topLevelIndex: 0, center: -664),
                .init(topLevelIndex: 1, center: -560),
                .init(topLevelIndex: 2, center: -456),
            ])
            #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
                draggedSessionID: "dragged",
                sourceGroupID: "source",
                screenPoint: CGPoint(x: -850, y: 456),
                geometry: snapshot,
                layout: mixedLayout
            ) == .topLevel(index: 2))
            #expect(PickyHUDDockExternalDragDestinationResolver.resolve(
                draggedSessionID: "dragged",
                sourceGroupID: "source",
                screenPoint: CGPoint(x: -850, y: 664),
                geometry: snapshot,
                layout: mixedLayout
            ) == .topLevel(index: 0))
        }
    }

    @Test func screenSnapshotRequiresFinitePositiveFramesForEveryRenderedFolder() {
        let slots = [
            PickyDockSlot(target: .session(id: "loose", container: .topLevel(index: 0)), visibleIndex: 0),
            PickyDockSlot(target: .group(id: "source"), visibleIndex: 1),
            PickyDockSlot(target: .group(id: "target"), visibleIndex: 2),
        ]
        func snapshot(folderDropFrames: [String: CGRect]) -> PickyHUDDockExternalDragGeometrySnapshot? {
            PickyHUDDockExternalDragRailGeometryInput(
                slots: slots,
                slotCenters: ["loose": CGPoint(x: 32, y: 18)],
                topEntryIDs: ["session:loose", "group:source", "group:target"],
                topEntryAxisCenters: ["session:loose": 32, "group:source": 70, "group:target": 100],
                folderDropFrames: folderDropFrames,
                layout: layout,
                activeSessionIDs: ["dragged", "loose", "member"],
                dockSide: .bottom,
                geometryRevision: 11,
                metrics: PickyHUDDockMetrics(preset: .medium),
                fontScale: 1
            ).screenSnapshot(
                draggedSessionID: "dragged",
                hudRailFrame: CGRect(x: 20, y: 30, width: 180, height: 60),
                hudPanelFrame: CGRect(x: -900, y: 200, width: 300, height: 400)
            )
        }

        #expect(snapshot(folderDropFrames: [
            "target": CGRect(x: 80, y: 4, width: 40, height: 40),
        ]) == nil)
        #expect(snapshot(folderDropFrames: [
            "source": CGRect(x: 50, y: 4, width: 40, height: 40),
        ]) == nil)
        #expect(snapshot(folderDropFrames: [
            "source": CGRect(x: 50, y: 4, width: 40, height: 40),
            "target": CGRect(x: 80, y: 4, width: 0, height: 40),
        ]) == nil)
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

//
//  PickyHUDDockGroupListStatePolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

private final class DockGroupListHostingProbe {}

@MainActor
struct PickyHUDDockGroupListStatePolicyTests {
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

    // MARK: - S1 row membership drag invalidation

    @Test func rowDragMembershipSnapshotKeepsContentOnlyUpdatesAlive() {
        let rowIDs = ["alpha", "bravo"]
        #expect(PickyHUDDockGroupListDragPolicy.shouldCancelDrag(
            referenceRowIDs: rowIDs,
            currentRowIDs: rowIDs
        ) == false)
    }

    @Test func rowDragMembershipSnapshotCancelsForAddsRemovalsAndReorders() {
        let reference = ["alpha", "bravo"]
        #expect(PickyHUDDockGroupListDragPolicy.shouldCancelDrag(referenceRowIDs: reference, currentRowIDs: ["alpha", "bravo", "charlie"]))
        #expect(PickyHUDDockGroupListDragPolicy.shouldCancelDrag(referenceRowIDs: reference, currentRowIDs: ["alpha"]))
        #expect(PickyHUDDockGroupListDragPolicy.shouldCancelDrag(referenceRowIDs: reference, currentRowIDs: ["bravo", "alpha"]))
        // Dragged-row removal is a membership removal, not a separate weaker guard.
        #expect(PickyHUDDockGroupListDragPolicy.shouldCancelDrag(referenceRowIDs: reference, currentRowIDs: ["bravo"]))
    }

    // MARK: - S2 publisher emission wiring

    @Test func subscriptionOrchestratorForwardsEmittedSnapshotBeforeBackingStorageChanges() {
        let stored = snapshot(groupID: "stored")
        let emitted = snapshot(groupID: "emitted")
        var received: [(PickyHUDDockSnapshot, CGFloat)] = []
        let orchestrator = PickyHUDDockGroupListSubscriptionOrchestrator { snapshot, fontScale in
            received.append((snapshot, fontScale))
        }

        orchestrator.receiveSnapshot(emitted, fontScale: 1.3)

        #expect(received.count == 1)
        #expect(received[0].0 == emitted)
        #expect(received[0].0 != stored)
        #expect(received[0].1 == 1.3)
    }

    @Test func subscriptionOrchestratorForwardsEmittedFontScaleInsteadOfStoredScale() {
        let currentSnapshot = snapshot(groupID: "current")
        var receivedScale: CGFloat?
        let orchestrator = PickyHUDDockGroupListSubscriptionOrchestrator { _, fontScale in
            receivedScale = fontScale
        }

        orchestrator.receiveFontScale(1.3, snapshot: currentSnapshot)

        #expect(receivedScale == 1.3)
        #expect(receivedScale != 1.0)
    }

    // MARK: - S3 child hosting lifecycle

    @Test func hostingLifecyclePreservesSameGroupIdentityAcrossContentUpdates() {
        let lifecycle = PickyHUDDockGroupListHostingLifecycle<DockGroupListHostingProbe>()
        let first = lifecycle.synchronize(groupID: "group") { DockGroupListHostingProbe() }
        let second = lifecycle.synchronize(groupID: "group") { DockGroupListHostingProbe() }

        guard case .created(let firstHosting) = first,
              case .retained(let secondHosting) = second
        else {
            Issue.record("Expected one creation followed by retained hosting")
            return
        }
        #expect(firstHosting === secondHosting)
        #expect(lifecycle.creationCount == 1)
    }

    @Test func hostingLifecycleReplacesOnlyForGroupChangesAndTearsDownOnHide() {
        let lifecycle = PickyHUDDockGroupListHostingLifecycle<DockGroupListHostingProbe>()
        _ = lifecycle.synchronize(groupID: "first") { DockGroupListHostingProbe() }
        let replacement = lifecycle.synchronize(groupID: "second") { DockGroupListHostingProbe() }

        #expect(lifecycle.creationCount == 2)
        if case .created = replacement {
            // expected
        } else {
            Issue.record("A new open group must create one replacement host")
        }
        lifecycle.tearDown()
        #expect(lifecycle.groupID == nil)
        #expect(lifecycle.hosting == nil)
    }

    // MARK: - S4 interaction frame selection

    @Test func outsideDismissFrameUsesInteractionFrameNotTileOnlyBadgeFrame() {
        let badge = CGRect(x: 10, y: 20, width: 54, height: 54)
        let interaction = CGRect(x: 10, y: 20, width: 54, height: 82)
        let hudFrame = CGRect(x: 100, y: 200, width: 400, height: 300)

        let result = PickyHUDDockGroupListOutsideDismissFramePolicy.owningInteractionScreenFrame(
            openGroupID: "group",
            badgeFrames: ["group": badge],
            interactionFrames: ["group": interaction],
            hudPanelFrame: hudFrame
        )

        let expected = PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudFrame,
            swiftUIOrigin: interaction.origin,
            panelSize: interaction.size
        )
        #expect(result == expected)
        #expect(result?.height != badge.height)
    }

    // MARK: - S5 shared activation and picker relay

    @Test func pointerAndCommandActivationUseTheSameProductionRouter() {
        var pickerGroups: [String] = []
        var listGroups: [String] = []
        let route: (Bool) -> Void = { hasVisibleMembers in
            PickyHUDDockGroupActivationRouter.perform(
                groupID: "group",
                hasVisibleMembers: hasVisibleMembers,
                showFolderPicker: { pickerGroups.append($0) },
                toggleMemberList: { listGroups.append($0) }
            )
        }

        route(false) // pointer activation for an empty group
        route(false) // Command-number activation for the same empty group
        route(true) // an empty-to-non-empty snapshot transition

        #expect(pickerGroups == ["group", "group"])
        #expect(listGroups == ["group"])
    }

    @Test func pickerRelayConsumesTargetAndFallsBackWhenTheTargetDisappears() {
        let relay = PickyHUDDockGroupPickerRelay()
        relay.request(groupID: "group")
        #expect(relay.requestedGroupID == "group")
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            requestedGroupID: relay.requestedGroupID,
            renderedGroupIDs: ["group"],
            hasUntargetedAddAnchor: true
        ) == .targeted(groupID: "group"))
        relay.consume()
        #expect(relay.requestedGroupID == nil)

        relay.request(groupID: "deleted")
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            requestedGroupID: relay.requestedGroupID,
            renderedGroupIDs: [],
            hasUntargetedAddAnchor: true
        ) == .untargeted)
        #expect(PickyHUDDockGroupPickerRelayPolicy.presentation(
            requestedGroupID: relay.requestedGroupID,
            renderedGroupIDs: [],
            hasUntargetedAddAnchor: false
        ) == .deferred)
    }

    // MARK: - S6 actual empty-group candidate construction

    @Test func emptyGroupCandidatePolicyBuildsOnlyEmptyProjectedGroupsForResolver() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "empty")),
            .group(PickyDockGroup(id: "nonempty", memberSessionIDs: ["member"])),
        ])
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["loose", "member"]
        )
        let candidates = PickyHUDDockEmptyGroupDropCandidatePolicy.candidates(
            slots: projection.slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            topEntryCenters: ["group:empty": 100, "group:nonempty": 200]
        )
        let nonEmptyCandidates = PickyHUDDockNonEmptyGroupDropCandidatePolicy.candidates(
            slots: projection.slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            topEntryCenters: ["group:empty": 100, "group:nonempty": 200]
        )
        let slotCandidates = projection.slots.compactMap { slot -> PickyDockDropResolver.SlotCandidate? in
            guard let container = slot.container else { return nil }
            return .init(container: container, center: 0)
        }

        #expect(candidates.map(\.groupID) == ["empty"])
        #expect(nonEmptyCandidates.map(\.groupID) == ["nonempty"])
        #expect(PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 100,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: candidates,
            nonEmptyGroupCandidates: nonEmptyCandidates,
            layout: layout,
            slotPitch: 100
        ) == .group(id: "empty", memberIndex: 0))
        #expect(PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 200,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: candidates,
            nonEmptyGroupCandidates: nonEmptyCandidates,
            layout: layout,
            slotPitch: 100
        ) == .group(id: "nonempty", memberIndex: 0))
    }
}

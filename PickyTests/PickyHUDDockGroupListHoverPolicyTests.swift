//
//  PickyHUDDockGroupListHoverPolicyTests.swift
//  PickyTests
//
//  A peek belongs to the pointer, a pin belongs to the user. These rules keep
//  the two from trading places behind the user's back.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListHoverPolicyTests {
    @Test func groupAndSessionHoverDisclosuresUseTheSameCloseGrace() {
        #expect(PickyHUDDockGroupListHoverPolicy.peekGrace == PickyHUDDockLayout.closeDelay)
    }

    @Test func hoveringAFolderWithMembersOpensAPeekWhenNothingIsOpen() {
        #expect(
            PickyHUDDockGroupListHoverPolicy.shouldBeginPeek(
                hoveredGroupID: "a",
                openGroupID: nil,
                presentation: nil,
                hasVisibleMembers: true
            )
        )
    }

    @Test func anEmptyFolderNeverPeeksBecauseItsClickOpensTheCreatePopover() {
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldBeginPeek(
                hoveredGroupID: "a",
                openGroupID: nil,
                presentation: nil,
                hasVisibleMembers: false
            )
        )
    }

    @Test func hoverNeverReplacesOrReopensAPinnedList() {
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldBeginPeek(
                hoveredGroupID: "b",
                openGroupID: "a",
                presentation: .pinned,
                hasVisibleMembers: true
            )
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldBeginPeek(
                hoveredGroupID: "a",
                openGroupID: "a",
                presentation: .pinned,
                hasVisibleMembers: true
            )
        )
    }

    @Test func hoverSwitchesBetweenPeeksButDoesNotRestartTheCurrentOne() {
        #expect(
            PickyHUDDockGroupListHoverPolicy.shouldBeginPeek(
                hoveredGroupID: "b",
                openGroupID: "a",
                presentation: .peek,
                hasVisibleMembers: true
            )
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldBeginPeek(
                hoveredGroupID: "a",
                openGroupID: "a",
                presentation: .peek,
                hasVisibleMembers: true
            )
        )
    }

    @Test func anExplicitKeyboardPinPromotesAPeekAndLeavesAClosedListAlone() {
        #expect(
            PickyHUDDockGroupListHoverPolicy.presentationAfterExplicitPin(current: .peek)
                == .pinned
        )
        #expect(
            PickyHUDDockGroupListHoverPolicy.presentationAfterExplicitPin(current: .pinned)
                == .pinned
        )
        #expect(
            PickyHUDDockGroupListHoverPolicy.presentationAfterExplicitPin(current: nil) == nil
        )
    }

    @Test func hoveringARegularPickleImmediatelyClosesOnlyAPeek() {
        #expect(
            PickyHUDDockGroupListHoverPolicy.shouldCloseForDockSessionHover(presentation: .peek)
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldCloseForDockSessionHover(presentation: .pinned)
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldCloseForDockSessionHover(presentation: nil)
        )
    }

    @Test func draggingAFolderImmediatelyClosesOnlyItsPointerOwnedPeek() {
        #expect(
            PickyHUDDockGroupListHoverPolicy.shouldCloseForDockGroupDrag(presentation: .peek)
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldCloseForDockGroupDrag(presentation: .pinned)
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldCloseForDockGroupDrag(presentation: nil)
        )
    }

    @Test @MainActor func groupDragBeginDismissesThePeekButPreservesAPinnedList() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyHUDDockGroupDragPeekTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = PickySettingsStore(appSupportRoot: root)
        let manager = PickyHUDOverlayManager(
            viewModel: PickySessionListViewModel(
                client: FakePickyAgentClient(),
                notificationCenter: PickyNoopNotificationCenter()
            ),
            appearanceStore: PickyAppearanceStore(settingsStore: settingsStore),
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settingsStore),
            visibilityStore: PickyHUDVisibilityStore(settingsStore: settingsStore),
            settingsStore: settingsStore,
            voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry()
        )
        let displayID: CGDirectDisplayID = 71
        let panel = PickyHUDDockGroupListPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        manager.dockGroupListChildrenByDisplayID[displayID] = .init(
            panel: panel,
            openGroupID: "peek",
            presentation: .peek
        )

        manager.handleDockGroupTileDragBegin(displayID: displayID)

        #expect(manager.dockGroupListChildrenByDisplayID[displayID] == nil)

        manager.dockGroupListChildrenByDisplayID[displayID] = .init(
            panel: panel,
            openGroupID: "pinned",
            presentation: .pinned
        )

        manager.handleDockGroupTileDragBegin(displayID: displayID)

        #expect(manager.dockGroupListChildrenByDisplayID[displayID]?.openGroupID == "pinned")
    }

    @Test func theCorridorSpansTheGapBetweenTheFolderAndItsPanel() {
        let folder = CGRect(x: 100, y: 100, width: 40, height: 40)
        // Ten points to the left, matching the production panel gap.
        let panel = CGRect(x: 0, y: 60, width: 90, height: 120)
        // Inside the gap, which pointer containment alone would reject.
        #expect(
            PickyHUDDockGroupListHoverPolicy.isPointerInPeekCorridor(
                pointer: CGPoint(x: 95, y: 110),
                folderScreenFrame: folder,
                panelScreenFrame: panel
            )
        )
        #expect(
            PickyHUDDockGroupListHoverPolicy.isPointerInPeekCorridor(
                pointer: CGPoint(x: 120, y: 120),
                folderScreenFrame: folder,
                panelScreenFrame: panel
            )
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.isPointerInPeekCorridor(
                pointer: CGPoint(x: 400, y: 400),
                folderScreenFrame: folder,
                panelScreenFrame: panel
            )
        )
    }

    @Test func aMissingFolderFrameFallsBackToThePanelAlone() {
        let panel = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(
            PickyHUDDockGroupListHoverPolicy.isPointerInPeekCorridor(
                pointer: CGPoint(x: 50, y: 50),
                folderScreenFrame: nil,
                panelScreenFrame: panel
            )
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.isPointerInPeekCorridor(
                pointer: CGPoint(x: 150, y: 50),
                folderScreenFrame: nil,
                panelScreenFrame: panel
            )
        )
    }

    @Test func reenteringTheCorridorRestartsTheGraceWindow() {
        let start = Date()
        #expect(
            PickyHUDDockGroupListHoverPolicy.outsideSince(
                current: nil,
                isPointerInCorridor: false,
                now: start
            ) == start
        )
        // A continuing absence keeps the original timestamp.
        #expect(
            PickyHUDDockGroupListHoverPolicy.outsideSince(
                current: start,
                isPointerInCorridor: false,
                now: start.addingTimeInterval(0.1)
            ) == start
        )
        #expect(
            PickyHUDDockGroupListHoverPolicy.outsideSince(
                current: start,
                isPointerInCorridor: true,
                now: start.addingTimeInterval(0.1)
            ) == nil
        )
    }

    @Test func aPeekClosesOnlyAfterTheFullGraceOutsideTheCorridor() {
        let outsideSince = Date()
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldClosePeek(
                presentation: .peek,
                isPointerInCorridor: false,
                outsideSince: outsideSince,
                now: outsideSince.addingTimeInterval(0.1),
                grace: 0.25
            )
        )
        #expect(
            PickyHUDDockGroupListHoverPolicy.shouldClosePeek(
                presentation: .peek,
                isPointerInCorridor: false,
                outsideSince: outsideSince,
                now: outsideSince.addingTimeInterval(0.25),
                grace: 0.25
            )
        )
    }

    @Test func graceNeverClosesAPinnedListOrOneThePointerStillOccupies() {
        let outsideSince = Date()
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldClosePeek(
                presentation: .pinned,
                isPointerInCorridor: false,
                outsideSince: outsideSince,
                now: outsideSince.addingTimeInterval(10),
                grace: 0.25
            )
        )
        #expect(
            !PickyHUDDockGroupListHoverPolicy.shouldClosePeek(
                presentation: .peek,
                isPointerInCorridor: true,
                outsideSince: nil,
                now: outsideSince.addingTimeInterval(10),
                grace: 0.25
            )
        )
    }
}

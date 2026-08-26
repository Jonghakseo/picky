//
//  PickyHUDDockGroupListHeaderEditPolicyTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupListHeaderEditPolicyTests {
    @Test func trimsAndCommitsChangedGroupName() {
        let committed = PickyHUDDockGroupListHeaderEditPolicy.committedName(
            draft: "  Platform work  ",
            currentStoredName: "Current name",
            shouldCommit: true
        )

        #expect(committed == "Platform work")
    }

    @Test func ignoresNameThatMatchesStoredNameAfterTrimming() {
        let committed = PickyHUDDockGroupListHeaderEditPolicy.committedName(
            draft: "  Current name  ",
            currentStoredName: "Current name",
            shouldCommit: true
        )

        #expect(committed == nil)
    }

    @Test func commitsAnEmptyNameWhenItChangesFromANamedGroup() {
        let committed = PickyHUDDockGroupListHeaderEditPolicy.committedName(
            draft: "   ",
            currentStoredName: "Current name",
            shouldCommit: true
        )

        #expect(committed == "")
    }

    @Test func cancellationDoesNotCommitTheDraft() {
        let committed = PickyHUDDockGroupListHeaderEditPolicy.committedName(
            draft: "Changed name",
            currentStoredName: "Current name",
            shouldCommit: false
        )

        #expect(committed == nil)
    }

    @Test func childListPanelIsKeyableOnlyForNeededNativeInput() {
        let panel = PickyHUDDockGroupListPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func parentKeyRestorationRequiresAnEndedEditAndKeyChildPanel() {
        #expect(
            PickyHUDDockGroupListPanelKeyPolicy.shouldRestoreOwningHUDKey(
                isEditing: false,
                isChildPanelKeyWindow: true
            )
        )
        #expect(
            !PickyHUDDockGroupListPanelKeyPolicy.shouldRestoreOwningHUDKey(
                isEditing: true,
                isChildPanelKeyWindow: true
            )
        )
        #expect(
            !PickyHUDDockGroupListPanelKeyPolicy.shouldRestoreOwningHUDKey(
                isEditing: false,
                isChildPanelKeyWindow: false
            )
        )
    }

    @Test func colorMenuUsesPaletteOrderAndMarksTheCurrentColor() {
        let items = PickyHUDDockGroupListHeaderEditPolicy.colorMenuItems(currentColor: .purple)

        #expect(items.map(\.color) == PickyDockGroupColor.palette)
        #expect(items.filter(\.isSelected).map(\.color) == [.purple])
    }
}

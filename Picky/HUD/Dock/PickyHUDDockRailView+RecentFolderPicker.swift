//
//  PickyHUDDockRailView+RecentFolderPicker.swift
//  Picky
//
//  Recent-folder picker anchoring and presentation ownership. The dock `+`
//  and each group header's `+` share one popover; the anchor that opened it
//  also decides which group receives the new Pickle.
//

import SwiftUI

extension PickyHUDDockRailView {
    func showRecentPickleFolderPicker(anchorGroupID: String?) {
        newPickleAnchorGroupID = anchorGroupID
        PickyPerf.event("new_pickle_show_request")
        updateDockAddSlotExpansion(pickerIsPresented: true)
        isRecentPickleFolderPickerPresented = true
    }

    func updateDockAddSlotExpansion(pickerIsPresented: Bool) {
        let expanded = PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: pickerIsPresented,
            activeAnchorGroupID: newPickleAnchorGroupID
        )
        withAnimation(PickyHUDExpansion.animation) {
            isAddSlotExpanded = expanded
        }
        onAddSlotExpandedChanged(expanded)
    }

    func isPickerPresented(anchorGroupID: String?) -> Bool {
        PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: isRecentPickleFolderPickerPresented,
            activeAnchorGroupID: newPickleAnchorGroupID,
            anchorGroupID: anchorGroupID
        )
    }

    private func newPicklePickerBinding(anchorGroupID: String?) -> Binding<Bool> {
        Binding(
            get: { isPickerPresented(anchorGroupID: anchorGroupID) },
            set: { isPresented in
                if isPresented {
                    showRecentPickleFolderPicker(anchorGroupID: anchorGroupID)
                } else if newPickleAnchorGroupID == anchorGroupID {
                    isRecentPickleFolderPickerPresented = false
                    newPickleAnchorGroupID = nil
                }
            }
        )
    }

    func newPicklePicker<Anchor: View>(
        anchoredTo anchor: Anchor,
        anchorGroupID: String?
    ) -> some View {
        anchor.recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(anchorGroupID: anchorGroupID),
            onPresentationAcknowledged: {},
            arrowEdge: recentPickleFolderPickerArrowEdge,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            onCreatePickleInRecentFolder: { cwd in
                createPickleInRecentFolder(cwd)
            },
            onChooseFolder: {
                chooseFolderForNewPickle()
            },
            onRemoveRecentPickleFolder: onRemoveRecentPickleFolder,
            onPinPickleFolder: onPinPickleFolder,
            onUnpinPickleFolder: onUnpinPickleFolder,
            onReorderPinnedPickleFolders: onReorderPinnedPickleFolders,
            // Use the full live list so members of collapsed groups remain selectable.
            availableSessionsForGroupCreation: sessions,
            suggestedGroupColor: PickyDockGroupColor.defaultColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
    }

    private func createPickleInRecentFolder(_ cwd: String) {
        let targetGroupID = newPickleAnchorGroupID
        isRecentPickleFolderPickerPresented = false
        newPickleAnchorGroupID = nil
        onCreatePickleInRecentFolder(cwd, targetGroupID)
    }

    private func chooseFolderForNewPickle() {
        let targetGroupID = newPickleAnchorGroupID
        isRecentPickleFolderPickerPresented = false
        newPickleAnchorGroupID = nil
        onCreatePickle(targetGroupID)
    }

    var addAgentSlotButton: some View {
        let isEmptyDock = baseProjection.items.isEmpty
        return newPicklePicker(
            anchoredTo: Button {
                PickyPerf.event("new_pickle_button_action")
                showRecentPickleFolderPicker(anchorGroupID: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: isEmptyDock ? 16 : metrics.plusFontSize, weight: .medium)) // design-token-exception: approved larger empty-dock action and compact utility glyph.
                    .foregroundStyle(DS.Colors.accentText)
                    .frame(
                        width: isEmptyDock ? emptyDockAddSize.width : metrics.utilityButtonSide,
                        height: isEmptyDock ? emptyDockAddSize.height : metrics.utilityButtonSide
                    )
                    .background(
                        isEmptyDock ? DS.Colors.accentSubtle : .clear,
                        in: RoundedRectangle(cornerRadius: metrics.rowCornerRadius)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(PickyHUDDockUtilityButtonStyle()),
            anchorGroupID: nil
        )
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
    }

    /// The empty dock's add action fills one row (vertical) or chip (horizontal).
    private var emptyDockAddSize: CGSize {
        switch dockSide.orientation {
        case .vertical:
            CGSize(width: metrics.listWidth - metrics.horizontalPadding * 2, height: metrics.rowHeight(fontScale: fontScale))
        case .horizontal:
            CGSize(width: metrics.chipWidth, height: metrics.chipHeight(fontScale: fontScale))
        }
    }

    private var recentPickleFolderPickerArrowEdge: Edge {
        switch dockSide {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }
}

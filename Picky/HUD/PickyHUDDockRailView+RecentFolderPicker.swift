//
//  PickyHUDDockRailView+RecentFolderPicker.swift
//  Picky
//
//  Recent-folder picker relay, anchoring, and presentation ownership.
//

import SwiftUI

extension PickyHUDDockRailView {
    var renderedGroupIDs: Set<String> {
        Set(projection.items.compactMap { item -> String? in
            guard case .group(let group) = item else { return nil }
            return group.id
        })
    }

    private var pickerAnchorGroupIDs: Set<String> {
        PickyHUDPickerAnchorVisibilityPolicy.visibleAnchorGroupIDs(
            renderedGroupIDs: renderedGroupIDs,
            badgeFrames: groupPickerBadgeFrames,
            viewportFrame: sessionsViewportFrame,
            needsScroll: overflowLayout.needsScroll
        )
    }

    func presentPendingPickleFolderPickerIfPossible() {
        guard let request = pendingPickleFolderPickerRequest else { return }
        switch PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: pickerAnchorGroupIDs,
            hasUntargetedAddAnchor: true
        ) {
        case .targeted(let groupID):
            showRecentPickleFolderPicker(
                anchorGroupID: groupID,
                targetGroupID: groupID,
                request: request
            )
        case .untargeted(let targetGroupID):
            showRecentPickleFolderPicker(
                anchorGroupID: nil,
                targetGroupID: targetGroupID,
                request: request
            )
        case .deferred:
            break
        }
    }

    private func acknowledgePickleFolderPickerPresentation(requestID: UUID) {
        onPickleFolderPickerPresentationAcknowledged(requestID)
    }

    private func showRecentPickleFolderPicker(
        anchorGroupID: String?,
        targetGroupID: String?,
        request: PickyHUDDockGroupPickerRequest? = nil
    ) {
        newPickleAnchorGroupID = anchorGroupID
        newPickleTargetGroupID = targetGroupID
        pickleFolderPickerPresentationRequest = request
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

    private func newPicklePickerBinding(anchorGroupID: String?) -> Binding<Bool> {
        Binding(
            get: {
                PickyHUDDockNewPicklePopoverPolicy.isPresented(
                    pickerIsPresented: isRecentPickleFolderPickerPresented,
                    activeAnchorGroupID: newPickleAnchorGroupID,
                    anchorGroupID: anchorGroupID
                )
            },
            set: { isPresented in
                if isPresented {
                    showRecentPickleFolderPicker(
                        anchorGroupID: anchorGroupID,
                        targetGroupID: anchorGroupID
                    )
                } else if newPickleAnchorGroupID == anchorGroupID {
                    isRecentPickleFolderPickerPresented = false
                    newPickleAnchorGroupID = nil
                    newPickleTargetGroupID = nil
                    pickleFolderPickerPresentationRequest = nil
                }
            }
        )
    }


    func newPicklePicker<Anchor: View>(
        anchoredTo anchor: Anchor,
        anchorGroupID: String?
    ) -> some View {
        let presentationRequestID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: anchorGroupID,
            activeAnchorGroupID: newPickleAnchorGroupID,
            activeRequest: pickleFolderPickerPresentationRequest
        )
        return anchor.recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(anchorGroupID: anchorGroupID),
            onPresentationAcknowledged: {
                guard let presentationRequestID else { return }
                acknowledgePickleFolderPickerPresentation(requestID: presentationRequestID)
            },
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
            // Use the full live list, not the collapsed projection slots, so
            // members hidden behind folder tiles remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
    }

    private func createPickleInRecentFolder(_ cwd: String) {
        let targetGroupID = newPickleTargetGroupID
        isRecentPickleFolderPickerPresented = false
        newPickleAnchorGroupID = nil
        newPickleTargetGroupID = nil
        pickleFolderPickerPresentationRequest = nil
        onCreatePickleInRecentFolder(cwd, targetGroupID)
    }

    private func chooseFolderForNewPickle() {
        let targetGroupID = newPickleTargetGroupID
        isRecentPickleFolderPickerPresented = false
        newPickleAnchorGroupID = nil
        newPickleTargetGroupID = nil
        pickleFolderPickerPresentationRequest = nil
        onCreatePickle(targetGroupID)
    }

    var addAgentSlotButton: some View {
        let presentationRequestID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: nil,
            activeAnchorGroupID: newPickleAnchorGroupID,
            activeRequest: pickleFolderPickerPresentationRequest
        )
        return Button {
            showRecentPickleFolderPicker(anchorGroupID: nil, targetGroupID: nil)
        } label: {
            ZStack {
                PickyHUDMaterialFill(
                    shape: RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous),
                    fallback: DS.Colors.surface1
                )
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                    .strokeBorder(
                        DS.Colors.textTertiary.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                    )
                Image(systemName: "plus")
                    .font(.system(size: metrics.plusFontSize, weight: .medium)) // design-token-exception: preserves the existing dock add-slot SF Symbol optical size during ownership extraction
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: metrics.addSlotButtonSide, height: metrics.addSlotButtonSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(anchorGroupID: nil),
            onPresentationAcknowledged: {
                guard let presentationRequestID else { return }
                acknowledgePickleFolderPickerPresentation(requestID: presentationRequestID)
            },
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
            // Use the full live list, not the collapsed projection slots, so
            // members hidden behind folder tiles remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
        .hoverAffordance()
    }

    /// Accent color the next group will adopt. Surfaced to the creator
    /// popover so the user sees the swatch alongside the name field. New
    /// groups always default to a neutral gray.
    private var nextSuggestedGroupColor: PickyDockGroupColor {
        PickyDockGroupColor.defaultColor
    }

    var collapsibleAddAgentSlot: some View {
        let presentationRequestID = PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: nil,
            activeAnchorGroupID: newPickleAnchorGroupID,
            activeRequest: pickleFolderPickerPresentationRequest
        )
        return Button {
            showRecentPickleFolderPicker(anchorGroupID: nil, targetGroupID: nil)
        } label: {
            ZStack {
                ZStack {
                    PickyHUDMaterialFill(
                        shape: RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous),
                        fallback: DS.Colors.surface1
                    )
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                    RoundedRectangle(cornerRadius: metrics.iconCornerRadius, style: .continuous)
                        .strokeBorder(
                            DS.Colors.textTertiary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: metrics.plusFontSize, weight: .medium)) // design-token-exception: preserves the existing dock add-slot SF Symbol optical size during ownership extraction
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: metrics.addSlotButtonSide, height: metrics.addSlotButtonSide)
                .opacity(isAddSlotExpanded ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(DS.Colors.textSecondary.opacity(0.78))
                    .frame(
                        width: dockSide.orientation == .horizontal ? metrics.collapsedDashHeight : metrics.collapsedDashWidth,
                        height: dockSide.orientation == .horizontal ? metrics.collapsedDashWidth : metrics.collapsedDashHeight
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 1, y: 0.4) // design-token-exception: preserves the existing collapsed dock add-slot depth cue during ownership extraction
                    .opacity(isAddSlotExpanded ? 0 : 1)
            }
            .frame(
                width: dockSide.orientation == .horizontal
                    ? PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
                    : metrics.addSlotButtonSide,
                height: dockSide.orientation == .horizontal
                    ? metrics.addSlotButtonSide
                    : PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .recentPickleFolderPicker(
            isPresented: newPicklePickerBinding(anchorGroupID: nil),
            onPresentationAcknowledged: {
                guard let presentationRequestID else { return }
                acknowledgePickleFolderPickerPresentation(requestID: presentationRequestID)
            },
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
            // Use the full live list, not the collapsed projection slots, so
            // members hidden behind folder tiles remain selectable.
            availableSessionsForGroupCreation: allSessions,
            suggestedGroupColor: nextSuggestedGroupColor,
            onCreateGroup: { name, memberIDs in
                _ = onCreateDockGroup(name, memberIDs)
            }
        )
        .onHover { hovering in
            let pickerKeepsExpanded = PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
                pickerIsPresented: isRecentPickleFolderPickerPresented,
                activeAnchorGroupID: newPickleAnchorGroupID
            )
            let expanded = hovering || pickerKeepsExpanded
            onAddSlotExpandedChanged(expanded)
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = expanded
            }
        }
        .accessibilityLabel(L10n.t("dock.startPickle"))
        .accessibilityHint(L10n.t("dock.startPickle.hint"))
        .hoverAffordance()
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

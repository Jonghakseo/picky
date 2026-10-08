import SwiftUI

extension PickyHUDDockRailView {
    /// Names and secondary controls share one row, instead of widening each
    /// icon cell. The last hovered target survives the crossing into this row.
    var horizontalPreview: some View {
        HStack(spacing: DS.Spacing.space2) {
            switch resolvedHorizontalPreviewTarget {
            case .session(let id):
                if let session = sessions.first(where: { $0.id == id }) {
                    Text(PickyHUDDockRowStatusPresentation.title(for: session))
                        .pickyFont(size: metrics.pickleTitleFontSize, weight: .medium)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DS.Spacing.space1)
                    Text(PickyHUDDockRowStatusPresentation.label(session.status))
                        .font(PickyHUDTypography.meta)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Button { onArchiveSession(id) } label: {
                        Image(systemName: "archivebox")
                            .font(PickyHUDTypography.supporting)
                            .frame(width: metrics.rowActionSide, height: metrics.rowActionSide)
                    }
                    .buttonStyle(PickyHUDDockUtilityButtonStyle())
                    .help(L10n.t("group.list.action.archive"))
                    .accessibilityLabel(L10n.t("group.list.action.archive"))
                }
            case .group(let id):
                if let group = layout.group(withID: id) {
                    let activeIDs = Set(sessions.map(\.id))
                    Text(group.displayName)
                        .font(PickyHUDTypography.supportingSemibold)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DS.Spacing.space1)
                    Text("\(group.memberSessionIDs.filter(activeIDs.contains).count)")
                        .font(PickyHUDTypography.meta)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize()
                    Button {
                        PickyHUDDockGroupColorMenu.present(current: group.color) { onSetDockGroupColor(id, $0) }
                    } label: {
                        RoundedRectangle(cornerRadius: metrics.groupHeaderSwatchCornerRadius)
                            .fill(group.color.accent)
                            .frame(width: metrics.groupHeaderSwatchSide, height: metrics.groupHeaderSwatchSide)
                            .frame(width: metrics.rowActionSide, height: metrics.rowActionSide)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PickyHUDDockUtilityButtonStyle())
                    .help(PickyHUDDockGroupContextMenuPresentation.colorTitle)
                    .accessibilityLabel(PickyHUDDockGroupContextMenuPresentation.colorTitle)
                    .accessibilityValue(group.color.localizedName)
                    // An expanded group owns a `+` slot (and the picker anchor)
                    // in the rail itself; a second `+` here would compete with it.
                    if !showsHorizontalGroupAddSlot(group) {
                        newPicklePicker(anchoredTo: PickyHUDDockGroupAddButton(side: metrics.rowActionSide) {
                            showRecentPickleFolderPicker(anchorGroupID: id)
                        }, anchorGroupID: id)
                    }
                }
            case .groupAdd(let id):
                if let group = layout.group(withID: id) {
                    Text(L10n.t("dock.group.startPickle.preview", group.displayName))
                        .font(PickyHUDTypography.supporting)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            case .newPickle:
                Text(L10n.t("dock.startPickle"))
                    .font(PickyHUDTypography.supporting)
                Spacer(minLength: 0)
            case .archive:
                Text(L10n.t("hud.archivedList.title"))
                    .font(PickyHUDTypography.supporting)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(DS.Colors.textSecondary)
        .accessibilityIdentifier("dock.horizontal.preview")
    }
}

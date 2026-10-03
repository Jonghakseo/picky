//
//  PickyScheduledMessagesBarView.swift
//  Picky
//
//  Scheduled-messages surface above the composer: one collapsed summary line
//  plus a floating grouped panel. Queued follow-ups and delayed-action timed
//  messages share it, because from the user's side both are "messages that
//  have not been sent yet".
//

import SwiftUI

/// Row-level actions in the Slack-style hover toolbar.
enum PickyScheduledMessageAction: Equatable {
    case sendNow
    case edit
    case delete
}

/// Collapsed one-line summary. Tapping it toggles the floating panel.
struct PickyScheduledMessagesBarView: View {
    let presentation: PickyScheduledMessagesPresentation
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.Spacing.space1) {
                Image(systemName: "calendar.badge.clock")
                    .accessibilityHidden(true)
                Text(presentation.summaryText)
                    .font(PickyHUDTypography.statusSemibold)
                if let nextText = presentation.nextText {
                    Text(nextText)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .font(PickyHUDTypography.statusSemibold)
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.space2)
            .frame(minHeight: Self.minimumHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isExpanded ? DS.Colors.surface2 : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .help(L10n.t(isExpanded ? "hud.scheduled.collapse.help" : "hud.scheduled.expand.help"))
        .accessibilityLabel(L10n.t("hud.scheduled.accessibilityLabel"))
        .accessibilityValue(presentation.accessibilityValue)
    }

    static let minimumHeight: CGFloat = 28
}

/// The composer's whole scheduled surface: the collapsed summary plus the
/// floating panel wired to its per-row commands. It lives next to the views it
/// composes so the composer itself keeps only draft-level concerns.
struct PickyComposerScheduledSurface: View {
    let presentation: PickyScheduledMessagesPresentation
    @ObservedObject var model: PickyComposerScheduledModel
    let commands: any PickySessionCommands
    let sessionID: String
    let maxHeight: CGFloat
    /// What an edit should restore when it is cancelled or saved.
    let currentDraft: String
    let applyDraft: (String) -> Void

    var body: some View {
        if presentation.isVisible {
            PickyScheduledMessagesBarView(
                presentation: presentation,
                isExpanded: model.isPanelExpanded,
                onToggle: { model.togglePanel() }
            )
            .overlay(alignment: .bottom) {
                if model.isPanelExpanded {
                    panel
                        // Bottom-aligned to the summary line, then lifted past it by
                        // the line's height plus a gap, so the panel floats over the
                        // transcript instead of covering the line or pushing layout.
                        .padding(.bottom, PickyScheduledMessagesBarView.minimumHeight + DS.Spacing.space2)
                        .transition(.opacity)
                }
            }
            .zIndex(2)
        }
    }

    private var panel: some View {
        PickyScheduledMessagesPanelView(
            presentation: presentation,
            maxHeight: maxHeight,
            editingRowID: model.editing?.id,
            pendingDeleteRowID: model.pendingDeleteRowID,
            actionErrorRowID: model.actionErrorRowID,
            actionError: model.actionError,
            onAction: { row, action in
                model.handleRowAction(
                    row,
                    action: action,
                    commands: commands,
                    sessionID: sessionID,
                    currentDraft: currentDraft,
                    applyDraft: applyDraft
                )
            },
            onConfirmDelete: { row in
                model.confirmDelete(row, commands: commands, sessionID: sessionID, applyDraft: applyDraft)
            },
            onCancelDelete: { model.cancelDelete() }
        )
    }
}

/// Floating grouped list. It overlays the transcript instead of pushing it, so
/// opening the panel never changes the conversation's scroll position.
struct PickyScheduledMessagesPanelView: View {
    let presentation: PickyScheduledMessagesPresentation
    let maxHeight: CGFloat
    /// Row currently being edited in the composer, highlighted here.
    let editingRowID: String?
    /// Row whose delete confirmation is showing.
    let pendingDeleteRowID: String?
    let actionErrorRowID: String?
    let actionError: String?
    let onAction: (PickyScheduledMessageRow, PickyScheduledMessageAction) -> Void
    let onConfirmDelete: (PickyScheduledMessageRow) -> Void
    let onCancelDelete: () -> Void

    @State private var hoveredRowID: String?

    var body: some View {
        // An overlay proposes the summary line's ~28pt height, and a bare
        // ScrollView accepts it, which squeezed the list to one visible line.
        // Size the panel from its own content instead, capped at `maxHeight`.
        PickyScheduledPanelListLayout(maxHeight: maxHeight) {
            listContent.hidden().accessibilityHidden(true)
            ScrollView(.vertical, showsIndicators: true) {
                listContent
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2)
                .shadow(
                    color: .black.opacity(DS.Elevation.floatingPanelShadowOpacity),
                    radius: DS.Elevation.floatingPanelShadowRadius,
                    y: DS.Elevation.floatingPanelShadowYOffset
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.scheduled.accessibilityLabel"))
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            ForEach(presentation.groups) { group in
                VStack(alignment: .leading, spacing: Self.groupRowSpacing) {
                    groupHeader(group)
                    ForEach(group.rows) { row in
                        rowView(row)
                    }
                }
            }
            if let actionError {
                Text(actionError)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, DS.Spacing.space2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(_ group: PickyScheduledMessageGroup) -> some View {
        HStack(spacing: DS.Spacing.space1) {
            Text(group.title)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.textSecondary)
            if let detail = group.detail {
                Text(L10n.t("hud.scheduled.group.detail", detail))
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DS.Spacing.space2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowView(_ row: PickyScheduledMessageRow) -> some View {
        if pendingDeleteRowID == row.id {
            deleteConfirmRow(row)
        } else {
            messageRow(row)
        }
    }

    private func deleteConfirmRow(_ row: PickyScheduledMessageRow) -> some View {
        HStack(spacing: DS.Spacing.space3) {
            Text(L10n.t("hud.scheduled.delete.confirm"))
                .font(PickyHUDTypography.bodyCompact)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L10n.t("common.cancel")) { onCancelDelete() }
                .buttonStyle(.plain)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.textSecondary)
                .hoverAffordance()
            Button(L10n.t("hud.scheduled.delete.action")) { onConfirmDelete(row) }
                .buttonStyle(.plain)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.destructiveText)
                .hoverAffordance()
        }
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, DS.Spacing.space1)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.destructive.opacity(0.10))
        )
    }

    private func messageRow(_ row: PickyScheduledMessageRow) -> some View {
        let isEditing = editingRowID == row.id
        let isHovered = hoveredRowID == row.id
        // The row whose command failed keeps the error attached to it; the
        // message itself is printed once at the bottom of the panel.
        let hasFailed = actionErrorRowID == row.id
        return HStack(alignment: .center, spacing: DS.Spacing.space2) {
            if isEditing {
                Image(systemName: "pencil")
                    .font(PickyHUDTypography.statusSemibold)
                    .foregroundColor(DS.Colors.accentText)
                    .accessibilityHidden(true)
            }
            Text(row.text)
                .font(PickyHUDTypography.bodyCompact)
                .foregroundColor(rowTextColor(isEditing: isEditing, hasFailed: hasFailed))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered && row.isActionable {
                rowToolbar(row)
            }
        }
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, DS.Spacing.space1)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(isEditing ? DS.Colors.accentSubtle : (isHovered ? DS.Colors.surface3 : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredRowID = row.id }
            else if hoveredRowID == row.id { hoveredRowID = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.text)
    }

    private func rowToolbar(_ row: PickyScheduledMessageRow) -> some View {
        HStack(spacing: DS.Spacing.space3) {
            toolbarButton(row, action: .sendNow, systemImage: "paperplane", labelKey: "hud.scheduled.row.sendNow")
            toolbarButton(row, action: .edit, systemImage: "pencil", labelKey: "hud.scheduled.row.edit")
            toolbarButton(row, action: .delete, systemImage: "trash", labelKey: "hud.scheduled.row.delete")
        }
        .font(PickyHUDTypography.bodyCompact)
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, Self.toolbarVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func toolbarButton(
        _ row: PickyScheduledMessageRow,
        action: PickyScheduledMessageAction,
        systemImage: String,
        labelKey: String
    ) -> some View {
        Button { onAction(row, action) } label: {
            Image(systemName: systemImage)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .help(L10n.t(labelKey))
        .accessibilityLabel(L10n.t(labelKey))
    }

    private func rowTextColor(isEditing: Bool, hasFailed: Bool) -> Color {
        if hasFailed { return DS.Colors.destructiveText }
        return isEditing ? DS.Colors.textSecondary : DS.Colors.textPrimary
    }

    private static let groupRowSpacing: CGFloat = 2
    private static let toolbarVerticalPadding: CGFloat = 3
}

/// Sizes the panel to its document height up to `maxHeight`, ignoring the
/// height its container proposes. Subview 0 is an unplaced measuring copy of
/// the rows; subview 1 is the scroll view that is actually shown.
private struct PickyScheduledPanelListLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let documentHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(documentHeight, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Telegram-style edit bar: names what the composer is currently editing.
struct PickyScheduledMessageEditBarView: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.space2) {
            Image(systemName: "pencil")
                .foregroundColor(DS.Colors.accentText)
                .accessibilityHidden(true)
            Text(L10n.t("hud.scheduled.editing"))
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L10n.t("common.cancel"), action: onCancel)
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .hoverAffordance()
                .help(L10n.t("hud.scheduled.editing.cancel.help"))
        }
        .font(PickyHUDTypography.statusSemibold)
        .padding(.horizontal, DS.Spacing.space2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.scheduled.editing"))
    }
}

//
//  PickyPendingSteerBubbleView.swift
//  Picky
//
//  A queued steer: an ordinary user bubble, dimmed until the Pickle takes it.
//  Hovering shows a Slack-style toolbar over the bubble's top edge so the
//  message can be pulled back for editing or its send cancelled, the same
//  per-item control scheduled messages have.
//

import SwiftUI

struct PickyPendingSteerBubbleView: View {
    let item: PickyQueueItem
    let message: PickySessionMessage
    let sessionID: String
    let commands: any PickySessionCommands

    @State private var isHovered = false
    @State private var isConfirmingCancel = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        PickyUserBubbleView(message: message, timestamp: .sent(at: item.enqueuedAt))
            .opacity(Self.dimmedOpacity)
            .overlay(alignment: .topTrailing) {
                if item.id != nil, isHovered || isConfirmingCancel || errorText != nil {
                    controls
                        .offset(y: -Self.toolbarLift)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if !hovering, !isWorking { errorText = nil }
            }
            .accessibilityValue(L10n.t("hud.queue.pending.steer"))
            .accessibilityAction(named: Text(L10n.t("hud.queue.steer.cancel"))) { cancel() }
    }

    /// Dimming is the only difference from a delivered message, so the bubble
    /// keeps its identity when agentd materializes the real `user_text`.
    static let dimmedOpacity: Double = 0.6
    private static let toolbarLift: CGFloat = 12
    /// Same compact toolbar metric as the scheduled-message rows.
    private static let toolbarVerticalPadding: CGFloat = 3

    @ViewBuilder
    private var controls: some View {
        if let errorText {
            pill {
                Text(errorText)
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(1)
            }
        } else if isConfirmingCancel {
            pill {
                Text(L10n.t("hud.queue.steer.cancel.confirm"))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Button(L10n.t("hud.queue.steer.cancel.keep")) { isConfirmingCancel = false }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textSecondary)
                    .hoverAffordance()
                Button(L10n.t("hud.queue.steer.cancel")) { cancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.destructiveText)
                    .hoverAffordance()
                    .disabled(isWorking)
            }
            .font(PickyHUDTypography.statusSemibold)
        } else {
            pill {
                // Screen context cannot be put back into the composer, so a
                // screen-attached steer can only be cancelled, not edited.
                if (item.attachedImagesCount ?? 0) == 0 {
                    iconButton("pencil", labelKey: "hud.queue.steer.edit") { edit() }
                }
                iconButton("xmark", labelKey: "hud.queue.steer.cancel") { isConfirmingCancel = true }
            }
            .font(PickyHUDTypography.bodyCompact)
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DS.Spacing.space3) { content() }
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

    private func iconButton(_ systemImage: String, labelKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.textSecondary)
        .hoverAffordance()
        .disabled(isWorking)
        .help(L10n.t(labelKey))
        .accessibilityLabel(L10n.t(labelKey))
    }

    /// Removes the steer first and only then moves its text into the composer,
    /// so a steer the Pickle already took is never duplicated as a draft.
    private func edit() {
        guard let itemID = item.id, !isWorking else { return }
        let text = PickyQueuedInputText.displayText(from: item.text)
        run(itemID) { commands.appendComposerDraftText(text, sessionID: sessionID) }
    }

    private func cancel() {
        guard let itemID = item.id, !isWorking else { return }
        run(itemID) {}
    }

    private func run(_ itemID: String, onRemoved: @escaping () -> Void) {
        isWorking = true
        errorText = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await commands.removeQueuedInput(sessionID: sessionID, itemID: itemID)
                isConfirmingCancel = false
                onRemoved()
            } catch {
                isConfirmingCancel = false
                errorText = L10n.t("hud.queue.steer.cancel.failed")
            }
        }
    }
}

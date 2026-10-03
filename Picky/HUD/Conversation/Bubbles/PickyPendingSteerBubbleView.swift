//
//  PickyPendingSteerBubbleView.swift
//  Picky
//
//  A queued steer: an ordinary user bubble, dimmed until the Pickle takes it.
//  Low-emphasis "수정 · 전송 취소" links stay under the bubble the whole time,
//  so the message can be pulled back or cancelled without hunting for a hover
//  target.
//

import SwiftUI

struct PickyPendingSteerBubbleView: View {
    let item: PickyQueueItem
    let message: PickySessionMessage
    let sessionID: String
    let commands: any PickySessionCommands

    @State private var isConfirmingCancel = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.linkRowSpacing) {
            PickyUserBubbleView(message: message, timestamp: .sent(at: item.enqueuedAt))
                .opacity(Self.dimmedOpacity)
                .accessibilityValue(L10n.t("hud.queue.pending.steer"))
            if item.id != nil {
                controls
                    .font(PickyHUDTypography.status)
                    .lineLimit(1)
                    .padding(.trailing, DS.Spacing.space1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Dimming is the only difference from a delivered message, so the bubble
    /// keeps its identity when agentd materializes the real `user_text`.
    static let dimmedOpacity: Double = 0.6
    /// Pulls the link row close to the bubble so it reads as its caption.
    private static let linkRowSpacing: CGFloat = 2

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: DS.Spacing.space1) {
            if let errorText {
                Text(errorText)
                    .foregroundColor(DS.Colors.destructiveText)
            } else if isConfirmingCancel {
                Text(L10n.t("hud.queue.steer.cancel.confirm"))
                    .foregroundColor(DS.Colors.textSecondary)
                separator
                link(L10n.t("hud.queue.steer.cancel.keep"), color: DS.Colors.textTertiary) {
                    isConfirmingCancel = false
                }
                separator
                link(L10n.t("hud.queue.steer.cancel"), color: DS.Colors.destructiveText) { cancel() }
            } else {
                // Screen context cannot be put back into the composer, so a
                // screen-attached steer can only be cancelled, not edited.
                if (item.attachedImagesCount ?? 0) == 0 {
                    link(L10n.t("hud.queue.steer.edit.short"), color: DS.Colors.textTertiary, help: "hud.queue.steer.edit") {
                        edit()
                    }
                    separator
                }
                link(L10n.t("hud.queue.steer.cancel"), color: DS.Colors.textTertiary) {
                    isConfirmingCancel = true
                }
            }
        }
    }

    private var separator: some View {
        Text("·")
            .foregroundColor(DS.Colors.textTertiary)
            .accessibilityHidden(true)
    }

    private func link(_ title: String, color: Color, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundColor(color)
            .hoverAffordance(brightness: 0.18)
            .disabled(isWorking)
            .help(help.map { L10n.t($0) } ?? title)
    }

    /// Removes the steer first and only then moves its text into the composer,
    /// so a steer the Pickle already took is never duplicated as a draft.
    private func edit() {
        guard let itemID = item.id, !isWorking else { return }
        let text = item.userFacingText
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
                try? await Task.sleep(for: Self.errorDisplayDuration)
                errorText = nil
            }
        }
    }

    private static let errorDisplayDuration: Duration = .seconds(4)
}

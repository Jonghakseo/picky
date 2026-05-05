//
//  PickyConversationHeaderView.swift
//  Picky
//
//  Header for the conversation-style side-agent card.
//

import SwiftUI

struct PickyConversationHeaderView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard
    private var isVoiceFollowUpTarget: Bool {
        if let activeVoiceFollowUpSessionID = viewModel.activeVoiceFollowUpSessionID {
            return activeVoiceFollowUpSessionID == session.id
        }
        return viewModel.hoveredVoiceFollowUpSessionID == session.id
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            leadingTitle
            trailingActions
        }
        .frame(width: PickyHUDDockLayout.detailContentWidth, alignment: .trailing)
        .frame(minHeight: 24, alignment: .trailing)
    }

    private var leadingTitle: some View {
        HStack(alignment: .center, spacing: 9) {
            piBadge
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.trailing, trailingActionsReservedWidth)
        .frame(width: PickyHUDDockLayout.detailContentWidth, alignment: .leading)
    }

    private var trailingActions: some View {
        HStack(alignment: .center, spacing: 9) {
            statusPill
            notifyOnCompletionButton
            if isVoiceFollowUpTarget {
                voiceTargetBadge
            }
            conversationMenuButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var trailingActionsReservedWidth: CGFloat {
        isVoiceFollowUpTarget ? 166 : 140
    }

    private var voiceTargetBadge: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(DS.Colors.accentText)
            .frame(width: 18, height: 18)
            .background(Circle().fill(DS.Colors.accentSubtle.opacity(0.95)))
            .help("Voice steering target")
    }

    private var notifyOnCompletionButton: some View {
        Button {
            let enabled = !(session.notifyMainOnCompletion == true)
            Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
        } label: {
            Image(systemName: notifyOnCompletionIconName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(notifyOnCompletionColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(notifyOnCompletionBackgroundColor))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(notifyOnCompletionHelpText)
        .accessibilityLabel("Notify on completion")
        .accessibilityValue(session.notifyMainOnCompletion == true ? "On" : "Off")
    }

    var notifyOnCompletionIconName: String {
        session.notifyMainOnCompletion == true ? "bell.fill" : "bell.slash"
    }

    var notifyOnCompletionHelpText: String {
        session.notifyMainOnCompletion == true ? "Notify main agent on completion" : "Do not notify main agent on completion"
    }

    private var notifyOnCompletionColor: Color {
        session.notifyMainOnCompletion == true ? DS.Colors.accentText : DS.Colors.textTertiary
    }

    private var notifyOnCompletionBackgroundColor: Color {
        session.notifyMainOnCompletion == true ? DS.Colors.accentSubtle.opacity(0.34) : DS.Colors.surface2.opacity(0.65)
    }

    private var conversationMenuButton: some View {
        Menu {
            PickyConversationMenu(session: session, viewModel: viewModel)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Conversation menu")
    }

    private var piBadge: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(statusColor.opacity(session.status == .running ? 0.22 : 0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(statusColor.opacity(0.38), lineWidth: 0.8)
            )
            .frame(width: 22, height: 22)
            .overlay(
                Text("π")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(statusColor)
            )
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor.opacity(0.11)))
            .overlay(Capsule().stroke(statusColor.opacity(0.22), lineWidth: 0.6))
    }


    private var statusText: String {
        switch session.status {
        case .running: return "Working"
        case .completed: return "Done"
        case .waiting_for_input: return "Waiting"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .cancelled: return "Cancelled"
        case .queued: return "Queued"
        }
    }

    var statusColorName: String {
        switch session.status {
        case .running:
            return "blue"
        case .completed:
            return "green"
        case .waiting_for_input:
            return "amber"
        case .failed:
            return "red"
        case .blocked:
            return "warning"
        case .queued, .cancelled:
            return "tertiary"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .completed:
            return DS.Colors.success
        case .waiting_for_input:
            return DS.Colors.warning
        case .failed:
            return DS.Colors.destructiveText
        case .blocked:
            return DS.Colors.warningText
        case .queued, .cancelled:
            return DS.Colors.textTertiary
        }
    }
}

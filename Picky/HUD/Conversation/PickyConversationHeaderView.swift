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
    @State private var pulse = false

    private var isVoiceFollowUpTarget: Bool {
        if let activeVoiceFollowUpSessionID = viewModel.activeVoiceFollowUpSessionID {
            return activeVoiceFollowUpSessionID == session.id
        }
        return viewModel.hoveredVoiceFollowUpSessionID == session.id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            piBadge
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            statusPill
            if isVoiceFollowUpTarget {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(DS.Colors.accentSubtle.opacity(0.95)))
                    .help("Voice steering target")
            }
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
        .onAppear { pulse = true }
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
        HStack(spacing: 5) {
            if isPulsingStatus {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 1.0 : 0.35)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            }
            Text(statusText)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(statusColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(statusColor.opacity(0.11)))
        .overlay(Capsule().stroke(statusColor.opacity(0.22), lineWidth: 0.6))
    }

    private var isPulsingStatus: Bool {
        switch session.status {
        case .running, .queued, .waiting_for_input:
            return true
        case .blocked, .completed, .failed, .cancelled:
            return false
        }
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

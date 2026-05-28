//
//  PickyFullscreenSidebarView.swift
//  Picky
//
//  Left Pickle browser for the fullscreen workspace. Selection is local to the
//  fullscreen state store and intentionally does not mutate HUD selection.
//

import SwiftUI

struct PickyFullscreenSidebarView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let recentPickleCwds: [String]
    let isCreatingPickle: Bool
    let onCreatePickleInRecentFolder: (String) -> Void
    let onChoosePickleFolder: () -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    @Binding var selectedSessionID: String?
    @State private var isRecentPickleFolderPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sessions) { session in
                            Button {
                                selectedSessionID = session.id
                            } label: {
                                PickyFullscreenSidebarRow(
                                    session: session,
                                    isSelected: selectedSessionID == session.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(session.title)
                            .accessibilityValue(session.accessibilitySummary)
                            .accessibilityHint(selectedSessionID == session.id ? "Selected Pickle" : "Select Pickle")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)

            Button {
                isRecentPickleFolderPickerPresented = true
            } label: {
                Label(isCreatingPickle ? "Starting Pickle…" : "New Pickle", systemImage: "plus")
                    .pickyFont(size: 13, weight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isCreatingPickle)
            .recentPickleFolderPicker(
                isPresented: $isRecentPickleFolderPickerPresented,
                arrowEdge: .leading,
                recentPickleCwds: recentPickleCwds,
                onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
                onChooseFolder: onChoosePickleFolder,
                onRemoveRecentPickleFolder: onRemoveRecentPickleFolder
            )
            .help("Start a Pickle from a recent folder or choose a working folder.")
            .accessibilityLabel("New Pickle")
            .accessibilityHint("Choose a recent working folder or browse for a new one")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(minWidth: 236, idealWidth: 276, maxWidth: 296, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pickles sidebar")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pickles")
                .pickyFont(size: 16, weight: .semibold)
            Text("\(sessions.count) active sessions")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "tray")
                .pickyFont(size: 18, weight: .medium)
                .foregroundStyle(.secondary)
            Text("No active Pickles")
                .pickyFont(size: 13, weight: .semibold)
            Text("Start a new Pickle from this workspace to begin.")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No active Pickles")
        .accessibilityHint("Start a new Pickle from this workspace to begin")
    }
}

private struct PickyFullscreenSidebarRow: View {
    let session: PickySessionListViewModel.SessionCard
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                statusDot
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .pickyFont(size: 13.5, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let cwd = session.compactCwdDescription {
                        Text(cwd)
                            .pickyFont(size: 11.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text(session.status.fullscreenDisplayText)
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundStyle(session.status.fullscreenForegroundStyle)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text("Updated \(session.elapsedSinceUpdate()) ago")
                    .pickyFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(session.status.fullscreenStatusColor)
            .frame(width: 8, height: 8)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.58))
    }
}

private extension PickySessionListViewModel.SessionCard {
    var accessibilitySummary: String {
        var parts = [status.fullscreenDisplayText]
        if let cwd = compactCwdDescription {
            parts.append(cwd)
        }
        parts.append("Updated \(elapsedSinceUpdate()) ago")
        return parts.joined(separator: ", ")
    }
}

private extension PickySessionStatus {
    var fullscreenDisplayText: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting_for_input: "Waiting for input"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var fullscreenStatusColor: Color {
        switch self {
        case .running: .blue
        case .queued: .orange
        case .waiting_for_input: .purple
        case .blocked, .failed: .red
        case .completed: .green
        case .cancelled: .gray
        }
    }

    var fullscreenForegroundStyle: Color {
        switch self {
        case .blocked, .failed: .red
        case .completed: .green
        case .running: .blue
        case .queued: .orange
        case .waiting_for_input: .purple
        case .cancelled: .secondary
        }
    }
}

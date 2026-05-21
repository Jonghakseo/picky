//
//  PickyHUDArchivedSessionsListView.swift
//  Picky
//
//  Popover content that lists archived Pickles and lets the user restore them
//  back into the dock. Reaches the same code path as the in-toast Undo and the
//  realtime `picky_unarchive_pickle` tool: `PickySessionListViewModel.unarchive`.
//

import SwiftUI

struct PickyHUDArchivedSessionsListView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var onClose: () -> Void = {}

    private static let contentWidth: CGFloat = 320
    private static let listMaxHeight: CGFloat = 320

    private var archivedSessions: [PickySessionListViewModel.SessionCard] {
        viewModel.archivedSessions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().opacity(0.5)
            if archivedSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(archivedSessions) { session in
                            row(for: session)
                            if session.id != archivedSessions.last?.id {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
                .frame(maxHeight: Self.listMaxHeight)
            }
        }
        .padding(12)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("hud.archivedList.title")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if !archivedSessions.isEmpty {
                Text("\(archivedSessions.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 4)
        }
    }

    private var emptyState: some View {
        Text("hud.archivedList.empty")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func row(for session: PickySessionListViewModel.SessionCard) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let cwd = session.compactCwdDescription {
                    Text(cwd)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.unarchive(sessionID: session.id)
                if viewModel.archivedSessions.isEmpty {
                    onClose()
                }
            } label: {
                Text("hud.archivedList.restore")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore Pickle")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

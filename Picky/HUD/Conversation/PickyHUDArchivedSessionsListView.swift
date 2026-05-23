//
//  PickyHUDArchivedSessionsListView.swift
//  Picky
//
//  List of archived Pickles shown inside Settings → Pickle. Reaches the same
//  code path as the in-toast Undo and the realtime `picky_unarchive_pickle`
//  tool (`PickySessionListViewModel.unarchive`) for restore, and the new
//  `deleteArchivedSession` for permanent purge.
//

import SwiftUI

struct PickyHUDArchivedSessionsListView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    /// When `false`, the list's own "Archived sessions" header (title + count
    /// + delete-all) is suppressed so a parent disclosure row can own the
    /// labelling. Defaults to `true` to preserve the HUD-side rendering that
    /// has no outer chrome.
    var showsHeader: Bool = true

    private static let listMaxHeight: CGFloat = 280

    @State private var pendingDeleteSessionID: String?
    @State private var pendingDeleteResetTask: Task<Void, Never>?
    @State private var isDeleteAllConfirmationPresented = false

    /// Time window the two-step delete confirmation stays armed. After this we
    /// snap the row back to the neutral "Delete" label so a stale red state
    /// can't be triggered hours later.
    private static let pendingDeleteWindow: Duration = .seconds(4)

    private var archivedSessions: [PickySessionListViewModel.SessionCard] {
        viewModel.archivedSessions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                header
                Divider().opacity(0.5)
            }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        // SwiftUI .alert renders as a native NSAlert-backed modal on macOS,
        // which is what we want here — "Delete all" is a destructive,
        // unrecoverable action and the per-row 4-second arm/confirm pattern
        // is too easy to misfire when many rows could disappear in one shot.
        .alert(
            Text(deleteAllConfirmationTitle),
            isPresented: $isDeleteAllConfirmationPresented
        ) {
            Button("hud.archivedList.confirmDeleteAllCancel", role: .cancel) {}
            Button("hud.archivedList.confirmDeleteAllConfirm", role: .destructive) {
                resetPendingDelete()
                viewModel.deleteAllArchivedSessions()
            }
        } message: {
            Text("hud.archivedList.confirmDeleteAllMessage")
        }
        .onChange(of: archivedSessions.map(\.id)) { _, ids in
            // If the row currently waiting on confirmation disappears (restored,
            // deleted from another surface, etc.) drop the pending state so a
            // future row at the same index doesn't appear pre-armed.
            if let pending = pendingDeleteSessionID, !ids.contains(pending) {
                pendingDeleteSessionID = nil
                pendingDeleteResetTask?.cancel()
                pendingDeleteResetTask = nil
            }
        }
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
            if !archivedSessions.isEmpty {
                deleteAllButton
            }
        }
    }

    private var deleteAllButton: some View {
        Button {
            resetPendingDelete()
            isDeleteAllConfirmationPresented = true
        } label: {
            Text("hud.archivedList.deleteAll")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.destructiveText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DS.Colors.destructiveText.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete all archived Pickles")
    }

    /// Localized alert title pre-formatted with the current archived count so
    /// the SwiftUI alert can be rendered with a plain `Text` (`.alert` does
    /// not interpolate LocalizedStringKey arguments on macOS the way Text
    /// initializers do).
    private var deleteAllConfirmationTitle: String {
        let format = L10n.t("hud.archivedList.confirmDeleteAllTitle")
        return String.localizedStringWithFormat(format, archivedSessions.count)
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
        HStack(alignment: .center, spacing: 6) {
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

            restoreButton(for: session)
            deleteButton(for: session)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Tapping anywhere outside the delete button on a row cancels the
        // pending confirmation for any *other* row. The delete button itself
        // owns its own arm/confirm transitions.
        .onTapGesture { resetPendingDelete(except: session.id) }
    }

    private func restoreButton(for session: PickySessionListViewModel.SessionCard) -> some View {
        Button {
            resetPendingDelete()
            viewModel.unarchive(sessionID: session.id)
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

    @ViewBuilder
    private func deleteButton(for session: PickySessionListViewModel.SessionCard) -> some View {
        let isArmed = pendingDeleteSessionID == session.id
        Button {
            if isArmed {
                pendingDeleteSessionID = nil
                pendingDeleteResetTask?.cancel()
                pendingDeleteResetTask = nil
                viewModel.deleteArchivedSession(sessionID: session.id)
            } else {
                armPendingDelete(for: session.id)
            }
        } label: {
            Text(isArmed ? "hud.archivedList.confirmDelete" : "hud.archivedList.delete")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isArmed ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isArmed ? DS.Colors.destructiveText.opacity(0.12) : DS.Colors.surface2.opacity(0.6))
                )
                .animation(.easeOut(duration: 0.12), value: isArmed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isArmed ? "Confirm delete Pickle" : "Delete Pickle")
    }

    private func armPendingDelete(for sessionID: String) {
        pendingDeleteSessionID = sessionID
        pendingDeleteResetTask?.cancel()
        pendingDeleteResetTask = Task { @MainActor in
            try? await Task.sleep(for: Self.pendingDeleteWindow)
            guard !Task.isCancelled, pendingDeleteSessionID == sessionID else { return }
            pendingDeleteSessionID = nil
            pendingDeleteResetTask = nil
        }
    }

    private func resetPendingDelete(except keep: String? = nil) {
        guard let pending = pendingDeleteSessionID, pending != keep else { return }
        pendingDeleteSessionID = nil
        pendingDeleteResetTask?.cancel()
        pendingDeleteResetTask = nil
    }
}

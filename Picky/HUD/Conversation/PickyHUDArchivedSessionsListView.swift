//
//  PickyHUDArchivedSessionsListView.swift
//  Picky
//
//  List of archived Pickles shown inside Settings → Pickle. Membership is
//  registry-owned; each row observes only its own stable session store.
//

import Foundation
import SwiftUI

struct PickyHUDArchivedSessionsListView: View {
    let archiveMembership: any PickySessionArchiveMembership
    let commands: any PickySessionArchiveCommands
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

    private var archivedSessionIDs: [String] {
        archiveMembership.archivedSessionIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                header
                Divider().opacity(0.5)
            }
            if archivedSessionIDs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(archivedSessionIDs, id: \.self) { sessionID in
                            if let store = archiveMembership.existingSessionStore(sessionID: sessionID) {
                                row(for: store)
                            }
                            if sessionID != archivedSessionIDs.last {
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
                commands.deleteAllArchivedSessions()
            }
        } message: {
            Text("hud.archivedList.confirmDeleteAllMessage")
        }
        .onChange(of: archivedSessionIDs) { _, ids in
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
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.textPrimary)
            if !archivedSessionIDs.isEmpty {
                Text("\(archivedSessionIDs.count)")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 4)
            if !archivedSessionIDs.isEmpty {
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
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.destructiveText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
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
        return String.localizedStringWithFormat(format, archivedSessionIDs.count)
    }

    private var emptyState: some View {
        Text("hud.archivedList.empty")
            .pickyFont(size: 11)
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func row(for store: PickySessionStore) -> some View {
        PickyHUDArchivedSessionRow(
            store: store,
            isDeleteArmed: pendingDeleteSessionID == store.sessionID,
            onRestore: {
                resetPendingDelete()
                commands.unarchive(sessionID: store.sessionID)
            },
            onDelete: {
                if pendingDeleteSessionID == store.sessionID {
                    pendingDeleteSessionID = nil
                    pendingDeleteResetTask?.cancel()
                    pendingDeleteResetTask = nil
                    commands.deleteArchivedSession(sessionID: store.sessionID)
                } else {
                    armPendingDelete(for: store.sessionID)
                }
            },
            onRowTap: { resetPendingDelete(except: store.sessionID) }
        )
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

/// A row observes exactly one archived session's metadata; sibling and active
/// session mutations cannot invalidate it.
private struct PickyHUDArchivedSessionRow: View {
    let store: PickySessionStore
    let isDeleteArmed: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onRowTap: () -> Void

    var body: some View {
        if case .loaded(let metadata) = store.metaStore.metadataState {
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.title)
                        .pickyFont(size: 12, weight: .medium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let cwd = compactCwdDescription(metadata.cwd) {
                        Text(cwd)
                            .pickyFont(size: 10)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onRestore) {
                    Text("hud.archivedList.restore")
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restore Pickle")

                Button(action: onDelete) {
                    Text(isDeleteArmed ? "hud.archivedList.confirmDelete" : "hud.archivedList.delete")
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(isDeleteArmed ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(isDeleteArmed ? DS.Colors.destructiveText.opacity(0.12) : DS.Colors.surface2.opacity(0.6))
                        )
                        .animation(.easeOut(duration: 0.12), value: isDeleteArmed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDeleteArmed ? "Confirm delete Pickle" : "Delete Pickle")
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onRowTap)
        }
    }

    private func compactCwdDescription(_ cwd: String?) -> String? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardized = NSString(string: trimmed).standardizingPath
        if standardized == home { return "~" }
        if standardized.hasPrefix(home + "/") { return "~" + String(standardized.dropFirst(home.count)) }
        return trimmed
    }
}

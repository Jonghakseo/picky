//
//  PickyFullscreenWorkspaceView.swift
//  Picky
//
//  Fullscreen workspace shell: sidebar, focused conversation, composer, and
//  read-only work info panel.
//

import AppKit
import SwiftUI

struct PickyFullscreenWorkspaceView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    @ObservedObject var stateStore: PickyFullscreenStateStore
    @State private var isCreatingPickle = false
    @State private var pendingCreatedPickleSessionID: String?

    private var selectedSession: PickySessionListViewModel.SessionCard? {
        guard let selectedSessionID = stateStore.selectedSessionID else { return nil }
        return viewModel.sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        HStack(spacing: 0) {
            PickyFullscreenSidebarView(
                sessions: viewModel.sessions,
                recentPickleCwds: visibleRecentPickleCwds,
                isCreatingPickle: isCreatingPickle,
                onCreatePickleInRecentFolder: startEmptyPickle,
                onChoosePickleFolder: chooseFolderForEmptyPickle,
                onRemoveRecentPickleFolder: viewModel.removeRecentPickleFolder,
                selectedSessionID: $stateStore.selectedSessionID
            )

            Divider()

            PickyFullscreenConversationPaneView(
                session: selectedSession,
                viewModel: viewModel
            )

            Divider()

            PickyFullscreenWorkInfoPanelView(
                session: selectedSession,
                isVisible: $stateStore.isWorkInfoPanelVisible
            )
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reconcileSelectedSession)
        .onChange(of: viewModel.sessions.map(\.id)) { _, _ in reconcileSelectedSession() }
        .onChange(of: viewModel.selectedSessionID) { _, _ in reconcileSelectedSession() }
    }

    private var visibleRecentPickleCwds: [String] {
        PickyRecentPickleFolderPolicy.visibleCwds(viewModel.recentPickleCwds, exists: Self.isExistingDirectory)
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func chooseFolderForEmptyPickle() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a working folder"
        panel.prompt = "Start"
        panel.message = "Choose the folder where the new Pickle should run."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            startEmptyPickle(cwd: url.path)
        }
    }

    private func startEmptyPickle(cwd: String) {
        guard !isCreatingPickle else { return }
        isCreatingPickle = true
        Task {
            do {
                let sessionID = try await viewModel.createEmptyPickleSession(cwd: cwd)
                await MainActor.run {
                    pendingCreatedPickleSessionID = sessionID
                    stateStore.selectedSessionID = sessionID
                    isCreatingPickle = false
                }
            } catch {
                // `createEmptyPickleSession` already surfaces the error through the shared
                // view model. Keep the current fullscreen-local selection untouched.
                await MainActor.run {
                    isCreatingPickle = false
                }
            }
        }
    }

    private func reconcileSelectedSession() {
        let candidates = PickyFullscreenSessionSelection.candidates(from: viewModel.sessions)
        if let pendingCreatedPickleSessionID {
            if candidates.contains(where: { $0.id == pendingCreatedPickleSessionID }) {
                self.pendingCreatedPickleSessionID = nil
            } else {
                stateStore.selectedSessionID = pendingCreatedPickleSessionID
                return
            }
        }

        let resolvedID = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: nil,
            storedSelectedSessionID: stateStore.selectedSessionID,
            viewModelSelectedSessionID: viewModel.selectedSessionID,
            candidates: candidates
        )
        if stateStore.selectedSessionID != resolvedID {
            stateStore.selectedSessionID = resolvedID
        }
    }
}

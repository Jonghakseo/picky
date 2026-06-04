//
//  PickyConversationMenu.swift
//  Picky
//
//  Action menu for the conversation-style Pickle card.
//

import SwiftUI

struct PickyConversationMenu: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    var onArchive: (() -> Void)?

    var canOpenPiTerminal: Bool { session.piSessionFilePath != nil }
    var canShowInlinePiTerminal: Bool { session.piSessionFilePath != nil }
    var isShowingInlinePiTerminal: Bool { viewModel.isInlineTerminalMode(sessionID: session.id) }
    var canCopyResumeCommand: Bool { session.piSessionFilePath != nil }
    /// `syncTerminalSession` reads the on-disk Pi JSONL, so we gate the action on the same
    /// condition as the terminal overlay. Useful when the user is iterating the same session in
    /// an external `pi --session` and the HUD card has gone stale (the daemon has no automatic
    /// JSONL watcher).
    var canSyncFromPiSession: Bool { session.piSessionFilePath != nil }
    var canDuplicate: Bool { session.piSessionFilePath != nil }
    var canStop: Bool { !session.status.isTerminal }

    var body: some View {
        Section("QUICK") {
            Button("hud.menu.openTerminal") {
                viewModel.openTerminalOverlay(sessionID: session.id)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!canOpenPiTerminal)

            Button(isShowingInlinePiTerminal ? "hud.menu.showChatUI" : "hud.menu.showTerminalInline") {
                viewModel.toggleInlineTerminalMode(sessionID: session.id)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!canShowInlinePiTerminal)

            Button("hud.menu.copyResume") {
                viewModel.copyTerminalResumeCommand(sessionID: session.id)
            }
            .disabled(!canCopyResumeCommand)

            // Manual escape hatch for when the user has been iterating the session in an
            // external `pi --session` shell. The daemon does not watch JSONL files, so this is
            // the only way (short of opening the in-app terminal overlay) to reconcile the HUD
            // card with the latest on-disk transcript.
            Button("hud.menu.syncFromPi") {
                viewModel.syncTerminalSessionOnce(sessionID: session.id)
            }
            .disabled(!canSyncFromPiSession)
        }

        Section("SETTINGS") {
            Toggle("Notify on completion", isOn: notifyMainOnCompletionBinding)
        }

        Section("SESSION") {
            Button("hud.menu.duplicate") {
                Task { try? await viewModel.duplicate(sessionID: session.id) }
            }
            .disabled(!canDuplicate)

            Button("hud.menu.stopSession") {
                Task { try? await viewModel.abortRestoringQueuedInputs(sessionID: session.id) }
            }
            .disabled(!canStop)

            Button("hud.menu.archive") {
                if let onArchive {
                    onArchive()
                } else {
                    viewModel.archive(sessionID: session.id)
                }
            }
        }
    }

    private var notifyMainOnCompletionBinding: Binding<Bool> {
        Binding(
            get: { session.notifyMainOnCompletion == true },
            set: { enabled in
                Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
            }
        )
    }
}

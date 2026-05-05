//
//  PickyConversationMenu.swift
//  Picky
//
//  Action menu for the conversation-style side-agent card.
//

import SwiftUI

struct PickyConversationMenu: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel

    var canOpenPiTerminal: Bool { session.piSessionFilePath != nil }
    var canOpenReport: Bool { session.reportArtifact != nil || session.finalReport != nil }
    var canCopyResumeCommand: Bool { session.piSessionFilePath != nil }
    var canStop: Bool { !session.status.isTerminal }

    var body: some View {
        Section("QUICK") {
            Button("Open Pi terminal") {
                viewModel.openTerminalOverlay(sessionID: session.id)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!canOpenPiTerminal)

            Button("Open report") {
                Task { try? await viewModel.openReport(sessionID: session.id) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!canOpenReport)

            Button("Copy resume command") {
                viewModel.copyTerminalResumeCommand(sessionID: session.id)
            }
            .disabled(!canCopyResumeCommand)
        }

        Section("SETTINGS") {
            Toggle("Notify on completion", isOn: notifyMainOnCompletionBinding)
        }

        Section("SESSION") {
            Button("Stop session") {
                Task { try? await viewModel.abort(sessionID: session.id) }
            }
            .disabled(!canStop)

            Button("Archive") {
                viewModel.archive(sessionID: session.id)
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

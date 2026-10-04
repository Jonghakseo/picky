//
//  PickyConversationMenu.swift
//  Picky
//
//  Action menu for the conversation-style Pickle card.
//

import SwiftUI

struct PickyConversationMenu: View {
    let session: PickyConversationHeaderProjection
    let viewModel: any PickySessionCommands
    var onArchive: (() -> Void)?
    var onRewind: (() -> Void)?
    /// Lets the host ask what to stop when background tasks run. Without it the menu stops everything.
    var onStop: (() -> Void)?

    var canCopyResumeCommand: Bool { session.piSessionFilePath != nil }
    /// `syncTerminalSession` reads the on-disk Pi JSONL, so the action needs a session file.
    /// Useful when the user is iterating the same session in an external `pi --session` and
    /// the HUD card has gone stale (the daemon has no automatic JSONL watcher).
    var canSyncFromPiSession: Bool { session.piSessionFilePath != nil }
    var canDuplicate: Bool { session.piSessionFilePath != nil }
    // Requires a Pi session file AND a wired sheet host. Hosts that do not present the
    // rewind picker pass no `onRewind`; without that check the item would render enabled
    // there and tap to a silent no-op.
    var canRewind: Bool { session.piSessionFilePath != nil && onRewind != nil }
    var canStop: Bool { !session.status.isTerminal }
    var canCompact: Bool { session.canRequestDockCompaction }

    var body: some View {
        Section("hud.menu.section.quick") {
            Button("hud.menu.copyResume") {
                viewModel.copyTerminalResumeCommand(sessionID: session.id)
            }
            .disabled(!canCopyResumeCommand)

            // Manual escape hatch for when the user has been iterating the session in an
            // external `pi --session` shell. The daemon does not watch JSONL files, so this is
            // the only way to reconcile the HUD card with the latest on-disk transcript.
            Button("hud.menu.syncFromPi") {
                viewModel.syncTerminalSessionOnce(sessionID: session.id)
            }
            .disabled(!canSyncFromPiSession)
        }

        Section("hud.menu.section.settings") {
            Toggle("hud.menu.notifyMainOnCompletion", isOn: notifyMainOnCompletionBinding)
            Toggle("hud.menu.notifyMacOSOnCompletion", isOn: notifyMacOSOnCompletionBinding)
        }

        Section("hud.menu.section.session") {
            Button("hud.menu.duplicate") {
                Task { try? await viewModel.duplicate(sessionID: session.id) }
            }
            .disabled(!canDuplicate)

            Button("hud.menu.rewind") {
                onRewind?()
            }
            .disabled(!canRewind)

            Button("hud.menu.compact") {
                Task { await viewModel.requestCompaction(sessionID: session.id) }
            }
            .disabled(!canCompact)

            Button("hud.menu.stopSession") {
                if let onStop {
                    onStop()
                } else {
                    Task { try? await viewModel.abortRestoringQueuedInputs(sessionID: session.id, scope: .all) }
                }
            }
            .disabled(!canStop)
            .help(L10n.t("hud.menu.stopSession.help"))

            Button("hud.menu.archive") {
                if let onArchive {
                    onArchive()
                } else {
                    viewModel.archive(sessionID: session.id)
                }
            }
        }
    }

    init(
        session: PickyConversationHeaderProjection,
        viewModel: any PickySessionCommands,
        onArchive: (() -> Void)? = nil,
        onRewind: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        self.session = session
        self.viewModel = viewModel
        self.onArchive = onArchive
        self.onRewind = onRewind
        self.onStop = onStop
    }

    /// Compatibility entry point for callers that still carry the legacy card
    /// projection.
    init(
        session: PickyConversationSessionCard,
        viewModel: any PickySessionCommands,
        onArchive: (() -> Void)? = nil,
        onRewind: (() -> Void)? = nil
    ) {
        self.init(
            session: PickyConversationHeaderProjection(card: session),
            viewModel: viewModel,
            onArchive: onArchive,
            onRewind: onRewind
        )
    }

    private var notifyMainOnCompletionBinding: Binding<Bool> {
        Binding(
            get: { session.notifyMainOnCompletion == true },
            set: { enabled in
                Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
            }
        )
    }

    private var notifyMacOSOnCompletionBinding: Binding<Bool> {
        Binding(
            get: { session.notifyMacOSOnCompletion == true },
            set: { enabled in
                Task { try? await viewModel.setNotifyMacOSOnCompletion(sessionID: session.id, enabled: enabled) }
            }
        )
    }
}

//
//  PickySessionViewModel+Rewind.swift
//  Picky
//
//  Message-rewind (pi /tree) entry points, split out of PickySessionViewModel.swift.
//

import Foundation

extension PickySessionListViewModel {
    func slashCommandsIncludingRewindTreeCommand(_ commands: [PickySlashCommand], sessionID: String) -> [PickySlashCommand] {
        guard sessions.contains(where: { $0.id == sessionID && $0.piSessionFilePath != nil }) else { return commands }
        guard !commands.contains(where: { $0.name == "tree" }) else { return commands }
        return [PickySlashCommand(name: "tree", description: "Rewind to an earlier message", source: .builtin)] + commands
    }

    func loadRewindTargets(sessionID: String) async throws -> [PickyRewindTarget] {
        pickySessionLog("rewind targets requested session=\(sessionID)")
        do {
            let targets = try await client.listRewindTargets(sessionId: sessionID)
            lastError = nil
            return targets
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func rewind(sessionID: String, toEntry entryId: String) async {
        pickySessionLog("rewind session=\(sessionID) entry=\(entryId)")
        do {
            try await client.rewindSession(sessionId: sessionID, entryId: entryId)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applySessionRewound(sessionID sessionId: String, editorText: String?) {
        PickyPerf.event("vm_event_session_rewound")
        pickySessionLog("session rewound session=\(sessionId) editorTextChars=\(editorText?.count ?? 0)")
        guard let editorText else { return }
        replaceComposerDraftText(editorText, sessionID: sessionId)
    }
}

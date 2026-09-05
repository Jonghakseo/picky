//
//  PickySessionViewModel+HUDCommands.swift
//  Picky
//

import Foundation

extension PickySessionListViewModel: PickyGitChipActionViewModelDispatch, PickySessionCommands, PickyHUDSessionLifecycle {
    func unreadFocusShortcutTargetSessionID() -> String? {
        PickyUnreadFocusTargetPolicy.targetSessionID(
            layout: dockLayout,
            activeSessionIDs: Array(sessions.reversed().map(\.id)),
            unreadSessionIDs: unreadSessionIDs,
            lastActualConversationCardOpenedID: lastActualConversationCardOpenedID
        )
    }

    func sessionCard(sessionID: String) -> PickyConversationSessionCard? {
        activeSessionCard(sessionID: sessionID)
    }

    func setNotifyMainOnCompletion(sessionID: String, enabled: Bool) async throws {
        pickySessionLog("set notify main on completion session=\(sessionID) enabled=\(enabled)")
        try await client.send(PickyCommandEnvelope(type: .setNotifyMainOnCompletion, sessionId: sessionID, enabled: enabled))
        updateCompletionNotificationProjection(sessionID: sessionID, notifyMain: enabled)
    }

    func setNotifyMacOSOnCompletion(sessionID: String, enabled: Bool) async throws {
        pickySessionLog("set notify macOS on completion session=\(sessionID) enabled=\(enabled)")
        try await client.send(PickyCommandEnvelope(type: .setNotifyMacOSOnCompletion, sessionId: sessionID, enabled: enabled))
        updateCompletionNotificationProjection(sessionID: sessionID, notifyMacOS: enabled)
    }

    func shellTerminalSession(sessionID: String) -> PickyShellTerminalSession {
        guard let session = card(sessionID: sessionID) else {
            preconditionFailure("Extended terminal requires an active session")
        }
        return shellTerminalSession(for: session)
    }

    /// CLI bridge summaries remain a registry read model, avoiding a second
    /// v2 transaction reducer in `PickyAgentClientRouter`.
    func pickleSessionSummariesForCLI() -> [PickyAgentSession] {
        guard let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage else {
            return []
        }
        return storage.sessionSummariesForCLI()
    }

    /// Stable registry identity for scoped HUD subtrees. Consumers observe this
    /// store's child sections instead of the façade's global card arrays.
    func sessionStore(sessionID: String) -> PickySessionStore? {
        (sessionProjectionStorage as? PickyRegistrySessionProjectionStorage)?
            .registry.existingSessionStore(sessionID: sessionID)
    }

    /// Registry-owned archive membership for settings/onboarding consumers.
    /// Production always uses the registry backend, so these UI surfaces never
    /// fall back to a parallel array-backed projection.
    var sessionRegistry: PickySessionRegistry {
        guard let registry = (sessionProjectionStorage as? PickyRegistrySessionProjectionStorage)?.registry else {
            preconditionFailure("Archive membership requires registry projection storage")
        }
        return registry
    }
}

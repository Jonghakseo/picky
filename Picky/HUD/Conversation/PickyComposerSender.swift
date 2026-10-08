import Foundation

/// Sends composer messages and waits for picky-agentd's verdict. A rejection used to
/// reach only `lastError`, which no HUD view renders, so a refused message vanished.
@MainActor
struct PickyComposerSender {
    /// Long enough for the daemon to admit input after re-attaching a runtime. A steered
    /// slash command acknowledges only after it finishes, so silence past this window
    /// counts as accepted rather than as a failure.
    static let rejectionWindow: TimeInterval = 30

    let client: any PickyAgentClient
    let onAccepted: (_ sessionID: String, _ text: String) -> Void

    /// Throws `PickyCommandRejection` when the daemon refused the message.
    func send(kind: PickyConversationComposerSubmitKind, text: String, sessionID: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let type: PickyCommandType = kind == .steer ? .steer : .followUp
        pickySessionLog("composer \(type.rawValue) session=\(sessionID) textChars=\(trimmed.count)")
        if let rejection = try await client.sendAwaitingError(
            PickyCommandEnvelope(type: type, sessionId: sessionID, text: trimmed),
            timeout: Self.rejectionWindow,
            requireAcknowledgement: false
        ) {
            throw PickyCommandRejection(event: rejection)
        }
        onAccepted(sessionID, trimmed)
    }
}

/// What the composer says when a message did not go out.
enum PickyComposerSendFailurePolicy {
    static func message(for error: Error) -> String {
        guard let rejection = error as? PickyCommandRejection else {
            return L10n.t("hud.composer.sendError.generic", error.localizedDescription)
        }
        switch rejection.event.code {
        case "runtimeRestarting": return L10n.t("hud.composer.sendError.restarting")
        case "runtimeUnavailable": return L10n.t("hud.composer.sendError.unavailable")
        default: return L10n.t("hud.composer.sendError.generic", rejection.event.message)
        }
    }
}

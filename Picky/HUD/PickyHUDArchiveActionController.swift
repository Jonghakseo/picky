import Combine
import Foundation

/// One per HUD root. Owns choice/pending/error presentation; W5 still owns
/// the acknowledged archive operation and its captured owner revision.
@MainActor
final class PickyHUDArchiveActionController: ObservableObject {
    @Published var choiceSessionID: String?
    @Published var error: String?
    @Published var errorTitleKey = "hud.asyncTasks.archiveError.title"
    private var pendingSessionIDs = Set<String>()

    func request(sessionID: String, commands: any PickySessionCommands,
                 onConfirmed: @escaping @MainActor (String) -> Void) {
        guard pendingSessionIDs.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { pendingSessionIDs.remove(sessionID) }
            do {
                try await commands.archiveSessionConfirmed(sessionID: sessionID, mode: nil)
                onConfirmed(sessionID)
            } catch PickyAsyncControlError.archiveChoiceRequired {
                choiceSessionID = sessionID
            } catch {
                presentArchiveError(error)
            }
        }
    }

    func choose(_ mode: PickyAsyncTaskCommand.ArchiveMode, commands: any PickySessionCommands,
                onConfirmed: @escaping @MainActor (String) -> Void) {
        guard let sessionID = choiceSessionID else { return }
        choiceSessionID = nil
        guard pendingSessionIDs.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { pendingSessionIDs.remove(sessionID) }
            do {
                try await commands.archiveSessionConfirmed(sessionID: sessionID, mode: mode)
                onConfirmed(sessionID)
            } catch {
                // A changed owner/revision is an error, never a new implicit approval.
                presentArchiveError(error)
            }
        }
    }

    func presentStopError(_ error: Error) {
        errorTitleKey = "hud.asyncTasks.stopError.title"
        self.error = L10n.t("hud.asyncTasks.stopError", error.localizedDescription)
    }

    private func presentArchiveError(_ error: Error) {
        errorTitleKey = "hud.asyncTasks.archiveError.title"
        self.error = error.localizedDescription
    }
}

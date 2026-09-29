import Combine
import Foundation

/// One per HUD root. Owns choice/pending/error presentation; W5 still owns
/// the acknowledged archive operation and its captured owner revision.
@MainActor
final class PickyHUDArchiveActionController: ObservableObject {
    @Published private(set) var choiceSessionID: String?
    @Published private(set) var error: String?
    @Published private(set) var errorTitleKey = "hud.asyncTasks.archiveError.title"

    private struct Request {
        let sessionID: String
        let commands: any PickySessionCommands
        let onConfirmed: @MainActor (String) -> Void
    }

    private var pendingSessionIDs = Set<String>()
    private var queued: [Request] = []
    private var current: Request?

    func request(sessionID: String, commands: any PickySessionCommands,
                 onConfirmed: @escaping @MainActor (String) -> Void) {
        guard pendingSessionIDs.insert(sessionID).inserted else { return }
        queued.append(Request(sessionID: sessionID, commands: commands, onConfirmed: onConfirmed))
        startNext()
    }

    private func startNext() {
        guard current == nil, error == nil, !queued.isEmpty else { return }
        let request = queued.removeFirst()
        current = request
        Task { @MainActor in
            do {
                try await request.commands.archiveSessionConfirmed(sessionID: request.sessionID, mode: nil)
                request.onConfirmed(request.sessionID)
                finish(request)
            } catch PickyAsyncControlError.archiveChoiceRequired {
                choiceSessionID = request.sessionID
            } catch {
                presentArchiveError(error)
                finish(request)
            }
        }
    }

    func choose(_ mode: PickyAsyncTaskCommand.ArchiveMode) {
        guard let request = current, choiceSessionID == request.sessionID else { return }
        choiceSessionID = nil
        Task { @MainActor in
            do {
                try await request.commands.archiveSessionConfirmed(sessionID: request.sessionID, mode: mode)
                request.onConfirmed(request.sessionID)
            } catch {
                // A changed owner/revision is an error, never a new implicit approval.
                presentArchiveError(error)
            }
            finish(request)
        }
    }

    func cancelChoice() {
        guard let request = current, choiceSessionID == request.sessionID else { return }
        choiceSessionID = nil
        finish(request)
    }

    func dismissError() {
        error = nil
        startNext()
    }

    private func finish(_ request: Request) {
        guard current?.sessionID == request.sessionID else { return }
        pendingSessionIDs.remove(request.sessionID)
        current = nil
        startNext()
    }

    func presentStopError(_ error: Error) {
        errorTitleKey = "hud.asyncTasks.stopError.title"
        self.error = L10n.t("hud.asyncTasks.stopError", error.localizedDescription)
    }

    private func presentArchiveError(_ error: Error) {
        errorTitleKey = "hud.asyncTasks.archiveError.title"
        self.error = (error as? PickyAsyncControlError) == .unsupported
            ? L10n.t("hud.asyncTasks.archiveError.coverage") : error.localizedDescription
    }
}

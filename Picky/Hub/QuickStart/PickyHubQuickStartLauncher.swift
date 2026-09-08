//
//  PickyHubQuickStartLauncher.swift
//  Picky
//
//  Turns a workflow selection into a real Pickle: create an empty Pickle in
//  the chosen folder, wait for the daemon projection to surface it, send the
//  bundled guide as the first instruction, and open the card in the HUD.
//

import Combine
import Foundation

@MainActor
final class PickyHubQuickStartLauncher: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting(workflowID: String)
        case started(workflowID: String, sessionID: String)
        case failed(workflowID: String, message: String)

        var isBusy: Bool {
            if case .starting = self { return true }
            return false
        }
    }

    enum LaunchError: LocalizedError {
        case sessionNotProjected

        var errorDescription: String? {
            switch self {
            case .sessionNotProjected: L10n.t("hub.quickStart.error.notProjected")
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRecord: PickyHubQuickStartRecord?

    private let sessions: PickySessionListViewModel
    private let defaultCwd: () -> String
    private let presentSessionInHUD: (String) -> Void
    private let defaults: UserDefaults
    private let projectionTimeoutNanoseconds: UInt64
    private var launchGeneration: UInt64 = 0
    private var lastAttempt: (workflow: PickyHubQuickStartWorkflow, cwd: String)?
    private var lastAttemptSessionID: String?
    private static let recordKey = "picky.hub.quickStart.lastRecord"

    init(
        sessions: PickySessionListViewModel,
        defaultCwd: @escaping () -> String,
        presentSessionInHUD: @escaping (String) -> Void,
        defaults: UserDefaults = PickyRuntimeEnvironment.userDefaults,
        projectionTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) {
        self.sessions = sessions
        self.defaultCwd = defaultCwd
        self.presentSessionInHUD = presentSessionInHUD
        self.defaults = defaults
        self.projectionTimeoutNanoseconds = projectionTimeoutNanoseconds
        if let data = defaults.data(forKey: Self.recordKey),
           let record = try? JSONDecoder().decode(PickyHubQuickStartRecord.self, from: data) {
            lastRecord = record
        }
    }

    /// The record is only resumable while its Pickle still exists (live or
    /// archived); a deleted Pickle drops the card.
    var resumableRecord: PickyHubQuickStartRecord? {
        guard let record = lastRecord else { return nil }
        let exists = sessions.sessions.contains { $0.id == record.sessionID }
            || sessions.archivedSessions.contains { $0.id == record.sessionID }
        return exists ? record : nil
    }

    /// Creates exactly one session for a new workflow selection. Once the
    /// session ID exists, retries always operate on the durable record instead
    /// of creating another Pickle.
    func start(_ workflow: PickyHubQuickStartWorkflow, cwd: String? = nil) async {
        guard !phase.isBusy else { return }
        let generation = beginLaunch(workflowID: workflow.id)
        let targetCwd = (cwd ?? defaultCwd()).trimmingCharacters(in: .whitespacesAndNewlines)
        lastAttempt = (workflow, targetCwd)
        lastAttemptSessionID = nil
        do {
            try Task.checkCancellation()
            let sessionID = try await sessions.createEmptyPickleSession(cwd: targetCwd)
            guard isCurrent(generation) else { return }
            // Once creation returned an ID, retain it even if this task was
            // cancelled before projection. The user must not lose the only
            // route back to this child session.
            lastAttemptSessionID = sessionID
            let record = PickyHubQuickStartRecord(
                workflowID: workflow.id,
                sessionID: sessionID,
                cwd: targetCwd,
                startedAt: Date(),
                deliveryState: .awaitingProjection
            )
            persist(record)
            await continueLaunch(record, workflow: workflow, generation: generation)
        } catch {
            settleCreationFailure(workflowID: workflow.id, generation: generation, error: error)
        }
    }

    /// Only projection waits are retried without sending twice. After any
    /// attempted delivery, open the retained Pickle for inspection: even a
    /// correlated handler error can follow a partial journal write.
    var retryWillOpenExistingSession: Bool {
        if lastAttempt != nil, lastAttemptSessionID == nil { return false }
        guard let lastRecord else { return false }
        return lastRecord.deliveryState != .awaitingProjection
    }

    func retry() async {
        guard !phase.isBusy else { return }
        if let lastAttempt, lastAttemptSessionID == nil {
            await start(lastAttempt.workflow, cwd: lastAttempt.cwd)
            return
        }
        guard let record = lastRecord,
              let workflow = PickyHubQuickStartWorkflow.workflow(id: record.workflowID) else { return }
        guard record.deliveryState != .accepted else {
            resume()
            return
        }
        guard record.deliveryState == .awaitingProjection else {
            resume()
            return
        }

        let generation = beginLaunch(workflowID: record.workflowID)
        await continueLaunch(record, workflow: workflow, generation: generation)
    }

    func resume() {
        guard let record = resumableRecord else { return }
        if sessions.archivedSessions.contains(where: { $0.id == record.sessionID }) {
            sessions.unarchive(sessionID: record.sessionID)
        }
        openSessionInHUD(sessionID: record.sessionID)
    }

    /// All Hub entry points use the HUD owner, which restores visibility and
    /// presents the card on the same display instead of only changing selection.
    func openSessionInHUD(sessionID: String) {
        presentSessionInHUD(sessionID)
    }

    func acknowledge() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    /// Guide text plus the reply language, so Pi interviews in the language the
    /// user picked for Picky rather than the language of the bundled document.
    @MainActor
    static func firstInstruction(
        for workflow: PickyHubQuickStartWorkflow,
        locale: Locale? = nil
    ) -> String {
        let resolved = locale ?? LocaleManager.shared.effectiveLocale
        let language = resolved.language.languageCode?.identifier == "ko" ? "Korean" : "English"
        return workflow.loadGuide()
            + "\n\nReply language: \(language). Start the interview now with the first question.\n"
    }

    private func beginLaunch(workflowID: String) -> UInt64 {
        launchGeneration &+= 1
        phase = .starting(workflowID: workflowID)
        return launchGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == launchGeneration
    }

    private func continueLaunch(
        _ originalRecord: PickyHubQuickStartRecord,
        workflow: PickyHubQuickStartWorkflow,
        generation: UInt64
    ) async {
        var record = originalRecord
        do {
            try Task.checkCancellation()
            try await waitForProjection(sessionID: record.sessionID)
            guard isCurrent(generation) else { return }
            try Task.checkCancellation()

            // Persist uncertainty before crossing the transport boundary. If
            // the app exits while awaiting ack, reconnect must not resend.
            record.deliveryState = .deliveryUnknown
            persist(record)
            try await sessions.followUp(
                text: Self.firstInstruction(for: workflow),
                sessionID: record.sessionID,
                requireAcknowledgement: true
            )
            guard isCurrent(generation) else { return }
            try Task.checkCancellation()

            record.deliveryState = .accepted
            persist(record)
            openSessionInHUD(sessionID: record.sessionID)
            phase = .started(workflowID: record.workflowID, sessionID: record.sessionID)
        } catch let rejection as PickyCommandRejection {
            guard isCurrent(generation) else { return }
            record.deliveryState = .rejected
            persist(record)
            phase = .failed(workflowID: record.workflowID, message: rejection.localizedDescription)
        } catch {
            settlePendingDelivery(record, generation: generation, error: error)
        }
    }

    private func settleCreationFailure(workflowID: String, generation: UInt64, error: Error) {
        guard generation == launchGeneration else { return }
        if error is CancellationError {
            phase = .idle
            return
        }
        phase = .failed(workflowID: workflowID, message: error.localizedDescription)
    }

    private func settlePendingDelivery(_ originalRecord: PickyHubQuickStartRecord, generation: UInt64, error: Error) {
        guard generation == launchGeneration else { return }
        var record = originalRecord
        if record.deliveryState == .readyToSend {
            // The command might have been accepted after the socket write but
            // before its ack was lost or delayed. Keep the session and never
            // automatically send this instruction again.
            record.deliveryState = .deliveryUnknown
            persist(record)
        }
        // Keep uncertainty visibly distinct from a started workflow. The
        // durable record exposes the retained Pickle for resume/recovery.
        phase = .failed(workflowID: record.workflowID, message: error.localizedDescription)
    }

    private func waitForProjection(sessionID: String) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + projectionTimeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()
            if sessions.sessions.contains(where: { $0.id == sessionID }) { return }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        throw LaunchError.sessionNotProjected
    }

    private func persist(_ record: PickyHubQuickStartRecord) {
        lastRecord = record
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.recordKey)
        }
    }
}

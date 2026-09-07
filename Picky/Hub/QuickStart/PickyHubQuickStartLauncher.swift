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
    private let defaults: UserDefaults
    private let projectionTimeoutNanoseconds: UInt64
    private static let recordKey = "picky.hub.quickStart.lastRecord"

    init(
        sessions: PickySessionListViewModel,
        defaultCwd: @escaping () -> String,
        defaults: UserDefaults = .standard,
        projectionTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) {
        self.sessions = sessions
        self.defaultCwd = defaultCwd
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

    func start(_ workflow: PickyHubQuickStartWorkflow, cwd: String? = nil) async {
        guard !phase.isBusy else { return }
        phase = .starting(workflowID: workflow.id)
        let targetCwd = (cwd ?? defaultCwd()).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let sessionID = try await sessions.createEmptyPickleSession(cwd: targetCwd)
            try await waitForProjection(sessionID: sessionID)
            try await sessions.followUp(text: Self.firstInstruction(for: workflow), sessionID: sessionID)
            sessions.requestOpenSession(sessionID: sessionID, targetDisplayID: nil)
            let record = PickyHubQuickStartRecord(workflowID: workflow.id, sessionID: sessionID, startedAt: Date())
            persist(record)
            phase = .started(workflowID: workflow.id, sessionID: sessionID)
        } catch {
            phase = .failed(workflowID: workflow.id, message: error.localizedDescription)
        }
    }

    func resume() {
        guard let record = resumableRecord else { return }
        if sessions.archivedSessions.contains(where: { $0.id == record.sessionID }) {
            sessions.unarchive(sessionID: record.sessionID)
        }
        sessions.requestOpenSession(sessionID: record.sessionID, targetDisplayID: nil)
    }

    func acknowledge() {
        phase = .idle
    }

    /// Guide text plus the reply language, so Pi interviews in the language the
    /// user picked for Picky rather than the language of the bundled document.
    @MainActor
    static func firstInstruction(for workflow: PickyHubQuickStartWorkflow, locale: Locale? = nil) -> String {
        let resolved = locale ?? LocaleManager.shared.effectiveLocale
        let language = resolved.language.languageCode?.identifier == "ko" ? "Korean" : "English"
        return workflow.loadGuide() + "\n\nReply language: \(language). Start the interview now with the first question.\n"
    }

    private func waitForProjection(sessionID: String) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + projectionTimeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
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

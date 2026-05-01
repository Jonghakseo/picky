//
//  PickySessionViewModel.swift
//  Picky
//
//  Minimal streaming session state for the Phase 3 daemon bridge.
//

import Combine
import Foundation

@MainActor
final class PickySessionListViewModel: ObservableObject {
    struct SessionCard: Equatable, Identifiable {
        let id: String
        var title: String
        var status: PickySessionStatus
        var lastSummary: String
        var logPreview: String
    }

    @Published private(set) var sessions: [SessionCard] = []
    @Published private(set) var lastError: String?

    private let client: any PickyAgentClient
    private var eventTask: Task<Void, Never>?

    init(client: any PickyAgentClient) {
        self.client = client
    }

    func start() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                self.apply(event)
            }
        }
        Task { await client.connect() }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
    }

    func submit(transcript: String, context: PickyContextPacket) async throws {
        _ = try await client.submit(PickyAgentSubmission(transcript: transcript, context: context))
    }

    private func apply(_ event: PickyClientEvent) {
        switch event {
        case .connected:
            lastError = nil
        case .disconnected:
            lastError = "Disconnected from picky-agentd"
        case .recoverableError(let message):
            lastError = message
        case .protocolEvent(let envelope):
            apply(envelope.event)
        }
    }

    private func apply(_ event: PickyEvent) {
        switch event {
        case .sessionSnapshot(let snapshot):
            sessions = snapshot.map(SessionCard.init(session:))
        case .sessionUpdated(let session):
            upsert(SessionCard(session: session))
        case .sessionLogAppended(let sessionId, let line):
            guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
            sessions[index].logPreview = line
        case .toolActivityUpdated(let sessionId, let tool):
            guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
            sessions[index].logPreview = [tool.name, tool.preview].compactMap { $0 }.joined(separator: ": ")
        case .extensionUiRequest(let request):
            guard let index = sessions.firstIndex(where: { $0.id == request.sessionId }) else { return }
            sessions[index].status = .waiting_for_input
            sessions[index].lastSummary = request.prompt ?? request.title ?? "Waiting for input"
        case .error(let error):
            lastError = error.message
        case .hello, .artifactUpdated, .artifactOpened, .unknown:
            break
        }
    }

    private func upsert(_ card: SessionCard) {
        if let index = sessions.firstIndex(where: { $0.id == card.id }) {
            sessions[index] = card
        } else {
            sessions.append(card)
        }
    }
}

private extension PickySessionListViewModel.SessionCard {
    init(session: PickyAgentSession) {
        self.id = session.id
        self.title = session.title
        self.status = session.status
        self.lastSummary = session.lastSummary ?? ""
        self.logPreview = session.logs.last ?? session.tools.last?.preview ?? ""
    }
}

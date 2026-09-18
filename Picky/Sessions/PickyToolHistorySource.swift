import Combine
import Foundation

/// Bridges the authoritative projection to a read-only history window.
/// The window keeps a source snapshot rather than borrowing a mutable session ID alone.
@MainActor
final class PickyToolHistorySource {
    private let sessionID: String
    private let storage: any PickySessionProjectionStorage
    private let client: any PickyAgentClient

    init(sessionID: String, storage: any PickySessionProjectionStorage, client: any PickyAgentClient) {
        self.sessionID = sessionID
        self.storage = storage
        self.client = client
    }

    var snapshot: PickyToolHistorySnapshot {
        Self.snapshot(from: storage.session(id: sessionID))
    }

    var updates: AnyPublisher<PickyToolHistorySnapshot, Never> {
        let sessionID = sessionID
        return storage.changes.map { publication in
            Self.snapshot(from: publication.finalSnapshot.session(id: sessionID))
        }.eraseToAnyPublisher()
    }

    func load(toolCallID: String, expectedFile: String, part: PickyToolHistoryDetailPart, cursor: String?) async throws -> PickyToolHistoryDetailResult {
        guard matches(toolCallID: toolCallID, expectedFile: expectedFile) else {
            return sourceChanged(toolCallID: toolCallID, expectedFile: expectedFile, part: part)
        }
        let result = try await client.getToolHistoryDetail(
            sessionId: sessionID, toolCallId: toolCallID, expectedSessionFile: expectedFile, part: part, cursor: cursor
        )
        return matches(toolCallID: toolCallID, expectedFile: expectedFile)
            ? result : sourceChanged(toolCallID: toolCallID, expectedFile: expectedFile, part: part)
    }

    private func matches(toolCallID: String, expectedFile: String) -> Bool {
        let snapshot = snapshot
        return snapshot.sessionFilePath == expectedFile && snapshot.tools.contains { $0.toolCallId == toolCallID }
    }

    private func sourceChanged(toolCallID: String, expectedFile: String, part: PickyToolHistoryDetailPart) -> PickyToolHistoryDetailResult {
        PickyToolHistoryDetailResult(
            sessionId: sessionID, requestId: "", toolCallId: toolCallID,
            expectedSessionFile: expectedFile, part: part, status: .sourceChanged,
            reason: "sourceChanged"
        )
    }

    private static func snapshot(from card: PickySessionListViewModel.SessionCard?) -> PickyToolHistorySnapshot {
        PickyToolHistorySnapshot(tools: card?.tools ?? [], sessionFilePath: card?.piSessionFilePath, workingDirectory: card?.cwd)
    }
}

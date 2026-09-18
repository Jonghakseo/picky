import Foundation

enum PickyToolHistoryDetailRequestError: LocalizedError, Equatable {
    case timedOut
    case disconnected
    case daemonError(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: "Timed out waiting for tool history detail"
        case .disconnected: "picky-agentd disconnected while waiting for tool history detail"
        case .daemonError(let message): message
        }
    }
}

extension PickyAgentClient {
    func getToolHistoryDetail(
        sessionId: String,
        toolCallId: String,
        expectedSessionFile: String,
        part: PickyToolHistoryDetailPart,
        cursor: String? = nil
    ) async throws -> PickyToolHistoryDetailResult {
        try await getToolHistoryDetail(
            sessionId: sessionId, toolCallId: toolCallId,
            expectedSessionFile: expectedSessionFile, part: part, cursor: cursor, timeout: 5
        )
    }

    func getToolHistoryDetail(
        sessionId: String,
        toolCallId: String,
        expectedSessionFile: String,
        part: PickyToolHistoryDetailPart,
        cursor: String?,
        timeout: TimeInterval
    ) async throws -> PickyToolHistoryDetailResult {
        try Task.checkCancellation()
        let command = PickyCommandEnvelope(
            toolHistorySessionID: sessionId,
            toolCallId: toolCallId, expectedSessionFile: expectedSessionFile, part: part, cursor: cursor
        )
        // Register before send so an immediate unicast reply cannot be lost.
        let events = self.events
        let (outcomes, completion) = AsyncStream<Result<PickyToolHistoryDetailResult, Error>>.makeStream()
        let observer = Task {
            for await event in events {
                switch event {
                case .disconnected:
                    completion.yield(.failure(PickyToolHistoryDetailRequestError.disconnected))
                    return
                case .protocolEvent(let envelope):
                    switch envelope.event {
                    case .toolHistoryDetailResult(let result)
                        where result.requestId == command.id && result.sessionId == sessionId
                            && result.toolCallId == toolCallId && result.expectedSessionFile == expectedSessionFile
                            && result.part == part:
                        completion.yield(.success(result))
                        return
                    case .error(let error) where error.commandId == command.id:
                        completion.yield(.failure(PickyToolHistoryDetailRequestError.daemonError(error.message)))
                        return
                    default: break
                    }
                default: break
                }
            }
            completion.yield(.failure(PickyToolHistoryDetailRequestError.disconnected))
        }
        let sender = Task {
            do { try await send(command) }
            catch { completion.yield(.failure(error)) }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                completion.yield(.failure(PickyToolHistoryDetailRequestError.timedOut))
            } catch { /* Cancelled when another outcome wins. */ }
        }
        // Do not race eventTask.value inside a task group: cancelling the group
        // would still wait for that unstructured task and could hang forever.
        defer {
            observer.cancel()
            sender.cancel()
            timer.cancel()
            completion.finish()
        }
        for await outcome in outcomes {
            try Task.checkCancellation()
            return try outcome.get()
        }
        throw CancellationError()
    }
}

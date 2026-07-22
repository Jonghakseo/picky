//
//  PickyAgentClient.swift
//  Picky
//
//  Local WebSocket client for picky-agentd plus fake-friendly abstractions.
//

import Foundation

struct PickyAgentSubmission: Equatable {
    let transcript: String
    let context: PickyContextPacket
}

protocol PickyAgentClient: AnyObject {
    var events: AsyncStream<PickyClientEvent> { get }
    func connect() async
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt
    func send(_ command: PickyCommandEnvelope) async throws
    func listRewindTargets(sessionId: String) async throws -> [PickyRewindTarget]
    func rewindSession(sessionId: String, entryId: String) async throws
    /// Number of daemons `broadcast(_:)` will attempt to deliver to. Read
    /// synchronously before calling `broadcast` so the caller can set up
    /// reply aggregation. Defaults to 1 (single-daemon clients); the router
    /// overrides this to `1 + active child daemons`.
    var broadcastTargetCount: Int { get }
    /// Send the same sessionless command to every daemon backing this client.
    /// Returns the number of daemons the command was successfully delivered to;
    /// callers use this as the expected reply count for any per-daemon response
    /// event. The default implementation just calls `send` and returns 1, so
    /// single-daemon stubs (tests, local fallback) keep working unchanged.
    func broadcast(_ command: PickyCommandEnvelope) async throws -> Int
    /// Sends `command` and waits up to `timeout` for a server-side
    /// `type="error"` event matching `command.id`. Returns that event when the
    /// daemon rejects the command (e.g. `Unknown session: …`) so the caller
    /// can surface a real failure instead of treating fire-and-forget `send`
    /// as a successful submission. Returns `nil` if no error arrives in time
    /// — agentd does not currently emit positive acks, so absence of error
    /// within the timeout is treated as success. Throws the underlying
    /// transport error on connection failure.
    ///
    /// The default implementation simply forwards to `send` and returns nil,
    /// because intercepting error events requires owning a (single-subscriber)
    /// fanout layer over the events stream. Only `PickyAgentClientRouter`
    /// overrides this; the raw `WebSocketPickyAgentClient` doesn't, because
    /// its events stream is consumed exclusively by either the router or a
    /// dedicated consumer like `CompanionManager`.
    func sendAwaitingError(_ command: PickyCommandEnvelope, timeout: TimeInterval) async throws -> PickyErrorEvent?
    func disconnect()
}

enum PickyRewindTargetRequestError: LocalizedError, Equatable {
    case timedOut
    case disconnected
    case daemonError(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: "Timed out waiting for rewind targets"
        case .disconnected: "picky-agentd disconnected while waiting for rewind targets"
        case .daemonError(let message): message
        }
    }
}

extension PickyAgentClient {
    func listRewindTargets(sessionId: String) async throws -> [PickyRewindTarget] {
        let command = PickyCommandEnvelope(type: .listRewindTargets, sessionId: sessionId)
        // Subscribe synchronously BEFORE sending. Accessing `events` registers the subscriber
        // immediately (the router buffers per-subscriber), so a fast daemon reply cannot land
        // before we are wired up. Deferring this access into the Task would reintroduce the
        // missed-broadcast race the router explicitly warns about.
        let stream = events
        let eventTask = Task { () throws -> [PickyRewindTarget] in
            for await clientEvent in stream {
                guard case .protocolEvent(let envelope) = clientEvent else { continue }
                switch envelope.event {
                case .rewindTargetsSnapshot(let snapshotSessionId, let requestId, let targets)
                    where snapshotSessionId == sessionId && requestId == command.id:
                    return targets
                case .error(let error) where error.commandId == command.id:
                    throw PickyRewindTargetRequestError.daemonError(error.message)
                default:
                    continue
                }
            }
            throw PickyRewindTargetRequestError.disconnected
        }
        defer { eventTask.cancel() }
        try await send(command)
        return try await withThrowingTaskGroup(of: [PickyRewindTarget].self) { group in
            group.addTask { try await eventTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw PickyRewindTargetRequestError.timedOut
            }
            let targets = try await group.next() ?? []
            group.cancelAll()
            return targets
        }
    }

    func rewindSession(sessionId: String, entryId: String) async throws {
        try await send(PickyCommandEnvelope(type: .rewindSession, sessionId: sessionId, entryId: entryId))
    }

    func sendAwaitingError(_ command: PickyCommandEnvelope, timeout: TimeInterval = 1.0) async throws -> PickyErrorEvent? {
        try await send(command)
        return nil
    }

    var broadcastTargetCount: Int { 1 }

    func broadcast(_ command: PickyCommandEnvelope) async throws -> Int {
        try await send(command)
        return 1
    }
}

struct PickyAgentSubmissionReceipt: Equatable {
    let sessionID: String
    let message: String
}

enum PickyClientEvent: Equatable {
    case connected
    case disconnected
    case protocolEvent(PickyEventEnvelope)
    case recoverableError(String)
}

enum PickyAgentClientError: LocalizedError, Equatable {
    case disconnected
    case malformedEvent(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: "picky-agentd is disconnected"
        case .malformedEvent(let message): "Malformed picky-agentd event: \(message)"
        }
    }
}

final class LocalStubPickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async {
        pickyAgentClientLog("stub connected")
        continuation.yield(.connected)
    }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        let stableSessionInput = [
            submission.context.source,
            submission.context.transcript ?? "",
            submission.context.activeApp?.bundleId ?? "unknown-app",
            submission.context.activeWindow?.title ?? "unknown-window"
        ].joined(separator: "|")
        let sessionID = "local-stub-\(abs(stableSessionInput.hashValue))"

        pickyAgentClientLog("stub submit context=\(submission.context.id) transcriptChars=\(submission.transcript.count) receipt=\(sessionID)")
        return PickyAgentSubmissionReceipt(
            sessionID: sessionID,
            message: "Task captured locally. picky-agentd integration will run this through Pi when the daemon is connected."
        )
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        pickyAgentClientLog("stub send \(command.logSummary)")
    }
    func disconnect() {
        pickyAgentClientLog("stub disconnected")
        continuation.yield(.disconnected)
    }
}

protocol PickyWebSocketTask: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: PickyWebSocketTask {}

protocol PickyWebSocketTaskMaking {
    func makeWebSocketTask(url: URL, token: String) -> PickyWebSocketTask
}

struct URLSessionPickyWebSocketTaskFactory: PickyWebSocketTaskMaking {
    private static let maximumMessageSize = 16 * 1024 * 1024

    func makeWebSocketTask(url: URL, token: String) -> PickyWebSocketTask {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        return task
    }
}

final class WebSocketPickyAgentClient: PickyAgentClient {
    struct Configuration: Equatable {
        var host = "127.0.0.1"
        var port: Int
        var token: String
        var reconnectDelay: TimeInterval = 1
        /// Grace period for commands issued immediately after `connect()`. URLSession's
        /// `resume()` returns before the websocket server's hello frame is received, so callers
        /// that spawn a fresh child daemon and immediately send the first command need `send` to
        /// wait briefly for the connection to become usable.
        var connectionReadyTimeout: TimeInterval = 5

        var url: URL {
            var components = URLComponents()
            components.scheme = "ws"
            components.host = host
            components.port = port
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            return components.url!
        }
    }

    private let configuration: Configuration
    private let factory: PickyWebSocketTaskMaking
    private let encoder = JSONEncoder.pickyAgentProtocolEncoder()
    private let decoder = JSONDecoder.pickyAgentProtocolDecoder()
    private var task: PickyWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var connected = false
    /// Wallclock instant of the most recent `connect()` call. Used by the
    /// receive loop to report how long the WebSocket sat idle after
    /// `resume()` before the first frame arrived — a critical signal for
    /// diagnosing handshake stalls where TCP completes but the daemon never
    /// sends `hello`.
    private var connectStartedAt: Date?
    private var hasReceivedFirstFrame = false
    /// Monotonically increasing count of `connect()` invocations on this
    /// instance, including reconnects after a receive-loop drop. Surfaced in
    /// logs so the diagnostics bundle reveals reconnect storms (e.g. daemon
    /// crashing and being respawned).
    private var connectAttemptCount = 0
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    init(configuration: Configuration, factory: PickyWebSocketTaskMaking = URLSessionPickyWebSocketTaskFactory()) {
        self.configuration = configuration
        self.factory = factory
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async {
        guard task == nil else { return }
        connectAttemptCount += 1
        connectStartedAt = Date()
        hasReceivedFirstFrame = false
        pickyAgentClientLog("connecting ws://\(configuration.host):\(configuration.port) attempt=#\(connectAttemptCount)")
        let socket = factory.makeWebSocketTask(url: configuration.url, token: configuration.token)
        task = socket
        socket.resume()
        pickyAgentClientLog("socket resumed ws://\(configuration.host):\(configuration.port)")
        startReceiveLoop(socket)
    }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        pickyAgentClientLog("submit context=\(submission.context.id) source=\(submission.context.source) transcriptChars=\(submission.transcript.count)")
        let command = PickyCommandEnvelope(type: .routeTask, context: submission.context)
        try await send(command)
        return PickyAgentSubmissionReceipt(sessionID: command.id, message: "")
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        guard task != nil else {
            pickyAgentClientLog("send failed disconnected \(command.logSummary)")
            throw PickyAgentClientError.disconnected
        }
        if !connected {
            try await waitUntilConnectedForSend()
        }
        guard connected, let task else {
            pickyAgentClientLog("send failed disconnected \(command.logSummary)")
            throw PickyAgentClientError.disconnected
        }
        pickyAgentClientLog("send \(command.logSummary)")
        let data = try encoder.encode(command)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    private func waitUntilConnectedForSend() async throws {
        let timeout = max(configuration.connectionReadyTimeout, 0)
        let deadline = Date().addingTimeInterval(timeout)
        while !connected {
            if task == nil { throw PickyAgentClientError.disconnected }
            if timeout == 0 || Date() >= deadline { throw PickyAgentClientError.disconnected }
            let sleepSeconds = min(0.01, max(deadline.timeIntervalSinceNow, 0))
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

    func disconnect() {
        pickyAgentClientLog("disconnect requested")
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        continuation.yield(.disconnected)
    }

    private func startReceiveLoop(_ socket: PickyWebSocketTask) {
        receiveLoop?.cancel()
        pickyAgentClientLog("receive loop started awaiting first frame")
        receiveLoop = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    try self.handle(message)
                } catch is CancellationError {
                    return
                } catch {
                    let elapsedMs = self.connectStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                    pickyAgentClientLog("receive loop disconnected error=\(error.localizedDescription) elapsedSinceConnectMs=\(elapsedMs) firstFrameSeen=\(self.hasReceivedFirstFrame)")
                    self.connected = false
                    self.task = nil
                    self.continuation.yield(.disconnected)
                    try? await Task.sleep(nanoseconds: UInt64(self.configuration.reconnectDelay * 1_000_000_000))
                    if !Task.isCancelled { await self.connect() }
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        let messageBytes: Int
        switch message {
        case .string(let text):
            data = Data(text.utf8)
            messageBytes = data.count
        case .data(let messageData):
            data = messageData
            messageBytes = messageData.count
        @unknown default:
            throw PickyAgentClientError.malformedEvent("unsupported message kind")
        }

        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            let elapsedMs = connectStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            pickyAgentClientLog("first frame received bytes=\(messageBytes) elapsedSinceConnectMs=\(elapsedMs)")
        }

        do {
            let event = try decoder.decode(PickyEventEnvelope.self, from: data)
            if !connected, case .hello = event.event {
                connected = true
                let elapsedMs = connectStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                pickyAgentClientLog("connected ws://\(configuration.host):\(configuration.port) elapsedSinceConnectMs=\(elapsedMs)")
                continuation.yield(.connected)
            } else if !connected {
                // Pre-`hello` frame: daemon sent something other than the
                // expected handshake greeting. Logging the envelope summary
                // here catches protocol-version mismatches that would
                // otherwise look like an indefinite stall.
                pickyAgentClientLog("pre-hello frame \(event.logSummary)")
            }
            pickyAgentClientLog("receive \(event.logSummary)")
            continuation.yield(.protocolEvent(event))
        } catch {
            pickyAgentClientLog("decode error=\(error.localizedDescription) bytes=\(messageBytes)")
            continuation.yield(.recoverableError(error.localizedDescription))
        }
    }
}

private func pickyAgentClientLog(_ message: String) {
    PickyLog.notice(.agentClient, prefix: "🔌 Picky agent client —", message: message)
}

private extension PickyCommandEnvelope {
    var logSummary: String {
        var parts = ["type=\(type.rawValue)", "id=\(id)"]
        if let sessionId { parts.append("session=\(sessionId)") }
        if let context {
            parts.append("context=\(context.id)")
            parts.append("source=\(context.source)")
            parts.append("transcriptChars=\(context.transcript?.count ?? 0)")
        }
        if let text { parts.append("textChars=\(text.count)") }
        if let source { parts.append("sourceChars=\(source.count)") }
        if let requestId { parts.append("request=\(requestId)") }
        if let artifactId { parts.append("artifact=\(artifactId)") }
        if let title { parts.append("titleChars=\(title.count)") }
        if let instructions { parts.append("instructionsChars=\(instructions.count)") }
        if let cwd { parts.append("cwd=\(cwd)") }
        if let errorMessage { parts.append("errorChars=\(errorMessage.count)") }
        if let enabled { parts.append("enabled=\(enabled)") }
        if let mainAgentModelPattern { parts.append("mainAgentModel=\(mainAgentModelPattern.isEmpty ? "<auto>" : mainAgentModelPattern)") }
        if let entryId { parts.append("entry=\(entryId)") }
        if let baselinePiMessageId { parts.append("baselinePiMessage=\(baselinePiMessageId)") }
        if let action { parts.append("action=\(action.rawValue)") }
        return parts.joined(separator: " ")
    }
}

private extension PickyEventEnvelope {
    var logSummary: String {
        switch event {
        case .hello:
            return "type=hello id=\(id)"
        case .quickReply(let reply):
            return "type=quickReply id=\(id) context=\(reply.contextId) textChars=\(reply.text.count)"
        case .mainTurnSettled(let contextId):
            return "type=mainTurnSettled id=\(id) context=\(contextId)"
        case .mainNarrationChunk(let chunk):
            return "type=mainNarrationChunk id=\(id) context=\(chunk.contextId) textChars=\(chunk.text.count)"
        case .mainVisualNarrationSegmentPrepared(let segment):
            return "type=mainVisualNarrationSegmentPrepared id=\(id) context=\(segment.identity.contextId) turn=\(segment.identity.turnToken) ordinal=\(segment.identity.ordinal)"
        case .mainVisualNarrationSegmentSentence(let sentence):
            return "type=mainVisualNarrationSegmentSentence id=\(id) context=\(sentence.identity.contextId) turn=\(sentence.identity.turnToken) ordinal=\(sentence.identity.ordinal) index=\(sentence.index) textChars=\(sentence.text.count)"
        case .mainVisualNarrationSegmentCommitted(let segment):
            return "type=mainVisualNarrationSegmentCommitted id=\(id) context=\(segment.identity.contextId) turn=\(segment.identity.turnToken) ordinal=\(segment.identity.ordinal) sentences=\(segment.sentenceCount) textChars=\(segment.text?.count ?? 0)"
        case .mainMessagesSnapshot(let messages):
            return "type=mainMessagesSnapshot id=\(id) messages=\(messages.count)"
        case .mainMessageAppended(let message):
            return "type=mainMessageAppended id=\(id) role=\(message.role.rawValue) textChars=\(message.text.count)"
        case .mainAgentModelsSnapshot(let models):
            return "type=mainAgentModelsSnapshot id=\(id) models=\(models.count)"
        case .mainAgentSessionInfoUpdated(let sessionFilePath, let cwd):
            return "type=mainAgentSessionInfoUpdated id=\(id) hasSessionFile=\(sessionFilePath != nil ? 1 : 0) hasCwd=\(cwd != nil ? 1 : 0)"
        case .sessionSnapshot(let snapshot):
            return "type=sessionSnapshot id=\(id) sessions=\(snapshot.sessions.count) complete=\(snapshot.isComplete) skipped=\(snapshot.skippedSessionCount)"
        case .sessionUpdated(let session):
            return "type=sessionUpdated id=\(id) session=\(session.id) status=\(session.status.rawValue)"
        case .sessionArchivedAuthoritative(let sessionId, let archived):
            return "type=sessionArchivedAuthoritative id=\(id) session=\(sessionId) archived=\(archived)"
        case .sessionResourcesReloaded(let sessionId):
            return "type=sessionResourcesReloaded id=\(id) session=\(sessionId)"
        case .pluginsReloaded(let summary):
            return "type=pluginsReloaded id=\(id) request=\(summary.requestId ?? "none") picky=\(summary.pickyReloaded ? 1 : 0) reloaded=\(summary.pickleReloadedCount) aborted=\(summary.pickleAbortedCount) deferred=\(summary.pickleDeferredCount)"
        case .packageOperationProgress(let progress):
            return "type=packageOperationProgress id=\(id) request=\(progress.requestId) operation=\(progress.operation.rawValue) sourceChars=\(progress.source.count) messageChars=\(progress.message.count)"
        case .packageOperationCompleted(let result):
            return "type=packageOperationCompleted id=\(id) request=\(result.requestId) operation=\(result.operation.rawValue) sourceChars=\(result.source.count) ok=\(result.ok ? 1 : 0) errorChars=\(result.errorMessage?.count ?? 0)"
        case .sessionLogAppended(let sessionId, let line):
            return "type=sessionLogAppended id=\(id) session=\(sessionId) lineChars=\(line.count)"
        case .toolActivityUpdated(let sessionId, let tool):
            return "type=toolActivityUpdated id=\(id) session=\(sessionId) tool=\(tool.name) status=\(tool.status)"
        case .sessionTodoStateUpdated(let sessionId, let todoState, let seq):
            return "type=sessionTodoStateUpdated id=\(id) session=\(sessionId) tasks=\(todoState?.tasks.count ?? 0) seq=\(seq)"
        case .extensionUiRequest(let request):
            return "type=extensionUiRequest id=\(id) session=\(request.sessionId) request=\(request.id) method=\(request.method)"
        case .artifactUpdated(let sessionId, let artifact):
            return "type=artifactUpdated id=\(id) session=\(sessionId) artifact=\(artifact.id) kind=\(artifact.kind)"
        case .pointerOverlayRequested(let request):
            return "type=pointerOverlayRequested id=\(id) request=\(request.id) screen=\(request.screenId ?? "primary")"
        case .annotationOverlayRequested(let request):
            return "type=annotationOverlayRequested id=\(id) request=\(request.id) mode=\(request.mode.rawValue) annotations=\(request.annotations.count)"
        case .pickleHandoffRequested(let request):
            return "type=pickleHandoffRequested id=\(id) request=\(request.requestId) context=\(request.context.id) titleChars=\(request.title.count) cwd=\(request.cwd)"
        case .pickleBridgeRequested(let request):
            return "type=pickleBridgeRequested id=\(id) request=\(request.requestId) operation=\(request.operation.rawValue) session=\(request.sessionId ?? "none")"
        case .externalEntryRequested(let request):
            return "type=externalEntryRequested id=\(id) request=\(request.requestId) kind=\(request.kind.rawValue) cwd=\(request.cwd ?? "none")"
        case .externalEntryAccepted(let event):
            return "type=externalEntryAccepted id=\(id) command=\(event.commandId) kind=\(event.kind.rawValue) context=\(event.contextId) session=\(event.sessionId ?? "none") group=\(event.group ?? "none")"
        case .dockGroupsRequested(let requestId):
            return "type=dockGroupsRequested id=\(id) request=\(requestId)"
        case .pushToTalkControlRequested(let request):
            return "type=pushToTalkControlRequested id=\(id) request=\(request.requestId) action=\(request.action.rawValue)"
        case .slashCommandsSnapshot(let sessionId, let requestId, let commands):
            return "type=slashCommandsSnapshot id=\(id) session=\(sessionId) request=\(requestId ?? "none") commands=\(commands.count)"
        case .autocompleteCapabilitiesSnapshot(let snapshot):
            return "type=autocompleteCapabilitiesSnapshot id=\(id) session=\(snapshot.sessionId) request=\(snapshot.requestId) generation=\(snapshot.generation) triggers=\(snapshot.triggerCharacters.count)"
        case .autocompleteSuggestionsSnapshot(let snapshot):
            return "type=autocompleteSuggestionsSnapshot id=\(id) session=\(snapshot.sessionId) request=\(snapshot.requestId) generation=\(snapshot.generation) revision=\(snapshot.draftRevision) suggestions=\(snapshot.items.count)"
        case .autocompleteCompletionApplied(let completion):
            return "type=autocompleteCompletionApplied id=\(id) session=\(completion.sessionId) request=\(completion.requestId) generation=\(completion.generation) revision=\(completion.draftRevision) lines=\(completion.lines.count)"
        case .rewindTargetsSnapshot(let sessionId, let requestId, let targets):
            return "type=rewindTargetsSnapshot id=\(id) session=\(sessionId) request=\(requestId ?? "none") targets=\(targets.count)"
        case .sessionRewound(let sessionId, let editorText, let removedIds):
            return "type=sessionRewound id=\(id) session=\(sessionId) editorTextChars=\(editorText?.count ?? 0) removed=\(removedIds.count)"
        case .sessionMessageAppended(let sessionId, _, let seq):
            return "type=sessionMessageAppended id=\(id) session=\(sessionId) seq=\(seq)"
        case .sessionMessagesImported(let sessionId, let messages, let seq):
            return "type=sessionMessagesImported id=\(id) session=\(sessionId) messages=\(messages.count) seq=\(seq)"
        case .sessionMessageReplaced(let sessionId, let messageId, _, let seq):
            return "type=sessionMessageReplaced id=\(id) session=\(sessionId) message=\(messageId) seq=\(seq)"
        case .sessionMessageRemoved(let sessionId, let messageId, let seq):
            return "type=sessionMessageRemoved id=\(id) session=\(sessionId) message=\(messageId) seq=\(seq)"
        case .sessionQueueUpdated(let sessionId, let steering, let followUp, _, _, let seq):
            return "type=sessionQueueUpdated id=\(id) session=\(sessionId) steering=\(steering.count) followUp=\(followUp.count) seq=\(seq)"
        case .sessionActivityUpdated(let sessionId, let activitySummary, let seq):
            return "type=sessionActivityUpdated id=\(id) session=\(sessionId) edit=\(activitySummary.edit) bash=\(activitySummary.bash) thinking=\(activitySummary.thinking) other=\(activitySummary.other) seq=\(seq)"
        case .terminalSessionSyncOutcome(let outcome):
            return "type=terminalSessionSyncOutcome id=\(id) session=\(outcome.sessionId) baselineFound=\(outcome.baselineFound) imported=\(outcome.importedMessageCount)"
        case .error(let error):
            return "type=error id=\(id) command=\(error.commandId ?? "none") code=\(error.code)"
        case .unknown(let type):
            return "type=unknown(\(type)) id=\(id)"
        }
    }
}

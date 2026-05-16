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

extension PickyAgentClient {
    func sendAwaitingError(_ command: PickyCommandEnvelope, timeout: TimeInterval = 1.0) async throws -> PickyErrorEvent? {
        try await send(command)
        return nil
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
        if let requestId { parts.append("request=\(requestId)") }
        if let artifactId { parts.append("artifact=\(artifactId)") }
        if let title { parts.append("titleChars=\(title.count)") }
        if let instructions { parts.append("instructionsChars=\(instructions.count)") }
        if let cwd { parts.append("cwd=\(cwd)") }
        if let errorMessage { parts.append("errorChars=\(errorMessage.count)") }
        if let enabled { parts.append("enabled=\(enabled)") }
        if let mode { parts.append("mode=\(mode)") }
        if let mainAgentModelPattern { parts.append("mainAgentModel=\(mainAgentModelPattern.isEmpty ? "<auto>" : mainAgentModelPattern)") }
        if let provider { parts.append("provider=\(provider)") }
        if let modelOrDeployment { parts.append("modelOrDeployment=\(modelOrDeployment)") }
        if apiKey != nil { parts.append("apiKey=<redacted>") }
        if let inputId { parts.append("input=\(inputId.uuidString)") }
        if let audioBase64 { parts.append("audioBase64Chars=\(audioBase64.count)") }
        if let baselinePiMessageId { parts.append("baselinePiMessage=\(baselinePiMessageId)") }
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
        case .mainMessagesSnapshot(let messages):
            return "type=mainMessagesSnapshot id=\(id) messages=\(messages.count)"
        case .mainMessageAppended(let message):
            return "type=mainMessageAppended id=\(id) role=\(message.role.rawValue) textChars=\(message.text.count)"
        case .mainAgentModelsSnapshot(let models):
            return "type=mainAgentModelsSnapshot id=\(id) models=\(models.count)"
        case .mainAgentSessionInfoUpdated(let sessionFilePath, let cwd):
            return "type=mainAgentSessionInfoUpdated id=\(id) hasSessionFile=\(sessionFilePath != nil ? 1 : 0) hasCwd=\(cwd != nil ? 1 : 0)"
        case .mainRealtimeStateChanged(let state):
            return "type=mainRealtimeStateChanged id=\(id) state=\(state.state.rawValue) messageChars=\(state.message?.count ?? 0)"
        case .mainRealtimeInputTranscriptDelta(let inputId, let delta):
            return "type=mainRealtimeInputTranscriptDelta id=\(id) input=\(inputId.uuidString) deltaChars=\(delta.count)"
        case .mainRealtimeInputTranscriptCompleted(let inputId, let transcript):
            return "type=mainRealtimeInputTranscriptCompleted id=\(id) input=\(inputId.uuidString) transcriptChars=\(transcript.count)"
        case .mainRealtimeOutputAudioDelta(let inputId, let audioBase64):
            return "type=mainRealtimeOutputAudioDelta id=\(id) input=\(inputId?.uuidString ?? "none") audioBase64Chars=\(audioBase64.count)"
        case .mainRealtimeOutputAudioDone(let inputId):
            return "type=mainRealtimeOutputAudioDone id=\(id) input=\(inputId?.uuidString ?? "none")"
        case .mainRealtimeOutputTranscriptDelta(let inputId, let delta):
            return "type=mainRealtimeOutputTranscriptDelta id=\(id) input=\(inputId?.uuidString ?? "none") deltaChars=\(delta.count)"
        case .mainRealtimeOutputTranscriptCompleted(let inputId, let transcript):
            return "type=mainRealtimeOutputTranscriptCompleted id=\(id) input=\(inputId?.uuidString ?? "none") transcriptChars=\(transcript.count)"
        case .mainRealtimeTurnDone(let done):
            return "type=mainRealtimeTurnDone id=\(id) input=\(done.inputId?.uuidString ?? "none") status=\(done.status.rawValue) transcriptChars=\(done.finalTranscript?.count ?? 0)"
        case .sessionSnapshot(let sessions):
            return "type=sessionSnapshot id=\(id) sessions=\(sessions.count)"
        case .sessionUpdated(let session):
            return "type=sessionUpdated id=\(id) session=\(session.id) status=\(session.status.rawValue)"
        case .sessionLogAppended(let sessionId, let line):
            return "type=sessionLogAppended id=\(id) session=\(sessionId) lineChars=\(line.count)"
        case .toolActivityUpdated(let sessionId, let tool):
            return "type=toolActivityUpdated id=\(id) session=\(sessionId) tool=\(tool.name) status=\(tool.status)"
        case .extensionUiRequest(let request):
            return "type=extensionUiRequest id=\(id) session=\(request.sessionId) request=\(request.id) method=\(request.method)"
        case .artifactUpdated(let sessionId, let artifact):
            return "type=artifactUpdated id=\(id) session=\(sessionId) artifact=\(artifact.id) kind=\(artifact.kind)"
        case .pointerOverlayRequested(let request):
            return "type=pointerOverlayRequested id=\(id) request=\(request.id) screen=\(request.screenId ?? "primary")"
        case .narrateProgressRequested(let request):
            return "type=narrateProgressRequested id=\(id) session=\(request.sessionId ?? "none") chars=\(request.text.count)"
        case .pickleHandoffRequested(let request):
            return "type=pickleHandoffRequested id=\(id) request=\(request.requestId) context=\(request.context.id) titleChars=\(request.title.count) cwd=\(request.cwd)"
        case .pickleBridgeRequested(let request):
            return "type=pickleBridgeRequested id=\(id) request=\(request.requestId) operation=\(request.operation.rawValue) session=\(request.sessionId ?? "none")"
        case .externalEntryRequested(let request):
            return "type=externalEntryRequested id=\(id) request=\(request.requestId) kind=\(request.kind.rawValue) cwd=\(request.cwd ?? "none")"
        case .slashCommandsSnapshot(let sessionId, let commands):
            return "type=slashCommandsSnapshot id=\(id) session=\(sessionId) commands=\(commands.count)"
        case .sessionMessageAppended(let sessionId, _, let seq):
            return "type=sessionMessageAppended id=\(id) session=\(sessionId) seq=\(seq)"
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

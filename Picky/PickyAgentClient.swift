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
    func disconnect()
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

    func connect() async { continuation.yield(.connected) }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        let stableSessionInput = [
            submission.context.source,
            submission.context.transcript ?? "",
            submission.context.activeApp?.bundleId ?? "unknown-app",
            submission.context.activeWindow?.title ?? "unknown-window"
        ].joined(separator: "|")
        let sessionID = "local-stub-\(abs(stableSessionInput.hashValue))"

        return PickyAgentSubmissionReceipt(
            sessionID: sessionID,
            message: "Task captured locally. picky-agentd integration will run this through Pi when the daemon is connected."
        )
    }

    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() { continuation.yield(.disconnected) }
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
    func makeWebSocketTask(url: URL, token: String) -> PickyWebSocketTask {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return URLSession.shared.webSocketTask(with: request)
    }
}

final class WebSocketPickyAgentClient: PickyAgentClient {
    struct Configuration: Equatable {
        var host = "127.0.0.1"
        var port: Int
        var token: String
        var reconnectDelay: TimeInterval = 1

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
        let socket = factory.makeWebSocketTask(url: configuration.url, token: configuration.token)
        task = socket
        socket.resume()
        connected = true
        continuation.yield(.connected)
        startReceiveLoop(socket)
    }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        let command = PickyCommandEnvelope(type: .routeTask, context: submission.context)
        try await send(command)
        return PickyAgentSubmissionReceipt(sessionID: command.id, message: "")
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        guard connected, let task else { throw PickyAgentClientError.disconnected }
        let data = try encoder.encode(command)
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        continuation.yield(.disconnected)
    }

    private func startReceiveLoop(_ socket: PickyWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    try self.handle(message)
                } catch is CancellationError {
                    return
                } catch {
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
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let messageData): data = messageData
        @unknown default: throw PickyAgentClientError.malformedEvent("unsupported message kind")
        }

        do {
            let event = try decoder.decode(PickyEventEnvelope.self, from: data)
            continuation.yield(.protocolEvent(event))
        } catch {
            continuation.yield(.recoverableError(error.localizedDescription))
        }
    }
}

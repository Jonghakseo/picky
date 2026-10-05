//
//  PickyRemoteHubClient.swift
//  Picky
//
//  WebSocket between the remote hub inside Picky.app and the local gateway.
//  Loopback only, bearer-token authenticated, reconnecting.
//

import Foundation

@MainActor
protocol PickyRemoteHubTransport: AnyObject {
    func connect(url: URL, token: String)
    func disconnect()
    func send(_ message: PickyHubToGatewayMessage)
    var onMessage: ((PickyGatewayToHubMessage) -> Void)? { get set }
    var onConnectedChange: ((Bool) -> Void)? { get set }
}

@MainActor
final class PickyRemoteHubClient: PickyRemoteHubTransport {
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 10]

    var onMessage: ((PickyGatewayToHubMessage) -> Void)?
    var onConnectedChange: ((Bool) -> Void)?

    private let factory: PickyWebSocketTaskMaking
    private var task: PickyWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Frames go out in the order `send` was called: the handshake has to reach
    /// the gateway before the snapshots that follow it.
    private var sendChain: Task<Void, Never>?
    private var url: URL?
    private var token: String?
    private var attempt = 0
    private var generation = 0
    private(set) var isConnected = false {
        didSet { if isConnected != oldValue { onConnectedChange?(isConnected) } }
    }

    init(factory: PickyWebSocketTaskMaking = URLSessionPickyWebSocketTaskFactory()) {
        self.factory = factory
    }

    func connect(url: URL, token: String) {
        self.url = url
        self.token = token
        attempt = 0
        // A reconnect scheduled by an earlier drop would otherwise open a
        // second socket behind this one; the gateway drops the first, and the
        // handshake that went out on it is lost.
        cancelReconnect()
        openSocket()
    }

    func disconnect() {
        url = nil
        token = nil
        generation &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sendChain = nil
        isConnected = false
    }

    func send(_ message: PickyHubToGatewayMessage) {
        guard let task, isConnected else { return }
        guard let data = try? PickyRemoteProtocolCodec.encodeHubMessage(message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let previous = sendChain
        sendChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await task.send(.string(text))
            } catch {
                self?.handleDrop()
            }
        }
    }

    private func openSocket() {
        guard let url, let token else { return }
        cancelReconnect()
        receiveLoop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        // Every socket starts disconnected, so each one that comes up produces
        // its own false -> true transition and therefore its own handshake.
        isConnected = false

        let socket = factory.makeWebSocketTask(url: url, token: token)
        task = socket
        sendChain = nil
        generation &+= 1
        let currentGeneration = generation
        socket.resume()

        receiveLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, currentGeneration == self.generation else { return }
                    self.handle(message)
                } catch {
                    guard let self, currentGeneration == self.generation else { return }
                    self.handleDrop()
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        // The upgrade is only confirmed once the gateway actually speaks (it
        // sends `gateway.hello` on accept). `resume()` alone also succeeds for a
        // 401 or a dead port, and anything sent in that window is thrown away.
        attempt = 0
        isConnected = true
        guard let data, let decoded = try? PickyRemoteProtocolCodec.decodeGatewayMessage(data) else { return }
        onMessage?(decoded)
    }

    private func handleDrop() {
        guard url != nil else { return }
        isConnected = false
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        scheduleReconnect()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func scheduleReconnect() {
        let delay = Self.reconnectDelays[min(attempt, Self.reconnectDelays.count - 1)]
        attempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.url != nil else { return }
            self.openSocket()
        }
    }
}

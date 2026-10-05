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

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var url: URL?
    private var token: String?
    private var attempt = 0
    private var generation = 0
    private(set) var isConnected = false {
        didSet { if isConnected != oldValue { onConnectedChange?(isConnected) } }
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(url: URL, token: String) {
        self.url = url
        self.token = token
        attempt = 0
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
        isConnected = false
    }

    func send(_ message: PickyHubToGatewayMessage) {
        guard let task, isConnected else { return }
        guard let data = try? PickyRemoteProtocolCodec.encodeHubMessage(message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.handleDrop() }
        }
    }

    private func openSocket() {
        guard let url, let token else { return }
        receiveLoop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        task = socket
        generation &+= 1
        let currentGeneration = generation
        socket.resume()
        isConnected = true

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
        guard let data, let decoded = try? PickyRemoteProtocolCodec.decodeGatewayMessage(data) else { return }
        attempt = 0
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

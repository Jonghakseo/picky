//
//  PickyDebugRouterChannel.swift
//  Picky
//
//  Debug-owned half of the `picky-debug` socket hop. The router keeps only the
//  event tap and the send primitive; request completion, structured error
//  codes, and trace publication live here so the client facade does not grow a
//  debug responsibility.
//

import Foundation

@MainActor
final class PickyDebugRouterChannel {
    typealias Send = (PickyCommandEnvelope) async throws -> Void

    /// Applies a `picky-debug` app action (snapshot, text injection,
    /// push-to-talk). Safety policy and the production input path live in the
    /// app composition root; this channel only moves the request and reply.
    var appRequestHandler: ((PickyDebugAppRequest) async throws -> JSONValue)?

    private let send: Send

    init(send: @escaping Send) {
        self.send = send
    }

    func handle(_ request: PickyDebugAppRequest) async {
        do {
            guard let appRequestHandler else { throw PickyDebugControlError.unavailable }
            let result = try await appRequestHandler(request)
            try await send(PickyCommandEnvelope(
                type: .completeDebugApp,
                requestId: request.requestId,
                result: result
            ))
        } catch {
            let debugError = error as? PickyDebugControlError
            try? await send(PickyCommandEnvelope(
                type: .completeDebugApp,
                requestId: request.requestId,
                errorMessage: debugError?.message ?? error.localizedDescription,
                errorCode: debugError?.code
            ))
        }
    }

    /// Ships one batch of redacted trace records to the primary daemon and
    /// reports whether the socket took it. A failed publish leaves no daemon
    /// sequence gap, because the daemon never assigned a sequence to those
    /// records, so the recorder has to count the loss itself.
    @discardableResult
    func publish(_ records: [PickyDebugTraceRecord]) async -> Bool {
        guard !records.isEmpty else { return true }
        do {
            try await send(PickyCommandEnvelope(type: .publishDebugTrace, records: records))
            return true
        } catch {
            return false
        }
    }
}

extension PickyDebugRouterChannel {
    /// Binds a channel to the router's authenticated primary connection. The
    /// router owns the channel, so the capture back to it stays weak.
    static func primaryConnection(of router: PickyAgentClientRouter) -> PickyDebugRouterChannel {
        PickyDebugRouterChannel { [weak router] command in
            guard let router else { throw PickyDebugControlError.unavailable }
            try await router.sendAfterCapabilityRegistration(command, on: router.primaryClient)
        }
    }
}

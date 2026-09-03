//
//  PickySessionSlashCommandController.swift
//  Picky
//
//  Owns slash-command cache, request, and epoch state for the session list
//  facade. The ViewModel remains the ObservableObject and autocomplete policy
//  owner.
//

import Foundation

@MainActor
final class PickySessionSlashCommandController {
    private let sendCommand: (PickyCommandEnvelope) async throws -> Void
    private let onSendFailure: (String) -> Void

    private(set) var commandsBySessionID: [String: [PickySlashCommand]] = [:]
    private var requestedSessionIDs = Set<String>()
    private var epochBySessionID: [String: UInt64] = [:]
    private var requestEpochByID: [String: UInt64] = [:]
    private var requestSessionByID: [String: String] = [:]
    private var requestStartedAtByID: [String: Date] = [:]

    init(
        sendCommand: @escaping (PickyCommandEnvelope) async throws -> Void,
        onSendFailure: @escaping (String) -> Void
    ) {
        self.sendCommand = sendCommand
        self.onSendFailure = onSendFailure
    }

    func ensureLoaded(sessionID: String) {
        guard commandsBySessionID[sessionID] == nil else { return }
        guard !requestedSessionIDs.contains(sessionID) else { return }
        request(sessionID: sessionID)
    }

    func refreshIfStillLoading(sessionID: String) {
        guard commandsBySessionID[sessionID] == nil else { return }
        request(sessionID: sessionID)
    }

    func applySnapshot(sessionID: String, requestID: String?, commands: [PickySlashCommand]) {
        let currentEpoch = epochBySessionID[sessionID] ?? 0
        let requestEpoch: UInt64?
        var requestStartedAt: Date?
        if let requestID {
            guard let requestSessionID = requestSessionByID.removeValue(forKey: requestID),
                  let matchedRequestEpoch = requestEpochByID.removeValue(forKey: requestID),
                  requestSessionID == sessionID else {
                let startedAt = requestStartedAtByID.removeValue(forKey: requestID)
                pickySessionLog("slash commands snapshot discarded session=\(sessionID) request=\(requestID) reason=unknown-request commands=\(commands.count) latencyMs=\(Self.millisecondsSince(startedAt))")
                return
            }
            requestStartedAt = requestStartedAtByID.removeValue(forKey: requestID)
            requestEpoch = matchedRequestEpoch
        } else {
            let staleRequestIDs = requestSessionByID
                .filter { entry in
                    entry.value == sessionID && requestEpochByID[entry.key] != currentEpoch
                }
                .map(\.key)
            if !staleRequestIDs.isEmpty {
                for staleRequestID in staleRequestIDs {
                    requestSessionByID.removeValue(forKey: staleRequestID)
                    requestEpochByID.removeValue(forKey: staleRequestID)
                    requestStartedAtByID.removeValue(forKey: staleRequestID)
                }
                pickySessionLog("slash commands snapshot discarded session=\(sessionID) reason=no-request-id-after-epoch-invalidation staleRequests=\(staleRequestIDs.count) commands=\(commands.count)")
                return
            }
            let matchingRequestIDs = requestSessionByID
                .filter { entry in
                    entry.value == sessionID && requestEpochByID[entry.key] == currentEpoch
                }
                .map(\.key)
            guard !matchingRequestIDs.isEmpty else {
                pickySessionLog("slash commands snapshot discarded session=\(sessionID) reason=no-request-id-without-inflight commands=\(commands.count)")
                return
            }
            requestStartedAt = matchingRequestIDs
                .compactMap { requestStartedAtByID[$0] }
                .min()
            requestEpoch = currentEpoch
        }
        guard requestEpoch == currentEpoch else {
            pickySessionLog("slash commands snapshot discarded session=\(sessionID) requestEpoch=\(requestEpoch ?? 0) currentEpoch=\(currentEpoch) commands=\(commands.count) latencyMs=\(Self.millisecondsSince(requestStartedAt))")
            return
        }
        clearRequests(sessionID: sessionID)
        pickySessionLog("slash commands snapshot session=\(sessionID) epoch=\(currentEpoch) commands=\(commands.count) latencyMs=\(Self.millisecondsSince(requestStartedAt))")
        commandsBySessionID[sessionID] = commands
        requestedSessionIDs.insert(sessionID)
    }

    func invalidate(sessionID: String, refreshIfPreviouslyRequested: Bool = false) {
        // If there is an in-flight request, its response is about to be discarded by the epoch
        // bump below. Without a re-fire the composer would stay stuck on "Loading commands…"
        // until the next onAppear (i.e. until the HUD is closed and reopened). Always refresh in
        // that case so the UI converges as soon as the daemon answers the new request.
        let hadInFlightRequest = requestedSessionIDs.contains(sessionID)
        let shouldRefresh = hadInFlightRequest
            || (refreshIfPreviouslyRequested && commandsBySessionID[sessionID] != nil)
        epochBySessionID[sessionID] = (epochBySessionID[sessionID] ?? 0) &+ 1
        commandsBySessionID[sessionID] = nil
        requestedSessionIDs.remove(sessionID)
        if shouldRefresh {
            ensureLoaded(sessionID: sessionID)
        }
    }

    func clear(sessionID: String) {
        commandsBySessionID.removeValue(forKey: sessionID)
        requestedSessionIDs.remove(sessionID)
        epochBySessionID.removeValue(forKey: sessionID)
        clearRequests(sessionID: sessionID)
    }

    func prune(knownSessionIDs: Set<String>) {
        commandsBySessionID = commandsBySessionID.filter { knownSessionIDs.contains($0.key) }
        epochBySessionID = epochBySessionID.filter { knownSessionIDs.contains($0.key) }
        requestedSessionIDs = requestedSessionIDs.filter { knownSessionIDs.contains($0) }
        requestSessionByID = requestSessionByID.filter { knownSessionIDs.contains($0.value) }
        requestEpochByID = requestEpochByID.filter { requestSessionByID[$0.key] != nil }
        requestStartedAtByID = requestStartedAtByID.filter { requestSessionByID[$0.key] != nil }
    }

    func hasLoaded(sessionID: String) -> Bool {
        commandsBySessionID[sessionID] != nil
    }

    func commands(for sessionID: String) -> [PickySlashCommand] {
        commandsBySessionID[sessionID] ?? []
    }

    private func request(sessionID: String) {
        requestedSessionIDs.insert(sessionID)
        let epoch = epochBySessionID[sessionID] ?? 0
        let command = PickyCommandEnvelope(type: .listSlashCommands, sessionId: sessionID)
        requestEpochByID[command.id] = epoch
        requestSessionByID[command.id] = sessionID
        requestStartedAtByID[command.id] = Date()
        pickySessionLog("slash commands requested session=\(sessionID) request=\(command.id) epoch=\(epoch)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sendCommand(command)
            } catch {
                let startedAt = requestStartedAtByID.removeValue(forKey: command.id)
                requestEpochByID.removeValue(forKey: command.id)
                requestSessionByID.removeValue(forKey: command.id)
                if !requestSessionByID.values.contains(sessionID) {
                    requestedSessionIDs.remove(sessionID)
                }
                pickySessionLog("slash commands request failed session=\(sessionID) request=\(command.id) latencyMs=\(Self.millisecondsSince(startedAt))")
                // Failure changes request bookkeeping only, so no published mirror sync is needed.
                onSendFailure(error.localizedDescription)
            }
        }
    }

    private func clearRequests(sessionID: String) {
        let requestIDs = requestSessionByID.filter { $0.value == sessionID }.map(\.key)
        for requestID in requestIDs {
            requestSessionByID.removeValue(forKey: requestID)
            requestEpochByID.removeValue(forKey: requestID)
            requestStartedAtByID.removeValue(forKey: requestID)
        }
    }

    private static func millisecondsSince(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return String(milliseconds(Date().timeIntervalSince(date)))
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }
}

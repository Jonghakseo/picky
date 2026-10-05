//
//  PickyRemoteHubRequestHandler.swift
//  Picky
//
//  Runs the app-owned actions the gateway asks for on behalf of a paired
//  phone. Everything else (session steer/follow-up, queue, runtime options)
//  goes straight from the gateway to the owning daemon and never reaches here.
//
//  Two rules this file exists to keep:
//    1. A remote request never changes what the Mac is showing — no card
//       selection, no panel, no cursor bubble, no spoken reply.
//    2. A remote request never opens a macOS permission prompt.
//

import Foundation

/// Error carrying a wire code the gateway can map to phone copy.
struct PickyRemoteHubError: LocalizedError, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }

    static func unavailable(_ message: String) -> PickyRemoteHubError {
        PickyRemoteHubError(code: PickyRemoteHubErrorCode.macUnavailable, message: message)
    }
}

@MainActor
protocol PickyRemoteSessionActions: AnyObject {
    /// Creates an empty Pickle in its own child daemon without selecting or
    /// opening the card on the Mac.
    func createRemotePickle(cwd: String) async throws -> String
    func markRemoteSessionRead(sessionID: String)
    func setRemoteSessionArchived(sessionID: String, archived: Bool) async throws
}

@MainActor
protocol PickyRemoteMainAgentActions: AnyObject {
    /// Submits to the always-on main agent with a remote-owned context: no
    /// screen capture, no cursor bubble, no TTS.
    func submitMainFromRemote(text: String) async throws
    func abortMainFromRemote() async throws
    func answerMainQuestionFromRemote(requestID: String, value: JSONValue) async throws
}

@MainActor
protocol PickyRemoteDictationTranscribing: AnyObject {
    /// Transcribes a recording with the Mac's configured speech service and
    /// deletes the file afterwards.
    func transcribe(filePath: String, mime: String) async throws -> String
}

@MainActor
final class PickyRemoteHubRequestHandler {
    private weak var sessions: (any PickyRemoteSessionActions)?
    private weak var mainAgent: (any PickyRemoteMainAgentActions)?
    private weak var dictation: (any PickyRemoteDictationTranscribing)?

    init(
        sessions: (any PickyRemoteSessionActions)?,
        mainAgent: (any PickyRemoteMainAgentActions)?,
        dictation: (any PickyRemoteDictationTranscribing)?
    ) {
        self.sessions = sessions
        self.mainAgent = mainAgent
        self.dictation = dictation
    }

    func handle(requestId: String, request: PickyRemoteHubRequest) async -> PickyRemoteHubResponse {
        do {
            return .ok(requestId: requestId, data: try await perform(request))
        } catch let error as PickyRemoteHubError {
            return .failure(requestId: requestId, code: error.code, message: error.message)
        } catch {
            return .failure(
                requestId: requestId,
                code: PickyRemoteHubErrorCode.failed,
                message: error.localizedDescription
            )
        }
    }

    private func perform(_ request: PickyRemoteHubRequest) async throws -> JSONValue? {
        switch request {
        case .pickleCreate(let cwd):
            let sessions = try requireSessions()
            let sessionID = try await sessions.createRemotePickle(cwd: cwd)
            return .object(["sessionId": .string(sessionID)])
        case .mainSend(let text):
            try await requireMainAgent().submitMainFromRemote(text: text)
            return nil
        case .mainAbort:
            try await requireMainAgent().abortMainFromRemote()
            return nil
        case .mainAnswer(let requestId, let value):
            try await requireMainAgent().answerMainQuestionFromRemote(requestID: requestId, value: value)
            return nil
        case .sessionMarkRead(let sessionId):
            try requireSessions().markRemoteSessionRead(sessionID: sessionId)
            return nil
        case .sessionArchive(let sessionId, let archived):
            try await requireSessions().setRemoteSessionArchived(sessionID: sessionId, archived: archived)
            return nil
        case .dictationTranscribe(let filePath, let mime):
            guard let dictation else {
                throw PickyRemoteHubError(
                    code: PickyRemoteHubErrorCode.macUnavailable,
                    message: L10n.t("settings.remote.error.dictationUnavailable")
                )
            }
            let text = try await dictation.transcribe(filePath: filePath, mime: mime)
            return .object(["text": .string(text)])
        }
    }

    private func requireSessions() throws -> any PickyRemoteSessionActions {
        guard let sessions else { throw PickyRemoteHubError.unavailable(L10n.t("settings.remote.error.appUnavailable")) }
        return sessions
    }

    private func requireMainAgent() throws -> any PickyRemoteMainAgentActions {
        guard let mainAgent else { throw PickyRemoteHubError.unavailable(L10n.t("settings.remote.error.appUnavailable")) }
        return mainAgent
    }
}

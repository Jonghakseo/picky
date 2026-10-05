//
//  PickyRemoteMainAgentAdapter.swift
//  Picky
//
//  Main-conversation actions a paired phone can trigger. It lives next to the
//  hub rather than inside `CompanionManager` so the companion keeps one owner
//  for desktop input and the remote path stays a thin, testable caller of the
//  entry points the HUD already uses.
//
//  The one rule every method here keeps: nothing a phone does may change what
//  the Mac shows. No capture, no cursor bubble, no speech, no panel.
//

import Foundation

@MainActor
final class PickyRemoteMainAgentAdapter: PickyRemoteMainAgentActions {
    /// The slice of the companion the remote actions need, as closures, so
    /// tests can drive the adapter without a live companion, agent client, or
    /// question panel.
    struct Host {
        var noteSubmission: (PickyContextPacket) -> Void
        var submit: (PickyAgentSubmission) async throws -> Void
        var cancelMainTurn: (PickyMainTurnCancellationSource) async -> Bool
        var answerQuestion: (String, JSONValue) async -> Error?
    }

    private let host: () -> Host?

    init(host: @escaping () -> Host?) {
        self.host = host
    }

    /// Binds to the live companion. Two deliberate choices here:
    /// `remoteContextCaptured` registers the context as remote-owned before
    /// the submission leaves the Mac (without it the eventual quickReply falls
    /// back to a metadata-derived owner and paints the desktop cursor), and the
    /// submit skips `submitToMainAgent` because that funnel also records the
    /// overlay context, resetting this Mac's annotation scene for a turn nobody
    /// here started.
    convenience init(companion: CompanionManager?) {
        self.init(host: { [weak companion] in
            guard let companion else { return nil }
            return Host(
                noteSubmission: { context in
                    companion.beginMainTurnGeneration()
                    companion.interactionCoordinator.accept(
                        .remoteContextCaptured(context: context),
                        correlation: PickyInteractionCorrelation(contextID: context.id, source: .system)
                    )
                },
                submit: { _ = try await companion.agentClient.submit($0) },
                cancelMainTurn: { await companion.cancelMainTurn(source: $0) },
                // The same closure the question panel's own answer button runs,
                // so the command bookkeeping and the pending-question clear stay
                // in one place.
                answerQuestion: { await companion.mainQuestionPanelManager.onAnswer($0, $1) }
            )
        })
    }

    func submitMainFromRemote(text: String) async throws {
        let host = try requireHost()
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.invalidRequest,
                message: L10n.t("settings.remote.error.emptyMessage")
            )
        }
        let context = Self.remoteContext(transcript: transcript)
        host.noteSubmission(context)
        try await host.submit(PickyAgentSubmission(transcript: transcript, context: context))
    }

    func abortMainFromRemote() async throws {
        let host = try requireHost()
        guard await host.cancelMainTurn(.remote) else {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.failed,
                message: L10n.t("settings.remote.error.abortFailed")
            )
        }
    }

    func answerMainQuestionFromRemote(requestID: String, value: JSONValue) async throws {
        let host = try requireHost()
        if let error = await host.answerQuestion(requestID, value) {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.failed,
                message: error.localizedDescription
            )
        }
    }

    /// A phone submission carries the typed text and nothing else. No
    /// screenshot, no window, no selection: the desktop is not the subject.
    /// `source` stays inside the daemon's accepted set; `remote=true` is the
    /// marker, mirroring how a manually created Pickle tags its own context.
    nonisolated static func remoteContext(transcript: String) -> PickyContextPacket {
        PickyContextPacket(
            id: "context-\(UUID().uuidString)",
            source: "text",
            capturedAt: Date(),
            transcript: transcript,
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: ["remote=true"]
        )
    }

    private func requireHost() throws -> Host {
        guard let host = host() else {
            throw PickyRemoteHubError.unavailable(L10n.t("settings.remote.error.appUnavailable"))
        }
        return host
    }
}

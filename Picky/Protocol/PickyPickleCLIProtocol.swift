//
//  PickyPickleCLIProtocol.swift
//  Picky
//
//  Codable app-daemon bridge models for Pickle CLI commands.
//

import Foundation

/// App-owned dock group snapshot exchanged with the CLI via agentd.
struct PickyDockGroupPayload: Codable, Equatable {
    let id: String
    let name: String
    let color: Int
    let memberSessionIds: [String]
    let collapsed: Bool
}

/// Identity a `picky` CLI invocation claims, issued per runtime session by the
/// owning daemon. The app never interprets it: it only forwards the context to
/// the owner connection, which revalidates it against its live bindings.
/// This is misidentification protection, not authentication.
struct PickyCliCallerContext: Codable, Equatable {
    /// The always-on main agent is not a Pickle and has no session record, so
    /// the daemon reports it under this fixed id.
    static let mainAgentSessionID = "picky"

    let bindingId: String
    let sessionId: String
    let piSessionId: String
    let generation: Int
}

/// The owning daemon's reply to a rename command: the session as it was
/// durably committed, correlated by the originating command id.
///
/// `revision` is read out of the same payload separately because
/// `PickyAgentSession` deliberately does not model the projection revision:
/// the app tracks that per session store, not per decoded summary.
struct PickyPickleSessionUpdatedPayload: Decodable, Equatable {
    let commandId: String
    let session: PickyAgentSession
    let revision: Int?

    private enum CodingKeys: String, CodingKey { case commandId, session }
    private struct RevisionProbe: Decodable { let revision: Int? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try container.decode(String.self, forKey: .commandId)
        session = try container.decode(PickyAgentSession.self, forKey: .session)
        revision = try container.decode(RevisionProbe.self, forKey: .session).revision
    }
}

enum PickyPickleBridgeOperation: String, Decodable, Equatable {
    case listSessions
    /// `picky whoami`: resolve the calling runtime session to a Pickle the app
    /// already projects. Read-only; it must never spawn or resume a runtime.
    case resolveCaller
    /// `picky pickle-rename`: persist a user-chosen display name through the
    /// session's owning daemon.
    case rename
    case steer
    case followUp
    case abort
    case setArchived
    /// `picky pickle-notify`: change a Pickle's completion channels through
    /// the same owner-routed commands the HUD toggles use.
    case setNotifications
    case delete
    case manageGroups
    case notifyMainOfPickleCompletion
}

enum PickyPickleCLIAction: String, Codable, Equatable {
    case steer
    case followUp
    case abort
}

enum PickyDockGroupManagementAction: String, Codable, Equatable {
    case list
    case create
    case addMembers
    case removeMembers
    case removeGroup
    case archiveGroup
}

struct PickyDockGroupManagementRequest: Equatable {
    let action: PickyDockGroupManagementAction
    let groupId: String?
    let name: String?
    let sessionIds: [String]
    var archiveMode: PickyAsyncTaskCommand.ArchiveMode? = nil
}

struct PickyPickleBridgeRequest: Decodable, Equatable {
    let requestId: String
    let operation: PickyPickleBridgeOperation
    /// Present for `resolveCaller` and for a `--self` rename. The app forwards
    /// it unchanged to the owning daemon instead of trusting it locally.
    let callerContext: PickyCliCallerContext?
    let sessionId: String?
    let text: String?
    let prompt: String?
    let cwd: String?
    /// Optional for old child daemons. New durable completion producers send
    /// all fields so the app can route without consulting session projection.
    let completionId: String?
    let title: String?
    let status: PickySessionStatus?
    let summary: String?
    let notifyMainOnCompletion: Bool?
    let notifyMacOSOnCompletion: Bool?
    let groupAction: PickyDockGroupManagementAction?
    let groupId: String?
    let name: String?
    let sessionIds: [String]?
    let archived: Bool?
    var archiveMode: PickyAsyncTaskCommand.ArchiveMode? = nil

    /// Builds one app-owned envelope for both durable and legacy bridges.
    /// A legacy bridge receipt is itself proof that its child had completion
    /// delivery enabled. Its projection can be absent or stale while the
    /// child is terminating, so use it only for presentation fallback.
    func completionEnvelope(projectedSession: PickyAgentSession?) -> PickyCompletionNotificationEnvelope? {
        guard operation == .notifyMainOfPickleCompletion,
              let sessionId,
              let prompt else { return nil }
        return PickyCompletionNotificationEnvelope(
            completionId: completionId ?? "legacy:\(requestId)",
            sessionID: sessionId,
            title: title ?? projectedSession?.title ?? sessionId,
            status: status ?? .completed,
            summary: summary ?? projectedSession?.lastSummary,
            prompt: prompt,
            cwd: cwd,
            notifyMainOnCompletion: notifyMainOnCompletion ?? true,
            notifyMacOSOnCompletion: notifyMacOSOnCompletion ?? false
        )
    }
}

struct PickyCompletionNotificationEnvelope: Equatable {
    let completionId: String
    let sessionID: String
    let title: String
    let status: PickySessionStatus
    let summary: String?
    let prompt: String?
    let cwd: String?
    let notifyMainOnCompletion: Bool
    let notifyMacOSOnCompletion: Bool
}

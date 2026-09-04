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

enum PickyPickleBridgeOperation: String, Decodable, Equatable {
    case listSessions
    case steer
    case followUp
    case abort
    case setArchived
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
}

struct PickyPickleBridgeRequest: Decodable, Equatable {
    let requestId: String
    let operation: PickyPickleBridgeOperation
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
    let groupAction: PickyDockGroupManagementAction?
    let groupId: String?
    let name: String?
    let sessionIds: [String]?
    let archived: Bool?

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
            bellEnabled: true
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
    let bellEnabled: Bool
}

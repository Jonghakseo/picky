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
    let groupAction: PickyDockGroupManagementAction?
    let groupId: String?
    let name: String?
    let sessionIds: [String]?
    let archived: Bool?
}

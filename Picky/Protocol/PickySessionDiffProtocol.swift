//
//  PickySessionDiffProtocol.swift
//  Picky
//
//  Wire models for `getSessionDiff`: the request command and the diff result event.
//

import Foundation

enum PickySessionDiffView: String, Codable, Equatable {
    case unstaged
    case staged
}

/// Type-specific command payload for a diff request. Unlike the generic envelope's
/// optional correlation field, this payload cannot be created or decoded without one.
struct PickySessionDiffCommand: Codable, Equatable {
    let id: String
    let protocolVersion: String
    let type: PickyCommandType
    let sessionId: String
    let requestId: String
    let view: PickySessionDiffView

    init(
        id: String = "cmd-\(UUID().uuidString)",
        sessionId: String,
        requestId: String,
        view: PickySessionDiffView
    ) {
        self.id = id
        protocolVersion = pickyAgentProtocolVersion
        type = .getSessionDiff
        self.sessionId = sessionId
        self.requestId = requestId
        self.view = view
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        type = try container.decode(PickyCommandType.self, forKey: .type)
        guard type == .getSessionDiff else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected getSessionDiff command")
        }
        sessionId = try container.decode(String.self, forKey: .sessionId)
        requestId = try container.decode(String.self, forKey: .requestId)
        view = try container.decode(PickySessionDiffView.self, forKey: .view)
    }
}

extension PickyCommandEnvelope {
    init(_ command: PickySessionDiffCommand) {
        self.init(
            id: command.id,
            type: command.type,
            sessionId: command.sessionId,
            requestId: command.requestId,
            view: command.view
        )
    }
}

struct PickySessionDiffFile: Decodable, Equatable, Identifiable {
    enum Status: String, Decodable, Equatable {
        case added, modified, deleted, renamed, untracked
    }

    var id: String { path }
    let path: String
    let status: Status
    let renamedFrom: String?
    let additions: Int
    let deletions: Int
    let diff: String
    let truncated: Bool
}

struct PickySessionDiffResult: Decodable, Equatable {
    let sessionId: String
    let view: PickySessionDiffView
    let isGitRepo: Bool
    let files: [PickySessionDiffFile]
    let filesTruncated: Bool
    let errorMessage: String?
    let requestID: String

    private enum CodingKeys: String, CodingKey {
        case sessionId, view, isGitRepo, files, filesTruncated, errorMessage, requestID = "requestId"
    }
}

//
//  PickyAgentMcpProtocol.swift
//  Picky
//
//  MCP server management payloads shared by the app and picky-agentd protocol.
//  Servers live in Pi's global `mcp.json`; agentd reads and edits it.
//

import Foundation

/// Which agents connect to an MCP server. Stored as `pickyScope` in the server's `mcp.json` entry.
enum PickyMcpScope: String, Codable, Equatable, CaseIterable, Identifiable {
    /// The main Picky agent and every Pickle.
    case all
    /// The main Picky agent only.
    case main

    var id: String { rawValue }
}

struct PickyMcpServer: Decodable, Equatable, Identifiable {
    /// Connection state as Pi reports it. Unknown future states decode as `failed`.
    enum State: String, Decodable, Equatable {
        case disabled
        case connecting
        case connected
        case disconnected
        case needsAuth = "needs-auth"
        case failed
        case closed

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .failed
        }
    }

    let name: String
    var pickyScope: PickyMcpScope
    let enabled: Bool
    let exposure: String
    /// The command line of a stdio server or the URL of an HTTP server.
    let transport: String
    let state: State
    let tools: [String]
    let error: String?
    let usesOAuth: Bool

    var id: String { name }
}

struct PickyMcpServerListEvent: Decodable, Equatable {
    let commandId: String
    let ok: Bool
    let configPath: String?
    let servers: [PickyMcpServer]
    let configErrors: [String]
    let errorMessage: String?
}

enum PickyMcpServerOperation: String, Decodable, Equatable {
    case add
    case update
    case remove
    case signIn
    case signOut
}

enum PickyMcpServerErrorCode: String, Decodable, Equatable {
    case duplicate
    case invalid
    case notFound
}

struct PickyMcpServerOperationCompletedEvent: Decodable, Equatable {
    let requestId: String
    let operation: PickyMcpServerOperation
    let name: String
    let ok: Bool
    /// Raw string so a newer daemon's unknown code decodes as a generic failure.
    let errorCode: String?
    let errorMessage: String?

    var code: PickyMcpServerErrorCode? { errorCode.flatMap(PickyMcpServerErrorCode.init(rawValue:)) }
}

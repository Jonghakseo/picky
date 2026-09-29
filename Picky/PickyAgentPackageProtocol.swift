//
//  PickyAgentPackageProtocol.swift
//  Picky
//
//  Package-management payloads shared by the app and picky-agentd protocol.
//

import Foundation

enum PickyPackageOperation: String, Decodable, Equatable {
    case install
    case remove
    case update
    case setup
}

struct PickyPackageUpdatesAvailableEvent: Decodable, Equatable {
    let commandId: String
    let sources: [String]
    /// `true` means agentd could not query the registry; callers may retry silently.
    let failed: Bool?
}

/// Another installed tool or skill with the same name as one a curated package provides.
struct PickyPackageConflict: Decodable, Equatable, Hashable {
    enum Kind: String, Decodable, Equatable, Hashable {
        case tool
        case skill
    }

    let source: String
    let kind: Kind
    let name: String
    /// Absolute path of the resource that already provides `name`.
    let ownerPath: String
}

struct PickyPackageConflictsEvent: Decodable, Equatable {
    let commandId: String
    let conflicts: [PickyPackageConflict]
    /// `true` means agentd could not inspect Pi resources; callers keep the previous state.
    let failed: Bool?
}

struct PickyPackageOperationProgressEvent: Decodable, Equatable {
    let requestId: String
    let operation: PickyPackageOperation
    let source: String
    let message: String
}

struct PickyPackageOperationCompletedEvent: Decodable, Equatable {
    let requestId: String
    let operation: PickyPackageOperation
    let source: String
    let ok: Bool
    let errorMessage: String?
    let packageChanged: Bool?

    init(
        requestId: String,
        operation: PickyPackageOperation,
        source: String,
        ok: Bool,
        errorMessage: String?,
        packageChanged: Bool? = nil
    ) {
        self.requestId = requestId
        self.operation = operation
        self.source = source
        self.ok = ok
        self.errorMessage = errorMessage
        self.packageChanged = packageChanged
    }
}

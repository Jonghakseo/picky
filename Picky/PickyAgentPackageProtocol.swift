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
    /// Registry version each source would update to. Older daemons omit it, and
    /// agentd leaves out sources whose version it could not resolve.
    let latestVersions: [String: String]?
    /// `true` means agentd could not query the registry; callers may retry silently.
    let failed: Bool?

    init(commandId: String, sources: [String], latestVersions: [String: String]? = nil, failed: Bool? = nil) {
        self.commandId = commandId
        self.sources = sources
        self.latestVersions = latestVersions
        self.failed = failed
    }
}

/// Curated package sources with an available update and, when known, the target version.
struct PickyAvailablePackageUpdates: Equatable, Sendable {
    var sources: Set<String>
    var latestVersions: [String: String] = [:]
}

/// Another installed tool or skill with the same name as one a curated package provides.
struct PickyPackageConflict: Decodable, Equatable, Hashable {
    enum Kind: String, Decodable, Equatable, Hashable {
        case tool
        case skill
    }

    /// How the other copy can be removed, decided by agentd from Pi's resource metadata.
    enum Removal: Decodable, Equatable, Hashable {
        /// Another user-scope Pi package; remove it with the package manager.
        case package(source: String)
        /// An auto-discovered local folder or file directly under a Pi resource root.
        case trash(path: String)
        /// Anything else; the user removes it.
        case manual

        private enum CodingKeys: String, CodingKey { case kind, source, path }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "package": self = .package(source: try container.decode(String.self, forKey: .source))
            case "trash": self = .trash(path: try container.decode(String.self, forKey: .path))
            default: self = .manual
            }
        }
    }

    let source: String
    let kind: Kind
    let name: String
    /// Absolute path of the resource that already provides `name`.
    let ownerPath: String
    /// Older daemons omit this; treat it as manual removal.
    let removal: Removal?

    init(source: String, kind: Kind, name: String, ownerPath: String, removal: Removal? = nil) {
        self.source = source
        self.kind = kind
        self.name = name
        self.ownerPath = ownerPath
        self.removal = removal
    }

    var isRemovable: Bool {
        switch removal {
        case .package, .trash: true
        case .manual, nil: false
        }
    }
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

/// Failure kinds agentd classifies; anything else is a generic failure.
enum PickyPackageErrorCode: String, Equatable {
    case duplicate
    case held
    case timeout
}

struct PickyPackageOperationCompletedEvent: Decodable, Equatable {
    let requestId: String
    let operation: PickyPackageOperation
    let source: String
    let ok: Bool
    let errorMessage: String?
    /// Raw string so a newer daemon's unknown code decodes as a generic failure.
    let errorCode: String?
    let packageChanged: Bool?

    var code: PickyPackageErrorCode? { errorCode.flatMap(PickyPackageErrorCode.init(rawValue:)) }

    init(
        requestId: String,
        operation: PickyPackageOperation,
        source: String,
        ok: Bool,
        errorMessage: String?,
        errorCode: String? = nil,
        packageChanged: Bool? = nil
    ) {
        self.requestId = requestId
        self.operation = operation
        self.source = source
        self.ok = ok
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.packageChanged = packageChanged
    }
}

//
//  PickySessionRuntimeOptions.swift
//  Picky
//
//  Value types for the main-agent and per-session runtime model/thinking selectors.
//

struct PickyMainAgentModelOption: Codable, Equatable, Identifiable {
    var id: String { pattern }
    let provider: String
    let modelId: String
    let displayName: String
    let pattern: String
    /// Whether provider fast mode applies to this model. Absent from older daemons.
    var fastModeSupported: Bool? = nil
}

struct PickySessionRuntimeModelOption: Codable, Equatable, Identifiable {
    var id: String { "\(provider)/\(modelId)" }
    let provider: String
    let modelId: String
    let displayName: String
    let pattern: String
    var fastModeSupported: Bool? = nil
}

struct PickySessionRuntimeModelIdentity: Codable, Equatable {
    let provider: String
    let modelId: String
}

enum PickyRuntimeModelScopeMode: String, Codable, Equatable {
    case all
    case exact
}

enum PickyRuntimeModelScopeReason: String, Codable, Equatable {
    case advancedPatterns

    var localizedDescription: String {
        switch self {
        case .advancedPatterns:
            L10n.t("hud.composer.runtime.picker.advancedReadOnly")
        }
    }
}

struct PickyRuntimeModelScope: Codable, Equatable {
    let mode: PickyRuntimeModelScopeMode
    let patterns: [String]
    let editable: Bool
    let revision: String?
    /// Canonical provider/modelId values resolved from the global raw patterns.
    /// Optional for older daemons.
    let resolvedModelIds: [String]?
    let reason: PickyRuntimeModelScopeReason?
}

//
//  PickySessionRuntimeOptions.swift
//  Picky
//
//  Value types for the per-session runtime model/thinking selectors.
//

struct PickySessionRuntimeModelOption: Codable, Equatable, Identifiable {
    var id: String { "\(provider)/\(modelId)" }
    let provider: String
    let modelId: String
    let displayName: String
    let pattern: String
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

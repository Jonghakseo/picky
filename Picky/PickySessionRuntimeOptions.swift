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

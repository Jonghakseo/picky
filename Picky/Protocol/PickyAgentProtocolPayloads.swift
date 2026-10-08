//
//  PickyAgentProtocolPayloads.swift
//  Picky
//
//  Decoder-only shims for daemon events whose JSON wraps the value the app
//  actually models. They have no behavior and no callers outside
//  `PickyEvent`'s decoding, so they live here instead of growing the protocol
//  model file.
//

import Foundation

struct PickyMainMessagesSnapshotPayload: Decodable { let messages: [PickyMainAgentMessage] }
struct PickyMainMessageAppendedPayload: Decodable { let message: PickyMainAgentMessage }
struct PickyMainActivityUpdatedPayload: Decodable { let activity: PickyMainActivity? }
struct PickyMainExtensionUiRequestedPayload: Decodable { let request: PickyExtensionUiRequest }
struct PickyMainExtensionUiCancelledPayload: Decodable { let requestId: String }
struct PickyMainAgentSessionInfoUpdatedPayload: Decodable { let sessionFilePath: String?; let cwd: String? }
struct PickyMainAgentModelsSnapshotPayload: Decodable { let models: [PickyMainAgentModelOption] }
struct PickySessionRuntimeOptionsSnapshotPayload: Decodable {
    let sessionId: String
    let requestId: String
    let models: [PickySessionRuntimeModelOption]
    let allModels: [PickySessionRuntimeModelOption]?
    let globalScope: PickyRuntimeModelScope?
    let projectScope: PickyRuntimeModelScope?
    let effectiveScope: PickyRuntimeModelScope?
    let thinkingLevels: [PickyMainAgentThinkingLevel]
    let currentModel: PickySessionRuntimeModelIdentity?
}
struct PickyMainTurnSettledPayload: Decodable { let contextId: String }
struct PickySessionResourcesReloadedPayload: Decodable { let sessionId: String }
struct PickyExtensionUiRequestPayload: Decodable { let request: PickyExtensionUiRequest }
struct PickyPointerOverlayRequestedPayload: Decodable { let request: PickyPointerOverlayRequest }
struct PickyAnnotationOverlayRequestedPayload: Decodable { let request: PickyAnnotationOverlayRequest }
struct PickySlashCommandsSnapshotPayload: Decodable { let sessionId: String; let requestId: String?; let commands: [PickySlashCommand] }
struct PickyRewindTargetsSnapshotPayload: Decodable { let sessionId: String; let requestId: String?; let targets: [PickyRewindTarget] }
struct PickySessionRewoundPayload: Decodable { let sessionId: String; let editorText: String?; let removedIds: [String] }
struct PickyDockGroupsRequestedPayload: Decodable { let requestId: String }

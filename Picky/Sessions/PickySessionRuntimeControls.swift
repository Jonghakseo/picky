//
//  PickySessionRuntimeControls.swift
//  Picky
//
//  Per-session runtime model and thinking-level controls. Every mutation goes through
//  one acknowledged-command path so a daemon rejection surfaces as `lastError`.
//

import Foundation

enum PickyRuntimeModelScopeCommandError: LocalizedError {
    case conflict

    var errorDescription: String? {
        switch self {
        case .conflict: L10n.t("hud.composer.runtime.picker.conflict")
        }
    }
}

extension PickySessionListViewModel {
    func listSessionRuntimeOptions(sessionID: String) async throws -> PickySessionRuntimeOptions {
        try await client.listSessionRuntimeOptions(sessionId: sessionID)
    }

    func setGlobalModelScope(mode: PickyRuntimeModelScopeMode, patterns: [String]?, expectedRevision: String) async throws {
        try await sendRuntimeControlCommand(PickyCommandEnvelope(
            type: .setGlobalModelScope,
            mode: mode,
            patterns: patterns,
            expectedRevision: expectedRevision
        ))
    }

    func pickleRuntimeDefaults() -> (modelPattern: String, thinkingLevel: PickyPickleAgentThinkingLevel) {
        let settings = pickleRuntimeDefaultsStore.load()
        return (settings.pickleAgentModelPattern, settings.pickleAgentThinkingLevel)
    }

    func setPickleRuntimeDefaults(modelPattern: String?, thinkingLevel: PickyPickleAgentThinkingLevel?) async throws {
        _ = try await pickleRuntimeDefaultsPersistence.persist(notification: .settingsDidSave) { settings in
            if let modelPattern {
                settings.pickleAgentModelPattern = modelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let thinkingLevel {
                settings.pickleAgentThinkingLevel = thinkingLevel
            }
        }
    }

    func setSessionModel(sessionID: String, provider: String, modelID: String) async throws {
        try await sendRuntimeControlCommand(PickyCommandEnvelope(
            type: .setSessionModel,
            sessionId: sessionID,
            provider: provider,
            modelId: modelID
        ))
    }

    func setSessionThinkingLevel(sessionID: String, thinkingLevel: PickyMainAgentThinkingLevel) async throws {
        try await sendRuntimeControlCommand(PickyCommandEnvelope(
            type: .setSessionThinkingLevel,
            sessionId: sessionID,
            thinkingLevel: thinkingLevel
        ))
    }

    func cycleThinkingLevel(sessionID: String) async throws {
        pickySessionLog("cycle thinking level session=\(sessionID)")
        try await sendRuntimeControlCommand(PickyCommandEnvelope(type: .cycleSessionThinkingLevel, sessionId: sessionID))
    }

    func cycleModel(sessionID: String, direction: PickyModelCycleDirection = .forward) async throws {
        pickySessionLog("cycle model session=\(sessionID) direction=\(direction.rawValue)")
        try await sendRuntimeControlCommand(PickyCommandEnvelope(
            type: .cycleSessionModel,
            sessionId: sessionID,
            direction: direction
        ))
    }

    private func sendRuntimeControlCommand(_ command: PickyCommandEnvelope) async throws {
        do {
            if let error = try await client.sendAwaitingError(command, timeout: 5.0, requireAcknowledgement: true) {
                if command.type == .setGlobalModelScope, error.code == "picky_model_scope_conflict" {
                    throw PickyRuntimeModelScopeCommandError.conflict
                }
                throw PickyRewindTargetRequestError.daemonError(error.message)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

//
//  PickyComposerRuntimeControlsModel.swift
//  Picky
//
//  Owns the composer's runtime model/thinking selector state and its async mutations.
//  Every in-flight result is gated on a session + request generation token, so switching
//  Pickles or firing a second mutation never lets a stale response write back.
//

import Combine
import Foundation

@MainActor
final class PickyComposerRuntimeControlsModel: ObservableObject {
    @Published var actionError: String?
    @Published var runtimeOptions: PickySessionRuntimeOptions?
    @Published var loadState: PickyComposerRuntimeOptionsLoadState = .idle
    @Published var isModelPickerPresented = false
    @Published var isModelActionInFlight = false
    @Published var isThinkingActionInFlight = false

    private var sessionGeneration = 0
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?

    func cancelLoad() {
        loadTask?.cancel()
    }

    func reset() {
        sessionGeneration += 1
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        runtimeOptions = nil
        loadState = .idle
        actionError = nil
        isModelPickerPresented = false
        isModelActionInFlight = false
        isThinkingActionInFlight = false
    }

    func openModelPicker(commands: PickySessionCommands, sessionID: String) {
        isModelPickerPresented = true
        loadOptions(commands: commands, sessionID: sessionID)
    }

    func loadOptions(commands: PickySessionCommands, sessionID: String) {
        loadGeneration += 1
        let token = ControlToken(sessionID: sessionID, sessionGeneration: sessionGeneration, requestGeneration: loadGeneration)
        loadTask?.cancel()
        runtimeOptions = nil
        loadState = .loading
        actionError = nil
        loadTask = Task { [weak self] in
            do {
                let options = try await commands.listSessionRuntimeOptions(sessionID: sessionID)
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                self.runtimeOptions = options
                self.loadState = options.models.isEmpty ? .empty : .loaded
            } catch {
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    func selectModel(_ model: PickySessionRuntimeModelOption, commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        isModelActionInFlight = true
        runMutation(token: token, commands: commands, dismissPickerOnSuccess: true) {
            try await commands.setSessionModel(sessionID: sessionID, provider: model.provider, modelID: model.modelId)
        } finish: { [weak self] in
            self?.isModelActionInFlight = false
        }
    }

    func selectThinkingLevel(_ thinkingLevel: PickyMainAgentThinkingLevel, commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        isThinkingActionInFlight = true
        runMutation(token: token, commands: commands, dismissPickerOnSuccess: false) {
            try await commands.setSessionThinkingLevel(sessionID: sessionID, thinkingLevel: thinkingLevel)
        } finish: { [weak self] in
            self?.isThinkingActionInFlight = false
        }
    }

    func cycleModel(direction: PickyModelCycleDirection, commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        runMutation(token: token, commands: commands, dismissPickerOnSuccess: false) {
            try await commands.cycleModel(sessionID: sessionID, direction: direction)
        } finish: { }
    }

    func cycleThinkingLevel(commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        Task { [weak self] in
            do {
                try await commands.cycleThinkingLevel(sessionID: sessionID)
                guard let self, self.isCurrent(token) else { return }
                self.actionError = nil
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.actionError = error.localizedDescription
            }
        }
    }

    private func runMutation(
        token: SessionToken,
        commands: PickySessionCommands,
        dismissPickerOnSuccess: Bool,
        _ mutate: @escaping () async throws -> Void,
        finish: @escaping () -> Void
    ) {
        Task { [weak self] in
            defer { if let self, self.isCurrent(token) { finish() } }
            do {
                try await mutate()
                guard let self, self.isCurrent(token) else { return }
                if dismissPickerOnSuccess { self.isModelPickerPresented = false }
                self.actionError = nil
                self.loadOptions(commands: commands, sessionID: token.sessionID)
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.actionError = error.localizedDescription
            }
        }
    }

    private func isCurrent(_ token: ControlToken) -> Bool {
        isCurrent(SessionToken(sessionID: token.sessionID, generation: token.sessionGeneration))
            && loadGeneration == token.requestGeneration
    }

    private func isCurrent(_ token: SessionToken) -> Bool {
        sessionGeneration == token.generation
    }

    private struct ControlToken: Equatable {
        let sessionID: String
        let sessionGeneration: Int
        let requestGeneration: Int
    }

    private struct SessionToken: Equatable {
        let sessionID: String
        let generation: Int
    }
}

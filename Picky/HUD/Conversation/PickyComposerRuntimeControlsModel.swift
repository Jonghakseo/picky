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

struct PickyComposerRuntimeScopeStaging: Equatable {
    var mode: PickyRuntimeModelScopeMode
    /// Raw Pi patterns retain their persisted spelling and cycle order until their
    /// membership changes. Comparison remains canonical and case-insensitive.
    var patterns: [String]

    init(scope: PickyRuntimeModelScope? = nil) {
        mode = scope?.mode ?? .all
        patterns = Self.canonicalizedRawPatterns(scope?.patterns ?? [])
    }

    func containsPattern(_ pattern: String) -> Bool {
        patterns.contains { Self.canonicalPattern($0) == Self.canonicalPattern(pattern) }
    }

    mutating func setAllModelsEnabled(_ enabled: Bool, firstAvailablePattern: String?) {
        mode = enabled ? .all : .exact
        if !enabled, patterns.isEmpty, let firstAvailablePattern {
            patterns.append(firstAvailablePattern)
        }
    }

    mutating func setPattern(_ pattern: String, selected: Bool) {
        let canonical = Self.canonicalPattern(pattern)
        if selected {
            guard !patterns.contains(where: { Self.canonicalPattern($0) == canonical }) else { return }
            patterns.append(pattern)
        } else {
            patterns.removeAll { Self.canonicalPattern($0) == canonical }
        }
    }

    private static func canonicalizedRawPatterns(_ rawPatterns: [String]) -> [String] {
        var canonical = Set<String>()
        var preserved: [String] = []
        for pattern in rawPatterns {
            let key = canonicalPattern(pattern)
            guard !key.isEmpty, canonical.insert(key).inserted else { continue }
            preserved.append(pattern)
        }
        return preserved
    }

    private static func canonicalPattern(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct PickyComposerRuntimeScopeApplySuccess: Equatable {
    let sessionID: String
    let generation: Int
}

enum PickyComposerRuntimePickerScreenPolicy {
    static func shouldReturnToQuick(
        after success: PickyComposerRuntimeScopeApplySuccess?,
        sessionID: String,
        lastHandledGeneration: Int
    ) -> Bool {
        guard let success else { return false }
        return success.sessionID == sessionID && success.generation > lastHandledGeneration
    }
}

enum PickyComposerRuntimePickerRowNavigation {
    static func first(in rowIDs: [String]) -> String? { rowIDs.first }

    static func next(after currentID: String?, in rowIDs: [String]) -> String? {
        guard !rowIDs.isEmpty else { return nil }
        guard let currentID, let index = rowIDs.firstIndex(of: currentID) else { return rowIDs.first }
        return rowIDs[min(index + 1, rowIDs.count - 1)]
    }

    static func previous(before currentID: String?, in rowIDs: [String]) -> String? {
        guard !rowIDs.isEmpty else { return nil }
        guard let currentID, let index = rowIDs.firstIndex(of: currentID) else { return rowIDs.first }
        return rowIDs[max(index - 1, 0)]
    }

    static func focusAfterFiltering(currentID: String?, rowIDs: [String]) -> String? {
        guard let currentID else { return nil }
        return rowIDs.contains(currentID) ? currentID : first(in: rowIDs)
    }
}

@MainActor
final class PickyComposerRuntimeControlsModel: ObservableObject {
    @Published var actionError: String?
    @Published var runtimeOptions: PickySessionRuntimeOptions?
    @Published var loadState: PickyComposerRuntimeOptionsLoadState = .idle
    @Published var isModelPickerPresented = false
    @Published var isModelActionInFlight = false
    @Published var isThinkingActionInFlight = false
    @Published var isGlobalScopeActionInFlight = false
    @Published private(set) var pickleRuntimeDefaults: (modelPattern: String, thinkingLevel: PickyPickleAgentThinkingLevel) = ("", .automatic)
    @Published private(set) var scopeStaging = PickyComposerRuntimeScopeStaging()
    /// Emitted only after Apply's own authoritative reload has completed.
    @Published private(set) var globalScopeApplySuccess: PickyComposerRuntimeScopeApplySuccess?

    private var sessionGeneration = 0
    private var loadGeneration = 0
    private var globalScopeApplyGeneration = 0
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
        isGlobalScopeActionInFlight = false
        pickleRuntimeDefaults = ("", .automatic)
        scopeStaging = PickyComposerRuntimeScopeStaging()
        globalScopeApplySuccess = nil
    }

    func openModelPicker(commands: PickySessionCommands, sessionID: String) {
        pickleRuntimeDefaults = commands.pickleRuntimeDefaults()
        isModelPickerPresented = true
        loadOptions(commands: commands, sessionID: sessionID)
    }

    func loadOptions(
        commands: PickySessionCommands,
        sessionID: String,
        replaceScopeStagingOnSuccess: Bool = false,
        globalScopeApplySuccess: PickyComposerRuntimeScopeApplySuccess? = nil
    ) {
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
                if replaceScopeStagingOnSuccess {
                    self.replaceScopeStaging(with: options)
                }
                self.loadState = options.models.isEmpty ? .empty : .loaded
                if let globalScopeApplySuccess {
                    self.globalScopeApplySuccess = globalScopeApplySuccess
                }
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

    func setNewPickleDefaultModel(_ model: PickySessionRuntimeModelOption, commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        isModelActionInFlight = true
        Task { [weak self] in
            defer { if let self, self.isCurrent(token) { self.isModelActionInFlight = false } }
            do {
                try await commands.setPickleRuntimeDefaults(modelPattern: model.pattern, thinkingLevel: nil)
                guard let self, self.isCurrent(token) else { return }
                self.pickleRuntimeDefaults = commands.pickleRuntimeDefaults()
                self.actionError = nil
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.actionError = error.localizedDescription
            }
        }
    }

    func setNewPickleDefaultThinking(_ thinkingLevel: PickyMainAgentThinkingLevel, commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        isThinkingActionInFlight = true
        Task { [weak self] in
            defer { if let self, self.isCurrent(token) { self.isThinkingActionInFlight = false } }
            do {
                try await commands.setPickleRuntimeDefaults(modelPattern: nil, thinkingLevel: PickyPickleAgentThinkingLevel(rawValue: thinkingLevel.rawValue))
                guard let self, self.isCurrent(token) else { return }
                self.pickleRuntimeDefaults = commands.pickleRuntimeDefaults()
                self.actionError = nil
            } catch {
                guard let self, self.isCurrent(token) else { return }
                self.actionError = error.localizedDescription
            }
        }
    }

    func beginGlobalScopeEditing() {
        scopeStaging = PickyComposerRuntimeScopeStaging(scope: runtimeOptions?.globalScope)
    }

    func replaceScopeStaging(with options: PickySessionRuntimeOptions) {
        scopeStaging = PickyComposerRuntimeScopeStaging(scope: options.globalScope)
    }

    func setAllModelsEnabled(_ enabled: Bool, firstAvailablePattern: String?) {
        scopeStaging.setAllModelsEnabled(enabled, firstAvailablePattern: firstAvailablePattern)
    }

    func setStagedScopePattern(_ pattern: String, selected: Bool) {
        scopeStaging.setPattern(pattern, selected: selected)
    }

    /// Explicit Reload intentionally replaces conflict-era staging only after the
    /// authoritative scope and revision arrive. Normal refreshes preserve it.
    func reloadGlobalScope(commands: PickySessionCommands, sessionID: String) {
        loadOptions(commands: commands, sessionID: sessionID, replaceScopeStagingOnSuccess: true)
    }

    func applyStagedGlobalScope(commands: PickySessionCommands, sessionID: String) {
        guard let revision = runtimeOptions?.globalScope?.revision, !revision.isEmpty else {
            actionError = L10n.t("hud.composer.runtime.picker.unavailableScope")
            return
        }
        applyGlobalScope(
            mode: scopeStaging.mode,
            patterns: scopeStaging.mode == .exact ? scopeStaging.patterns : nil,
            expectedRevision: revision,
            commands: commands,
            sessionID: sessionID
        )
    }

    private func applyGlobalScope(mode: PickyRuntimeModelScopeMode, patterns: [String]?, expectedRevision: String, commands: PickySessionCommands, sessionID: String) {
        let token = SessionToken(sessionID: sessionID, generation: sessionGeneration)
        globalScopeApplyGeneration += 1
        let applyGeneration = globalScopeApplyGeneration
        isGlobalScopeActionInFlight = true
        Task { [weak self] in
            defer { if let self, self.isCurrent(token) { self.isGlobalScopeActionInFlight = false } }
            do {
                try await commands.setGlobalModelScope(mode: mode, patterns: patterns, expectedRevision: expectedRevision)
                guard let self, self.isCurrent(token), self.globalScopeApplyGeneration == applyGeneration else { return }
                self.actionError = nil
                self.loadOptions(
                    commands: commands,
                    sessionID: sessionID,
                    replaceScopeStagingOnSuccess: true,
                    globalScopeApplySuccess: PickyComposerRuntimeScopeApplySuccess(sessionID: sessionID, generation: applyGeneration)
                )
            } catch {
                guard let self, self.isCurrent(token), self.globalScopeApplyGeneration == applyGeneration else { return }
                self.actionError = Self.localizedScopeActionError(error)
            }
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

    private static func localizedScopeActionError(_ error: Error) -> String {
        if case PickyRuntimeModelScopeCommandError.conflict = error {
            return L10n.t("hud.composer.runtime.picker.conflict")
        }
        return error.localizedDescription
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

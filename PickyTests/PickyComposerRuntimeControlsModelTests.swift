import Testing
@testable import Picky

@MainActor
struct PickyComposerRuntimeControlsModelTests {
    @Test func authoritativeScopeReloadReplacesConflictEraStaging() {
        let model = PickyComposerRuntimeControlsModel()
        let conflictedOptions = runtimeOptions(scope: .init(
            mode: .exact,
            patterns: ["anthropic/claude-sonnet"],
            editable: true,
            revision: "old-revision",
            resolvedModelIds: ["anthropic/claude-sonnet"],
            reason: nil
        ))
        model.runtimeOptions = conflictedOptions
        model.beginGlobalScopeEditing()
        model.setStagedScopePattern("openai-codex/gpt-5.5", selected: true)

        #expect(model.scopeStaging.patterns == ["anthropic/claude-sonnet", "openai-codex/gpt-5.5"])

        let authoritativeOptions = runtimeOptions(scope: .init(
            mode: .exact,
            patterns: ["openai-codex/gpt-5.5"],
            editable: true,
            revision: "new-revision",
            resolvedModelIds: ["openai-codex/gpt-5.5"],
            reason: nil
        ))
        model.replaceScopeStaging(with: authoritativeOptions)

        #expect(model.scopeStaging == .init(scope: authoritativeOptions.globalScope))
        #expect(model.scopeStaging.patterns == ["openai-codex/gpt-5.5"])
    }

    @Test func exactScopeStagingMatchesAndRemovesCanonicalIDsCaseInsensitively() {
        var staging = PickyComposerRuntimeScopeStaging(scope: .init(
            mode: .exact,
            patterns: ["OpenAI-Codex/GPT-5.5", "openai-codex/gpt-5.5"],
            editable: true,
            revision: "revision",
            resolvedModelIds: ["openai-codex/gpt-5.5"],
            reason: nil
        ))

        #expect(staging.patterns == ["OpenAI-Codex/GPT-5.5"])
        #expect(staging.containsPattern("openai-codex/gpt-5.5"))
        staging.setPattern("OPENAI-CODEX/GPT-5.5", selected: true)
        #expect(staging.patterns == ["OpenAI-Codex/GPT-5.5"])
        staging.setPattern("openai-codex/gpt-5.5", selected: false)
        #expect(staging.patterns.isEmpty)
    }

    @Test func pickerRowNavigationIsDeterministicAcrossFilteredRows() {
        let rows = ["anthropic/claude-sonnet", "openai-codex/gpt-5.5"]
        #expect(PickyComposerRuntimePickerRowNavigation.first(in: rows) == rows[0])
        #expect(PickyComposerRuntimePickerRowNavigation.next(after: rows[0], in: rows) == rows[1])
        #expect(PickyComposerRuntimePickerRowNavigation.next(after: rows[1], in: rows) == rows[1])
        #expect(PickyComposerRuntimePickerRowNavigation.previous(before: rows[1], in: rows) == rows[0])
        #expect(PickyComposerRuntimePickerRowNavigation.previous(before: rows[0], in: rows) == rows[0])
        #expect(PickyComposerRuntimePickerRowNavigation.focusAfterFiltering(currentID: rows[1], rowIDs: [rows[0]]) == rows[0])
        #expect(PickyComposerRuntimePickerRowNavigation.focusAfterFiltering(currentID: rows[1], rowIDs: []) == nil)
    }

    private func runtimeOptions(scope: PickyRuntimeModelScope) -> PickySessionRuntimeOptions {
        PickySessionRuntimeOptions(
            models: [],
            allModels: [],
            globalScope: scope,
            thinkingLevels: [],
            currentModel: nil
        )
    }
}

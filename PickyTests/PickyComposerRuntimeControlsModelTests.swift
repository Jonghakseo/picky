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

    @Test func exactScopeStagingPreservesCycleOrderAndCanonicalMixedCaseMembership() {
        var staging = PickyComposerRuntimeScopeStaging(scope: .init(
            mode: .exact,
            patterns: ["Zeta/Model", "OpenAI-Codex/GPT-5.5", "anthropic/claude-sonnet", "openai-codex/gpt-5.5"],
            editable: true,
            revision: "revision",
            resolvedModelIds: ["zeta/model", "openai-codex/gpt-5.5", "anthropic/claude-sonnet"],
            reason: nil
        ))

        #expect(staging.patterns == ["Zeta/Model", "OpenAI-Codex/GPT-5.5", "anthropic/claude-sonnet"])
        #expect(staging.containsPattern("openai-codex/gpt-5.5"))
        staging.setPattern("OPENAI-CODEX/GPT-5.5", selected: true)
        #expect(staging.patterns == ["Zeta/Model", "OpenAI-Codex/GPT-5.5", "anthropic/claude-sonnet"])
        staging.setPattern("OPENAI-CODEX/GPT-5.5", selected: false)
        #expect(staging.patterns == ["Zeta/Model", "anthropic/claude-sonnet"])
        staging.setPattern("Beta/New", selected: true)
        #expect(staging.patterns == ["Zeta/Model", "anthropic/claude-sonnet", "Beta/New"])
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

    @Test func searchReconciliationKeepsFieldFocusUntilDirectionalNavigationEntersRows() {
        let allRows = ["anthropic/claude-sonnet", "openai-codex/gpt-5.5"]
        let filteredRows = ["openai-codex/gpt-5.5"]

        // Typing multiple characters must retain the TextField's nil row focus.
        #expect(PickyComposerRuntimePickerRowNavigation.focusAfterFiltering(currentID: nil, rowIDs: allRows) == nil)
        #expect(PickyComposerRuntimePickerRowNavigation.focusAfterFiltering(currentID: nil, rowIDs: filteredRows) == nil)
        // Once Down or Up explicitly moves into a row, filtering reconciles it.
        #expect(PickyComposerRuntimePickerRowNavigation.next(after: nil, in: allRows) == allRows[0])
        #expect(PickyComposerRuntimePickerRowNavigation.focusAfterFiltering(currentID: allRows[0], rowIDs: filteredRows) == filteredRows[0])
    }

    @Test func scopeApplySuccessOnlyReturnsTheMatchingPickerSessionToQuick() {
        let success = PickyComposerRuntimeScopeApplySuccess(sessionID: "pickle-1", generation: 2)

        #expect(PickyComposerRuntimePickerScreenPolicy.shouldReturnToQuick(
            after: success,
            sessionID: "pickle-1",
            lastHandledGeneration: 1
        ))
        #expect(!PickyComposerRuntimePickerScreenPolicy.shouldReturnToQuick(
            after: success,
            sessionID: "pickle-2",
            lastHandledGeneration: 0
        ))
        #expect(!PickyComposerRuntimePickerScreenPolicy.shouldReturnToQuick(
            after: success,
            sessionID: "pickle-1",
            lastHandledGeneration: 2
        ))
        #expect(!PickyComposerRuntimePickerScreenPolicy.shouldReturnToQuick(
            after: nil,
            sessionID: "pickle-1",
            lastHandledGeneration: 0
        ))
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

//
//  PickyConversationRuntimeControlsView.swift
//  Picky
//
//  Runtime model and thinking controls for the conversation composer.
//

import SwiftUI

enum PickyComposerRuntimeOptionsLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

enum PickyComposerRuntimePickerScreen {
    case quick
    case allModels
}

struct PickyConversationRuntimeControlsView: View {

    let presentation: PickyComposerRuntimePresentation
    let actionError: String?
    let sessionID: String
    @Binding var isModelPickerPresented: Bool
    let runtimeOptions: PickySessionRuntimeOptions?
    let modelPickerLoadState: PickyComposerRuntimeOptionsLoadState
    let isModelActionInFlight: Bool
    let isThinkingActionInFlight: Bool
    let isGlobalScopeActionInFlight: Bool
    let pickleRuntimeDefaults: (modelPattern: String, thinkingLevel: PickyPickleAgentThinkingLevel)
    let scopeStaging: PickyComposerRuntimeScopeStaging
    /// Allows the same production picker component to start on a detail page.
    /// Composer uses `.quick`; deterministic gallery scenes also use this seam.
    let initialPickerScreen: PickyComposerRuntimePickerScreen
    let onOpenModelPicker: () -> Void
    let onRetryRuntimeOptions: () -> Void
    let onSelectModel: (PickySessionRuntimeModelOption) -> Void
    let onSelectThinkingLevel: (PickyMainAgentThinkingLevel) -> Void
    let onSetNewPickleDefaultModel: (PickySessionRuntimeModelOption) -> Void
    let onSetNewPickleDefaultThinking: (PickyMainAgentThinkingLevel) -> Void
    let onBeginGlobalScopeEditing: () -> Void
    let onSetAllModelsEnabled: (Bool, String?) -> Void
    let onSetStagedScopePattern: (String, Bool) -> Void
    let onReloadGlobalScope: () -> Void
    let onApplyGlobalScope: () -> Void

    @State private var modelQuery = ""
    @State private var pickerScreen: PickyComposerRuntimePickerScreen = .quick
    @FocusState private var focusedModelRowID: String?

    init(
        presentation: PickyComposerRuntimePresentation,
        actionError: String?,
        sessionID: String,
        isModelPickerPresented: Binding<Bool>,
        runtimeOptions: PickySessionRuntimeOptions?,
        modelPickerLoadState: PickyComposerRuntimeOptionsLoadState,
        isModelActionInFlight: Bool,
        isThinkingActionInFlight: Bool,
        isGlobalScopeActionInFlight: Bool,
        pickleRuntimeDefaults: (modelPattern: String, thinkingLevel: PickyPickleAgentThinkingLevel),
        scopeStaging: PickyComposerRuntimeScopeStaging,
        initialPickerScreen: PickyComposerRuntimePickerScreen = .quick,
        onOpenModelPicker: @escaping () -> Void,
        onRetryRuntimeOptions: @escaping () -> Void,
        onSelectModel: @escaping (PickySessionRuntimeModelOption) -> Void,
        onSelectThinkingLevel: @escaping (PickyMainAgentThinkingLevel) -> Void,
        onSetNewPickleDefaultModel: @escaping (PickySessionRuntimeModelOption) -> Void,
        onSetNewPickleDefaultThinking: @escaping (PickyMainAgentThinkingLevel) -> Void,
        onBeginGlobalScopeEditing: @escaping () -> Void,
        onSetAllModelsEnabled: @escaping (Bool, String?) -> Void,
        onSetStagedScopePattern: @escaping (String, Bool) -> Void,
        onReloadGlobalScope: @escaping () -> Void,
        onApplyGlobalScope: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.actionError = actionError
        self.sessionID = sessionID
        _isModelPickerPresented = isModelPickerPresented
        self.runtimeOptions = runtimeOptions
        self.modelPickerLoadState = modelPickerLoadState
        self.isModelActionInFlight = isModelActionInFlight
        self.isThinkingActionInFlight = isThinkingActionInFlight
        self.isGlobalScopeActionInFlight = isGlobalScopeActionInFlight
        self.pickleRuntimeDefaults = pickleRuntimeDefaults
        self.scopeStaging = scopeStaging
        self.initialPickerScreen = initialPickerScreen
        _pickerScreen = State(initialValue: initialPickerScreen)
        self.onOpenModelPicker = onOpenModelPicker
        self.onRetryRuntimeOptions = onRetryRuntimeOptions
        self.onSelectModel = onSelectModel
        self.onSelectThinkingLevel = onSelectThinkingLevel
        self.onSetNewPickleDefaultModel = onSetNewPickleDefaultModel
        self.onSetNewPickleDefaultThinking = onSetNewPickleDefaultThinking
        self.onBeginGlobalScopeEditing = onBeginGlobalScopeEditing
        self.onSetAllModelsEnabled = onSetAllModelsEnabled
        self.onSetStagedScopePattern = onSetStagedScopePattern
        self.onReloadGlobalScope = onReloadGlobalScope
        self.onApplyGlobalScope = onApplyGlobalScope
    }

    @ViewBuilder
    var body: some View {
        if presentation.hasControls || actionError != nil {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Spacing.space1) {
            modelControl
            thinkingControl
            runtimeError
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.composer.runtime.accessibilityLabel"))
    }

    @ViewBuilder
    private var modelControl: some View {
        if let modelText = presentation.modelText {
            Button(action: onOpenModelPicker) {
                controlLabel(text: modelText, maximumTextWidth: PickyComposerToolbarMetrics.modelLabelMaximumWidth, trailingIcon: "chevron.down")
            }
            .buttonStyle(PickyComposerToolbarGhostButtonStyle())
            .help(L10n.t("hud.composer.runtime.model.help"))
            .accessibilityLabel(presentation.modelLabel ?? modelText)
            .accessibilityHint(L10n.t("hud.composer.runtime.model.accessibilityHint"))
            .disabled(isModelActionInFlight)
            .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) { modelPicker }
        }
    }

    @ViewBuilder
    private var thinkingControl: some View {
        if let thinkingText = presentation.thinkingText {
            Menu {
                ForEach(runtimeOptions?.thinkingLevels ?? [], id: \.self) { level in
                    Button { onSelectThinkingLevel(level) } label: {
                        if level.rawValue == thinkingText {
                            Label(level.displayName, systemImage: "checkmark")
                        } else {
                            Text(level.displayName)
                        }
                    }
                }
                Divider()
                Button { onSetNewPickleDefaultThinking(PickyMainAgentThinkingLevel(rawValue: thinkingText) ?? .off) } label: {
                    if pickleRuntimeDefaults.thinkingLevel.rawValue == thinkingText {
                        Label(L10n.t("hud.composer.runtime.defaultThinking"), systemImage: "checkmark")
                    } else {
                        Text(L10n.t("hud.composer.runtime.defaultThinking"))
                    }
                }
                .disabled(isThinkingActionInFlight)
            } label: {
                controlLabel(text: thinkingText, trailingIcon: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(DS.Colors.textSecondary)
            .help(L10n.t("hud.composer.runtime.thinking.help"))
            .accessibilityLabel(presentation.thinkingLabel ?? thinkingText)
            .accessibilityHint(L10n.t("hud.composer.runtime.thinking.accessibilityHint"))
            .disabled((runtimeOptions?.thinkingLevels.isEmpty ?? true) || isThinkingActionInFlight)
        }
    }

    @ViewBuilder
    private var runtimeError: some View {
        if let actionError {
            Label(L10n.t("hud.composer.runtime.failed", actionError), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.destructiveText)
                .help(actionError)
                .accessibilityLabel(L10n.t("hud.composer.runtime.failed", actionError))
        }
    }

    var modelPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            if pickerScreen == .allModels {
                allModelsPicker
            } else {
                quickModelPicker
            }
        }
        .padding(DS.Spacing.space3)
        .frame(width: PickyComposerToolbarMetrics.runtimePickerWidth)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .onAppear {
            if initialPickerScreen == .quick {
                pickerScreen = .quick
            }
            resetPicker()
        }
        .onChange(of: sessionID) { _, _ in
            pickerScreen = .quick
            resetPicker()
        }
        .onChange(of: modelQuery) { _, _ in
            reconcileFocusedRow()
        }
        .onChange(of: pickerScreen) { _, _ in
            focusedModelRowID = nil
        }
    }

    private var quickModelPicker: some View {
        Group {
            TextField(L10n.t("hud.composer.runtime.picker.search"), text: $modelQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("hud.composer.runtime.picker.search"))
            pickerContent
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        switch modelPickerLoadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.t("hud.composer.runtime.picker.loading"))
        case .failed(let message):
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                Text(L10n.t("hud.composer.runtime.picker.failed", message))
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.destructiveText)
                Button(L10n.t("hud.composer.runtime.picker.retry"), action: onRetryRuntimeOptions)
                    .buttonStyle(.borderless)
            }
        case .empty:
            Text(L10n.t("hud.composer.runtime.picker.empty"))
                .font(PickyHUDTypography.meta)
                .foregroundColor(DS.Colors.textSecondary)
        case .loaded:
            if let currentOutsideScopeModel {
                currentOutsideScopeNotice(currentOutsideScopeModel)
            }
            if filteredModels.isEmpty {
                Text(L10n.t("hud.composer.runtime.picker.empty"))
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                modelRows(filteredModels) { model in
                    onSelectModel(model)
                }
                .disabled(isModelActionInFlight)
            }
            quickPickerFooter
        }
    }

    private var quickPickerFooter: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            Divider()
            if let current = currentModelOption {
                Button { onSetNewPickleDefaultModel(current) } label: {
                    if pickleRuntimeDefaults.modelPattern == current.pattern {
                        Label(L10n.t("hud.composer.runtime.defaultModel"), systemImage: "checkmark")
                    } else {
                        Text(L10n.t("hud.composer.runtime.defaultModel"))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isModelActionInFlight)
            }
            Button(L10n.t("hud.composer.runtime.picker.allModels")) { openAllModels() }
                .buttonStyle(.borderless)
                .disabled(runtimeOptions?.globalScope == nil)
        }
    }

    private var allModelsPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            HStack {
                Button(L10n.t("hud.composer.runtime.picker.back")) { pickerScreen = .quick }
                    .buttonStyle(.borderless)
                Spacer()
                Text(L10n.t("hud.composer.runtime.picker.allModelsTitle"))
                    .font(PickyHUDTypography.title)
            }
            TextField(L10n.t("hud.composer.runtime.picker.search"), text: $modelQuery)
                .textFieldStyle(.roundedBorder)

            if runtimeOptions?.projectScope != nil {
                Label(L10n.t("hud.composer.runtime.picker.projectOverride"), systemImage: "folder")
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            if let scope = runtimeOptions?.globalScope, !scope.editable {
                Label(scope.reason?.localizedDescription ?? L10n.t("hud.composer.runtime.picker.advancedReadOnly"), systemImage: "lock")
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.warningText)
            }

            switch modelPickerLoadState {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.t("hud.composer.runtime.picker.loading"))
            case .failed(let message):
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    Text(L10n.t("hud.composer.runtime.picker.failed", message))
                        .font(PickyHUDTypography.meta)
                        .foregroundColor(DS.Colors.destructiveText)
                    Button(L10n.t("hud.composer.runtime.picker.retry"), action: onReloadGlobalScope)
                        .buttonStyle(.borderless)
                }
            case .empty, .loaded:
                allModelsScopeEditor
            }

            if let actionError {
                Label(L10n.t("hud.composer.runtime.picker.failed", actionError), systemImage: "exclamationmark.triangle.fill")
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    private var allModelsScopeEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Toggle(L10n.t("hud.composer.runtime.picker.allEnabled"), isOn: Binding(
                get: { scopeStaging.mode == .all },
                set: { enabled in onSetAllModelsEnabled(enabled, filteredAllModels.first?.pattern) }
            ))
            .disabled(!isScopeEditable)

            if scopeStaging.mode == .exact {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredAllModels) { model in
                            Toggle(model.displayName, isOn: Binding(
                                get: { isScopeStaged(model) },
                                set: { selected in onSetStagedScopePattern(model.pattern, selected) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(PickyHUDTypography.meta)
                            .frame(maxWidth: .infinity, minHeight: PickyComposerToolbarMetrics.runtimePickerRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                            .focusable()
                            .focused($focusedModelRowID, equals: model.id)
                            .onMoveCommand { moveFocusedRow($0, rows: filteredAllModels) }
                            .accessibilityLabel(model.displayName)
                            .disabled(!isScopeEditable)
                        }
                    }
                }
                .frame(height: PickyComposerToolbarMetrics.runtimePickerListHeight)
            }

            if runtimeOptions?.globalScope != nil {
                HStack {
                    Button(L10n.t("hud.composer.runtime.picker.reload"), action: onReloadGlobalScope)
                        .buttonStyle(.borderless)
                    Spacer()
                    Button(L10n.t("hud.composer.runtime.picker.apply"), action: onApplyGlobalScope)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Colors.accent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canApplyScope)
                }
            }
        }
    }

    private var filteredModels: [PickySessionRuntimeModelOption] { filtered(runtimeOptions?.models ?? []) }
    private var filteredAllModels: [PickySessionRuntimeModelOption] { filtered(runtimeOptions?.allModels ?? []) }

    private func filtered(_ models: [PickySessionRuntimeModelOption]) -> [PickySessionRuntimeModelOption] {
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter { $0.displayName.lowercased().contains(query) || $0.pattern.lowercased().contains(query) }
    }

    private var currentModelOption: PickySessionRuntimeModelOption? {
        guard let identity = runtimeOptions?.currentModel else { return nil }
        return (runtimeOptions?.allModels ?? runtimeOptions?.models ?? []).first { $0.provider == identity.provider && $0.modelId == identity.modelId }
    }

    private var currentOutsideScopeModel: PickySessionRuntimeModelOption? {
        guard let current = currentModelOption,
              !(runtimeOptions?.models.contains(where: { $0.id == current.id }) ?? false)
        else { return nil }
        return current
    }

    private func currentOutsideScopeNotice(_ model: PickySessionRuntimeModelOption) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.space1) {
            Image(systemName: "exclamationmark.triangle")
                .frame(width: PickyComposerToolbarMetrics.runtimePickerNoticeIconWidth, alignment: .leading)
            Text(L10n.t("hud.composer.runtime.picker.currentOutsideScope", model.pattern))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(PickyHUDTypography.meta)
        .foregroundColor(DS.Colors.warningText)
        .frame(height: PickyComposerToolbarMetrics.runtimePickerNoticeHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("hud.composer.runtime.picker.currentOutsideScope", model.pattern))
    }

    private func modelRows(_ models: [PickySessionRuntimeModelOption], onSelect: @escaping (PickySessionRuntimeModelOption) -> Void) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(models) { model in
                    Button { onSelect(model) } label: {
                        HStack(spacing: DS.Spacing.space2) {
                            Text(model.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: DS.Spacing.space2)
                            if isCurrentModel(model) {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(PickyHUDTypography.meta)
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: PickyComposerToolbarMetrics.runtimePickerRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedModelRowID, equals: model.id)
                    .onMoveCommand { moveFocusedRow($0, rows: models) }
                    .accessibilityLabel(model.displayName)
                    .accessibilityValue(isCurrentModel(model) ? L10n.t("hud.composer.runtime.picker.selected") : "")
                }
            }
        }
        .frame(height: PickyComposerToolbarMetrics.runtimePickerListHeight)
    }

    private func isScopeStaged(_ model: PickySessionRuntimeModelOption) -> Bool {
        if !isScopeEditable {
            return runtimeOptions?.globalScope?.resolvedModelIds?.contains { $0.caseInsensitiveCompare(model.id) == .orderedSame } ?? false
        }
        return scopeStaging.containsPattern(model.pattern)
    }

    private var isScopeEditable: Bool { runtimeOptions?.globalScope?.editable == true && !isGlobalScopeActionInFlight }
    private var canApplyScope: Bool {
        guard isScopeEditable, let revision = runtimeOptions?.globalScope?.revision, !revision.isEmpty else { return false }
        return scopeStaging.mode == .all || !scopeStaging.patterns.isEmpty
    }

    private func isCurrentModel(_ model: PickySessionRuntimeModelOption) -> Bool {
        runtimeOptions?.currentModel?.provider == model.provider && runtimeOptions?.currentModel?.modelId == model.modelId
    }

    private func moveFocusedRow(_ direction: MoveCommandDirection, rows: [PickySessionRuntimeModelOption]) {
        let rowIDs = rows.map(\.id)
        switch direction {
        case .up:
            focusedModelRowID = PickyComposerRuntimePickerRowNavigation.previous(before: focusedModelRowID, in: rowIDs)
        case .down:
            focusedModelRowID = PickyComposerRuntimePickerRowNavigation.next(after: focusedModelRowID, in: rowIDs)
        default:
            break
        }
    }

    private func reconcileFocusedRow() {
        let rows = pickerScreen == .allModels ? filteredAllModels : filteredModels
        focusedModelRowID = PickyComposerRuntimePickerRowNavigation.focusAfterFiltering(
            currentID: focusedModelRowID,
            rowIDs: rows.map(\.id)
        )
    }

    private func resetPicker() {
        modelQuery = ""
        focusedModelRowID = nil
        onBeginGlobalScopeEditing()
    }

    private func openAllModels() {
        modelQuery = ""
        onBeginGlobalScopeEditing()
        pickerScreen = .allModels
    }

    private func controlLabel(text: String, maximumTextWidth: CGFloat? = nil, trailingIcon: String? = nil) -> some View {
        HStack(spacing: DS.Spacing.space1) {
            Text(text)
                .font(PickyHUDTypography.meta)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maximumTextWidth)
            if let trailingIcon { Image(systemName: trailingIcon).font(PickyHUDTypography.meta) }
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, DS.Spacing.space2)
        .frame(height: PickyComposerToolbarMetrics.controlSize)
        .contentShape(Rectangle())
    }
}

struct PickyComposerToolbarGhostButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(backgroundColor(isPressed: configuration.isPressed)))
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = isEnabled && $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled { return .clear }
        if isPressed { return DS.Colors.surface4 }
        if isHovered { return DS.Colors.surface3 }
        return isActive ? DS.Colors.accentSubtle : .clear
    }
}

enum PickyComposerToolbarMetrics {
    static let controlSize = DS.Spacing.space6 + DS.Spacing.space1
    static let modelLabelMaximumWidth: CGFloat = 126 // design-token-exception: keeps long runtime model IDs inside the fixed 446pt Composer row
    static let runtimePickerListMinimumHeight = DS.Spacing.space8 * 3
    static let runtimePickerListHeight = runtimePickerListMinimumHeight
    static let runtimePickerRowHeight = DS.Spacing.space6
    static let runtimePickerNoticeHeight = DS.Spacing.space8
    static let runtimePickerNoticeIconWidth = DS.Spacing.space3
    static let runtimePickerWidth = DS.Spacing.space8 * 8
}

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

enum PickyComposerSettingsPage: Equatable {
    case menu
    case model
    case thinking
}

struct PickyComposerCompletionNotificationState: Equatable {
    let notifyMain: Bool
    let notifyMacOS: Bool
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
    let globalScopeApplySuccess: PickyComposerRuntimeScopeApplySuccess?
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
    /// Nil hides the control: the current model has no provider fast mode.
    let fastMode: PickyComposerFastModeControlState?
    let onToggleFastMode: () -> Void
    /// Nil hides the completion section (galleries that show runtime rows only).
    let completionNotifications: PickyComposerCompletionNotificationState?
    let onToggleNotifyMain: () -> Void
    let onToggleNotifyMacOS: () -> Void

    @State private var modelQuery = ""
    @State private var pickerScreen: PickyComposerRuntimePickerScreen = .quick
    @State private var settingsPage: PickyComposerSettingsPage = .menu
    @StateObject private var fastModeNotice = PickyComposerFastModeNotice()
    @State private var lastHandledScopeApplyGeneration = 0
    @FocusState private var focusedModelRowID: String?
    @FocusState private var focusedThinkingRowID: String?

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
        globalScopeApplySuccess: PickyComposerRuntimeScopeApplySuccess? = nil,
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
        onApplyGlobalScope: @escaping () -> Void,
        fastMode: PickyComposerFastModeControlState? = nil,
        onToggleFastMode: @escaping () -> Void = {},
        completionNotifications: PickyComposerCompletionNotificationState? = nil,
        onToggleNotifyMain: @escaping () -> Void = {},
        onToggleNotifyMacOS: @escaping () -> Void = {}
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
        self.globalScopeApplySuccess = globalScopeApplySuccess
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
        self.fastMode = fastMode
        self.onToggleFastMode = onToggleFastMode
        self.completionNotifications = completionNotifications
        self.onToggleNotifyMain = onToggleNotifyMain
        self.onToggleNotifyMacOS = onToggleNotifyMacOS
    }

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            settingsChip
            runtimeError
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.composer.runtime.accessibilityLabel"))
        .onChange(of: sessionID) { _, _ in
            fastModeNotice.dismiss()
            settingsPage = .menu
        }
        .onChange(of: fastMode) { _, _ in fastModeNotice.dismiss() }
        .onChange(of: isModelPickerPresented) { _, isPresented in
            guard !isPresented else { return }
            fastModeNotice.dismiss()
            settingsPage = .menu
        }
    }

    // MARK: Settings chip

    /// One chip for every per-Pickle setting. It shows the compact model name,
    /// thinking level, and Fast only while Fast is on (it costs more); the
    /// completion alerts stay inside the popover.
    private var settingsChip: some View {
        Button {
            settingsPage = .menu
            fastModeNotice.dismiss()
            onOpenModelPicker()
        } label: {
            HStack(spacing: DS.Spacing.space1) {
                if let chipModelText = presentation.chipModelText {
                    PickyComposerCappedWidthLayout(
                        maximumWidth: PickyComposerToolbarMetrics.settingsChipModelMaximumWidth,
                        minimumWidth: PickyComposerToolbarMetrics.settingsChipModelMinimumWidth
                    ) {
                        Text(chipModelText).lineLimit(1).truncationMode(.middle)
                    }
                    // The model name shrinks first so the send/stop actions never clip.
                    .layoutPriority(-1)
                }
                ForEach(Array(chipSuffixes.enumerated()), id: \.offset) { index, suffix in
                    if index > 0 || presentation.chipModelText != nil {
                        Text(verbatim: "·").foregroundColor(DS.Colors.textTertiary)
                    }
                    Text(suffix).lineLimit(1).fixedSize()
                }
                if presentation.chipModelText == nil, chipSuffixes.isEmpty {
                    Text("hud.composer.settings.chip.empty").lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.down")
                    .pickyFont(size: 7.5, weight: .bold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .font(PickyHUDTypography.status)
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.space2)
            .frame(height: PickyComposerToolbarMetrics.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: isModelPickerPresented))
        .help(L10n.t("hud.composer.settings.help"))
        .accessibilityLabel(L10n.t("hud.composer.settings.accessibilityLabel"))
        .accessibilityValue(chipAccessibilityValue)
        .pickyInstantPopover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
            settingsPopover
        }
    }

    private var chipSuffixes: [String] {
        var suffixes: [String] = []
        if let thinkingText = presentation.thinkingText { suffixes.append(thinkingText) }
        if fastMode?.isEnabled == true { suffixes.append(L10n.t("hud.composer.settings.chip.fast")) }
        return suffixes
    }

    private var chipAccessibilityValue: String {
        ([presentation.modelText] + chipSuffixes.map(Optional.some))
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var settingsPopover: some View {
        if fastModeNotice.isPresented {
            fastModeCostNotice
        } else {
            switch settingsPage {
            case .menu:
                settingsMenu
            case .model:
                VStack(alignment: .leading, spacing: 0) {
                    settingsBackButton
                    modelPicker
                }
            case .thinking:
                VStack(alignment: .leading, spacing: 0) {
                    settingsBackButton
                    thinkingPicker
                }
            }
        }
    }

    /// Exposed for the offscreen gallery, which mounts it without a popover.
    var settingsMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsSectionLabel("hud.composer.settings.title")
                .padding(.top, DS.Spacing.space3)
            if let modelText = presentation.modelText {
                settingsValueRow(
                    title: "hud.composer.settings.model",
                    value: modelText,
                    shortcut: "⌃P",
                    action: { settingsPage = .model }
                )
                .disabled(isModelActionInFlight)
            }
            if let thinkingText = presentation.thinkingText {
                settingsValueRow(
                    title: "hud.composer.settings.thinking",
                    value: thinkingText,
                    shortcut: nil,
                    action: { settingsPage = .thinking }
                )
                .disabled((runtimeOptions?.thinkingLevels.isEmpty ?? true) || isThinkingActionInFlight)
            }
            if let fastMode {
                settingsToggleRow(
                    title: "hud.composer.settings.fast",
                    detail: "hud.composer.settings.fast.detail",
                    shortcut: nil,
                    isOn: fastMode.isEnabled,
                    isDisabled: fastMode.isUpdating
                ) {
                    fastModeNotice.requestToggle(control: fastMode, sessionID: sessionID, onToggle: onToggleFastMode)
                }
            }
            if let completionNotifications {
                if presentation.hasControls || fastMode != nil {
                    Divider()
                        .padding(.horizontal, DS.Spacing.space3)
                        .padding(.vertical, DS.Spacing.space2)
                }
                settingsSectionLabel("hud.composer.settings.completion")
                settingsToggleRow(
                    title: "hud.composer.settings.notifyMain",
                    detail: nil,
                    shortcut: nil,
                    isOn: completionNotifications.notifyMain,
                    isDisabled: false,
                    onToggle: onToggleNotifyMain
                )
                settingsToggleRow(
                    title: "hud.composer.settings.notifyMacOS",
                    detail: nil,
                    shortcut: "⌘N",
                    isOn: completionNotifications.notifyMacOS,
                    isDisabled: false,
                    onToggle: onToggleNotifyMacOS
                )
            }
            Spacer().frame(height: DS.Spacing.space1)
        }
        .frame(width: PickyComposerToolbarMetrics.settingsMenuWidth, alignment: .leading)
    }

    private var settingsBackButton: some View {
        Button { settingsPage = .menu } label: {
            HStack(spacing: DS.Spacing.space1) {
                Image(systemName: "chevron.left")
                    .pickyFont(size: 9, weight: .bold)
                    .accessibilityHidden(true)
                Text("hud.composer.settings.title")
            }
            .font(PickyHUDTypography.status)
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.top, DS.Spacing.space2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("hud.composer.settings.back.accessibilityLabel"))
    }

    private func settingsSectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(PickyHUDTypography.status)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.bottom, DS.Spacing.space1)
            .accessibilityAddTraits(.isHeader)
    }

    // Every row shares one 8pt vertical inset with no fixed height, so the gap
    // between visible content stays 16pt whether or not a row has a detail line.
    private func settingsValueRow(
        title: LocalizedStringKey,
        value: String,
        shortcut: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.space2) {
                Text(title)
                    .font(PickyHUDTypography.bodyCompact)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: DS.Spacing.space2)
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .pickyFont(size: 8, weight: .bold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.vertical, DS.Spacing.space2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickyComposerSettingsRowButtonStyle())
        .accessibilityValue(value)
    }

    private func settingsToggleRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey?,
        shortcut: String?,
        isOn: Bool,
        isDisabled: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DS.Spacing.space2) {
            VStack(alignment: .leading, spacing: 2) { // design-token-exception: title/detail optical gap
                Text(title)
                    .font(PickyHUDTypography.bodyCompact)
                    .foregroundColor(DS.Colors.textPrimary)
                if let detail {
                    Text(detail)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.space2)
            if let shortcut {
                Text(verbatim: shortcut)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            Toggle(isOn: Binding(get: { isOn }, set: { newValue in
                guard newValue != isOn else { return }
                onToggle()
            })) {
                Text(title)
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isDisabled)
        }
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.vertical, DS.Spacing.space2)
    }

    /// Production popover content, also mounted directly by the offscreen gallery.
    var fastModeCostNotice: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space3) {
            Text("hud.composer.fastMode.notice.title")
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.textPrimary)
            Text("hud.composer.fastMode.notice.message")
                .font(PickyHUDTypography.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("common.cancel") { fastModeNotice.dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("hud.composer.fastMode.notice.enable") {
                    fastModeNotice.confirm(control: fastMode, sessionID: sessionID, onToggle: onToggleFastMode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(fastMode?.isUpdating != false)
            }
        }
        .padding(DS.Spacing.space3)
        .frame(width: PickyComposerToolbarMetrics.runtimePickerWidth, alignment: .leading)
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
        .frame(
            width: PickyComposerToolbarMetrics.runtimePickerWidth,
            height: pickerScreen == .quick ? PickyComposerToolbarMetrics.runtimeQuickPickerHeight : nil,
            alignment: .topLeading
        )
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
            lastHandledScopeApplyGeneration = 0
            resetPicker()
        }
        .onChange(of: globalScopeApplySuccess) { _, success in
            guard PickyComposerRuntimePickerScreenPolicy.shouldReturnToQuick(
                after: success,
                sessionID: sessionID,
                lastHandledGeneration: lastHandledScopeApplyGeneration
            ) else { return }
            lastHandledScopeApplyGeneration = success?.generation ?? lastHandledScopeApplyGeneration
            pickerScreen = .quick
        }
        .onChange(of: modelQuery) { _, _ in
            reconcileFocusedRow()
        }
        .onChange(of: pickerScreen) { _, _ in
            focusedModelRowID = nil
        }
    }

    private var quickModelPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            TextField(L10n.t("hud.composer.runtime.picker.search"), text: $modelQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("hud.composer.runtime.picker.search"))
                .onMoveCommand { moveFocusedRow($0, rows: filteredModels) }
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                pickerContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var thinkingPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(runtimeOptions?.thinkingLevels ?? [], id: \.self) { level in
                Button {
                    isModelPickerPresented = false
                    onSelectThinkingLevel(level)
                } label: {
                    pickerRowLabel(
                        text: level.displayName,
                        selected: level.rawValue == presentation.thinkingText
                    )
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedThinkingRowID, equals: level.rawValue)
                .onMoveCommand(perform: moveFocusedThinkingRow)
                .accessibilityLabel(level.displayName)
                .accessibilityValue(
                    level.rawValue == presentation.thinkingText
                        ? L10n.t("hud.composer.runtime.picker.selected")
                        : ""
                )
            }
            Divider()
                .padding(.vertical, DS.Spacing.space1)
            Button {
                isModelPickerPresented = false
                onSetNewPickleDefaultThinking(
                    PickyMainAgentThinkingLevel(rawValue: presentation.thinkingText ?? "") ?? .off
                )
            } label: {
                pickerRowLabel(
                    text: L10n.t("hud.composer.runtime.defaultThinking"),
                    selected: pickleRuntimeDefaults.thinkingLevel.rawValue == presentation.thinkingText
                )
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedThinkingRowID, equals: Self.thinkingDefaultRowID)
            .onMoveCommand(perform: moveFocusedThinkingRow)
            .disabled(isThinkingActionInFlight)
        }
        .padding(DS.Spacing.space2)
        .frame(width: PickyComposerToolbarMetrics.runtimeThinkingPickerWidth)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .onAppear {
            let currentID = presentation.thinkingText
            focusedThinkingRowID = thinkingRowIDs.contains(currentID ?? "")
                ? currentID
                : thinkingRowIDs.first
        }
        .onExitCommand { settingsPage = .menu }
    }

    @ViewBuilder
    private var pickerContent: some View {
        switch modelPickerLoadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                .onMoveCommand { moveFocusedRow($0, rows: filteredAllModels) }

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
                        pickerRowLabel(text: model.displayName, selected: isCurrentModel(model))
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

    private var thinkingRowIDs: [String] {
        (runtimeOptions?.thinkingLevels.map(\.rawValue) ?? []) + [Self.thinkingDefaultRowID]
    }

    private func moveFocusedThinkingRow(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            focusedThinkingRowID = PickyComposerRuntimePickerRowNavigation.previous(
                before: focusedThinkingRowID,
                in: thinkingRowIDs
            )
        case .down:
            focusedThinkingRowID = PickyComposerRuntimePickerRowNavigation.next(
                after: focusedThinkingRowID,
                in: thinkingRowIDs
            )
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

    private func pickerRowLabel(text: String, selected: Bool) -> some View {
        HStack(spacing: DS.Spacing.space2) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Spacing.space2)
            if selected {
                Image(systemName: "checkmark")
                    .accessibilityHidden(true)
            }
        }
        .font(PickyHUDTypography.meta)
        .foregroundColor(DS.Colors.textPrimary)
        .frame(maxWidth: .infinity, minHeight: PickyComposerToolbarMetrics.runtimePickerRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static let thinkingDefaultRowID = "picky.runtime.thinking.default"

}

/// Fast mode toggle shown only while the current model supports provider fast mode.
struct PickyComposerFastModeControlState: Equatable {
    let isEnabled: Bool
    let isUpdating: Bool

    /// Hidden when the model has no fast mode, so a stored choice for another
    /// model never shows as a dead control.
    init?(enabled: Bool, supported: Bool, isUpdating: Bool) {
        guard supported else { return nil }
        isEnabled = enabled
        self.isUpdating = isUpdating
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
    static let settingsChipModelMaximumWidth: CGFloat = 104 // design-token-exception: the chip caps the model name so the 446pt row keeps its actions
    static let settingsChipModelMinimumWidth: CGFloat = 36 // design-token-exception: keeps a few glyphs of the model visible under pressure
    static let settingsMenuWidth = DS.Spacing.space8 * 8 + DS.Spacing.space2
    static let runtimePickerListMinimumHeight = DS.Spacing.space8 * 3
    static let runtimePickerListHeight = runtimePickerListMinimumHeight
    static let runtimePickerRowHeight = DS.Spacing.space6
    static let runtimePickerNoticeHeight = DS.Spacing.space8
    static let runtimePickerNoticeIconWidth = DS.Spacing.space3
    static let runtimePickerWidth = DS.Spacing.space8 * 8
    static let runtimeQuickPickerHeight = DS.Spacing.space8 * 8 - DS.Spacing.space2
    static let runtimeThinkingPickerWidth = runtimePickerWidth
}

/// Highlights a settings row on hover/press like a native menu item.
struct PickyComposerSettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? DS.Colors.surface4 : (isHovered ? DS.Colors.surface3 : .clear))
                    .padding(.horizontal, DS.Spacing.space1)
            )
            .onHover { isHovered = isEnabled && $0 }
    }
}

/// Hugs its content, caps it at `maximumWidth`, and gives way down to
/// `minimumWidth` when the row runs out of room.
struct PickyComposerCappedWidthLayout: Layout {
    let maximumWidth: CGFloat
    let minimumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        let target = max(minimumWidth, min(ideal.width, maximumWidth, proposal.width ?? .infinity))
        // A truncated label is narrower than the width it was offered; report
        // that width so no gap opens before the next label.
        let fitted = content.sizeThatFits(ProposedViewSize(width: target, height: nil))
        return CGSize(width: min(target, max(minimumWidth, fitted.width)), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

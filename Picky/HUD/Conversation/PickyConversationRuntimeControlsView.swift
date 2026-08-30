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

struct PickyConversationRuntimeControlsView: View {
    let presentation: PickyComposerRuntimePresentation
    let heightTier: PickyConversationFocusStackHeightTier
    let actionError: String?
    let sessionID: String
    @Binding var isModelPickerPresented: Bool
    let runtimeOptions: PickySessionRuntimeOptions?
    let modelPickerLoadState: PickyComposerRuntimeOptionsLoadState
    let isModelActionInFlight: Bool
    let isThinkingActionInFlight: Bool
    let onOpenModelPicker: () -> Void
    let onRetryRuntimeOptions: () -> Void
    let onSelectModel: (PickySessionRuntimeModelOption) -> Void
    let onSelectThinkingLevel: (PickyMainAgentThinkingLevel) -> Void
    @State private var modelQuery = ""

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
                controlLabel(icon: "cpu", text: modelText, maximumTextWidth: PickyComposerToolbarMetrics.modelLabelMaximumWidth)
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
            } label: {
                controlLabel(icon: "brain", text: thinkingText)
            }
            .menuStyle(.borderlessButton)
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

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            TextField(L10n.t("hud.composer.runtime.picker.search"), text: $modelQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("hud.composer.runtime.picker.search"))
            pickerContent
        }
        .padding(DS.Spacing.space3)
        .frame(width: PickyComposerToolbarMetrics.runtimePickerWidth)
        .onAppear { modelQuery = "" }
        .onChange(of: sessionID) { _, _ in
            modelQuery = ""
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
            if filteredModels.isEmpty {
                Text(L10n.t("hud.composer.runtime.picker.empty"))
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                List(filteredModels) { model in
                    Button {
                        onSelectModel(model)
                    } label: {
                        HStack {
                            Text(model.displayName)
                            Spacer()
                            if isCurrentModel(model) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.displayName)
                    .accessibilityValue(isCurrentModel(model) ? L10n.t("hud.composer.runtime.picker.selected") : "")
                }
                .disabled(isModelActionInFlight)
                .frame(minHeight: PickyComposerToolbarMetrics.runtimePickerListMinimumHeight)
            }
        }
    }

    private var filteredModels: [PickySessionRuntimeModelOption] {
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return runtimeOptions?.models ?? [] }
        return (runtimeOptions?.models ?? []).filter {
            $0.displayName.lowercased().contains(query) || $0.pattern.lowercased().contains(query)
        }
    }

    private func isCurrentModel(_ model: PickySessionRuntimeModelOption) -> Bool {
        runtimeOptions?.currentModel?.provider == model.provider
            && runtimeOptions?.currentModel?.modelId == model.modelId
    }

    private func controlLabel(
        icon: String,
        text: String,
        maximumTextWidth: CGFloat? = nil
    ) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(PickyHUDTypography.statusSemibold)
            if heightTier == .regular {
                Text(text)
                    .font(PickyHUDTypography.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: maximumTextWidth)
            }
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
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = isEnabled && $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled {
            return .clear
        }
        if isPressed {
            return DS.Colors.surface4
        }
        if isHovered {
            return DS.Colors.surface3
        }
        return isActive ? DS.Colors.accentSubtle : .clear
    }
}

enum PickyComposerToolbarMetrics {
    static let controlSize = DS.Spacing.space6 + DS.Spacing.space1
    static let modelLabelMaximumWidth: CGFloat = 126 // design-token-exception: keeps long runtime model IDs inside the fixed 446pt Composer row
    static let runtimePickerListMinimumHeight = DS.Spacing.space8 * 3
    static let runtimePickerWidth = DS.Spacing.space8 * 8
}

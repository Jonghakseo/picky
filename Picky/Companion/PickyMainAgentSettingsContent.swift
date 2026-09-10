import SwiftUI

/// Presentation-only main-agent settings groups. The enclosing settings view
/// retains draft ownership, persistence, and every side-effecting callback.
struct PickyMainAgentSettingsContent<OpenAgentsFile: View>: View {
    let presentation: CompanionPanelSettingsPresentation
    let modelOptions: [PickyMainAgentModelOption]
    let isLoadingModelOptions: Bool
    let onMainAgentCwdChanged: (String) -> Void
    let onPiBinaryPathChanged: (String) -> Void
    let onPiCodingAgentDirChanged: (String) -> Void
    let commitMainAgentCwdField: () -> Void
    let chooseMainAgentDirectory: () -> Void
    let choosePiBinaryFile: () -> Void
    let choosePiCodingAgentDirectory: () -> Void
    let save: () -> Void
    let refreshModelOptions: () -> Void
    let directoryField: (String, Binding<String>, @escaping (String) -> Void, @escaping () -> Void, @escaping () -> Void) -> AnyView
    let openAgentsFile: OpenAgentsFile

    @Binding var mainAgentCwdDraft: String
    @Binding var piBinaryPathDraft: String
    @Binding var piCodingAgentDirDraft: String
    @Binding var mainAgentModelPattern: String
    @Binding var mainAgentThinkingLevel: PickyMainAgentThinkingLevel
    @Binding var screenContextScope: PickyScreenContextScope
    @Binding var attachScreenshotsOnlyWhenInked: Bool
    @Binding var screenshotQuality: PickyScreenshotQuality
    @Binding var armedPickleDispatchMode: PickyArmedPickleDispatchMode

    init(
        presentation: CompanionPanelSettingsPresentation,
        modelOptions: [PickyMainAgentModelOption],
        isLoadingModelOptions: Bool,
        mainAgentCwdDraft: Binding<String>,
        piBinaryPathDraft: Binding<String>,
        piCodingAgentDirDraft: Binding<String>,
        mainAgentModelPattern: Binding<String>,
        mainAgentThinkingLevel: Binding<PickyMainAgentThinkingLevel>,
        screenContextScope: Binding<PickyScreenContextScope>,
        attachScreenshotsOnlyWhenInked: Binding<Bool>,
        screenshotQuality: Binding<PickyScreenshotQuality>,
        armedPickleDispatchMode: Binding<PickyArmedPickleDispatchMode>,
        onMainAgentCwdChanged: @escaping (String) -> Void,
        onPiBinaryPathChanged: @escaping (String) -> Void,
        onPiCodingAgentDirChanged: @escaping (String) -> Void,
        commitMainAgentCwdField: @escaping () -> Void,
        chooseMainAgentDirectory: @escaping () -> Void,
        choosePiBinaryFile: @escaping () -> Void,
        choosePiCodingAgentDirectory: @escaping () -> Void,
        save: @escaping () -> Void,
        refreshModelOptions: @escaping () -> Void,
        directoryField: @escaping (String, Binding<String>, @escaping (String) -> Void, @escaping () -> Void, @escaping () -> Void) -> AnyView,
        @ViewBuilder openAgentsFile: () -> OpenAgentsFile
    ) {
        self.presentation = presentation
        self.modelOptions = modelOptions
        self.isLoadingModelOptions = isLoadingModelOptions
        _mainAgentCwdDraft = mainAgentCwdDraft
        _piBinaryPathDraft = piBinaryPathDraft
        _piCodingAgentDirDraft = piCodingAgentDirDraft
        _mainAgentModelPattern = mainAgentModelPattern
        _mainAgentThinkingLevel = mainAgentThinkingLevel
        _screenContextScope = screenContextScope
        _attachScreenshotsOnlyWhenInked = attachScreenshotsOnlyWhenInked
        _screenshotQuality = screenshotQuality
        _armedPickleDispatchMode = armedPickleDispatchMode
        self.onMainAgentCwdChanged = onMainAgentCwdChanged
        self.onPiBinaryPathChanged = onPiBinaryPathChanged
        self.onPiCodingAgentDirChanged = onPiCodingAgentDirChanged
        self.commitMainAgentCwdField = commitMainAgentCwdField
        self.chooseMainAgentDirectory = chooseMainAgentDirectory
        self.choosePiBinaryFile = choosePiBinaryFile
        self.choosePiCodingAgentDirectory = choosePiCodingAgentDirectory
        self.save = save
        self.refreshModelOptions = refreshModelOptions
        self.directoryField = directoryField
        self.openAgentsFile = openAgentsFile()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesHubCards ? DS.Spacing.space4 : DS.Spacing.space6) {
            settingsGroup(
                "settings.mainAgent.group.workspace",
                summary: "settings.mainAgent.summary.workspace",
                details: [
                    "settings.field.pickyCwd.note",
                    "settings.field.pickyCwd.workspaceWarning",
                    "settings.field.agentsFile.note"
                ]
            ) {
                VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.pickyCwd")
                        directoryField(
                            "~/",
                            $mainAgentCwdDraft,
                            onMainAgentCwdChanged,
                            commitMainAgentCwdField,
                            chooseMainAgentDirectory
                        )
                        standaloneNote("settings.field.pickyCwd.note")
                        if usesHubCards {
                            warning("settings.mainAgent.warning.workspace")
                        } else {
                            warning("settings.field.pickyCwd.workspaceWarning")
                        }
                    }

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.agentsFile")
                        summary("settings.mainAgent.summary.instructions")
                        standaloneNote("settings.field.agentsFile.note")
                        openAgentsFile
                    }
                }
            }

            settingsGroup(
                "settings.mainAgent.group.model",
                summary: "settings.mainAgent.summary.model",
                details: ["settings.field.piModel.helpText"]
            ) {
                VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                    modelPicker

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.reasoningLevel")
                        PickyNativeMenuPicker(
                            title: L10n.t("settings.field.reasoningLevel"),
                            selection: $mainAgentThinkingLevel,
                            options: PickyMainAgentThinkingLevel.allCases.map { .init(value: $0, title: $0.displayName) }
                        )
                        .frame(maxWidth: menuMaximumWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: mainAgentThinkingLevel) { _, _ in save() }
                    }
                }
            }

            settingsGroup(
                "settings.mainAgent.group.context",
                summary: "settings.mainAgent.summary.screenContext",
                details: [
                    "settings.field.attachScreenshotsOnlyWhenInked.note",
                    "settings.field.screenshotQuality.note"
                ]
            ) {
                VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.screenContext")
                        PickyNativeMenuPicker(
                            title: L10n.t("settings.field.screenContext"),
                            selection: $screenContextScope,
                            options: PickyScreenContextScope.allCases.map { .init(value: $0, title: $0.displayName) }
                        )
                        .frame(maxWidth: menuMaximumWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: screenContextScope) { _, _ in save() }
                    }

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        HStack(spacing: DS.Spacing.space2) {
                            Text("settings.field.attachScreenshotsOnlyWhenInked")
                                .font(PickyHUDTypography.labelMedium)
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer(minLength: DS.Spacing.space2)
                            Toggle(
                                "settings.field.attachScreenshotsOnlyWhenInked",
                                isOn: $attachScreenshotsOnlyWhenInked
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(DS.Colors.accent)
                            .controlSize(.small)
                            .onChange(of: attachScreenshotsOnlyWhenInked) { _, _ in save() }
                        }
                        summary("settings.mainAgent.summary.capture")
                        standaloneNote("settings.field.attachScreenshotsOnlyWhenInked.note")
                    }

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.screenshotQuality")
                        PickyNativeMenuPicker(
                            title: L10n.t("settings.field.screenshotQuality"),
                            selection: $screenshotQuality,
                            options: PickyScreenshotQuality.allCases.map { .init(value: $0, title: $0.displayName) }
                        )
                        .frame(maxWidth: menuMaximumWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: screenshotQuality) { _, _ in save() }
                        summary("settings.mainAgent.summary.quality")
                        standaloneNote("settings.field.screenshotQuality.note")
                    }
                }
            }

            settingsGroup(
                "settings.field.armedPickleDispatchMode",
                summary: "settings.mainAgent.summary.dispatch",
                details: ["settings.dispatch.idle.note"]
            ) {
                PickyDispatchModeChoiceView(selection: $armedPickleDispatchMode)
                    .onChange(of: armedPickleDispatchMode) { _, _ in save() }
                standaloneNote("settings.dispatch.idle.note")
            }

            settingsGroup(
                "settings.mainAgent.group.runtime",
                summary: "settings.mainAgent.summary.runtime",
                details: [
                    "settings.field.piBinaryPath.note",
                    "settings.field.piCodingAgentDir.note"
                ]
            ) {
                VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.piBinaryPath")
                        directoryField(
                            L10n.t("settings.field.piBinaryPath.placeholder"),
                            $piBinaryPathDraft,
                            onPiBinaryPathChanged,
                            commitMainAgentCwdField,
                            choosePiBinaryFile
                        )
                        summary("settings.mainAgent.summary.binary")
                        standaloneNote("settings.field.piBinaryPath.note")
                    }

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        fieldLabel("settings.field.piCodingAgentDir")
                        directoryField(
                            L10n.t("settings.field.piCodingAgentDir.placeholder"),
                            $piCodingAgentDirDraft,
                            onPiCodingAgentDirChanged,
                            commitMainAgentCwdField,
                            choosePiCodingAgentDirectory
                        )
                        standaloneNote("settings.field.piCodingAgentDir.note")
                    }
                }
            }
        }
    }

    private var usesHubCards: Bool {
        presentation == .embedded
    }

    // design-token-exception: 320pt popup measure accommodates model/provider names without spanning a Hub card
    private var menuMaximumWidth: CGFloat {
        presentation.showsNavigationChrome ? .infinity : 320
    }

    private var supportingTextColor: Color {
        presentation.showsNavigationChrome ? DS.Colors.textTertiary : PickyHubTheme.Colors.textSecondary
    }

    private var modelPicker: some View {
        let savedValue = mainAgentModelPattern
        let shouldShowSavedOption = !savedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelOptions.contains { $0.pattern == savedValue }
        return VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            HStack(spacing: DS.Spacing.space2) {
                fieldLabel("settings.field.piModel")
                if isLoadingModelOptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
            }
            PickyNativeMenuPicker(
                title: L10n.t("settings.field.piModel"),
                selection: $mainAgentModelPattern,
                options: [PickyNativeMenuOption(value: "", title: L10n.t("settings.field.modelOption.automatic"))]
                    + (shouldShowSavedOption ? [.init(value: savedValue, title: L10n.t("settings.field.modelOption.saved", savedValue))] : [])
                    + modelOptions.map { .init(value: $0.pattern, title: $0.displayName) }
            )
            .frame(maxWidth: menuMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: mainAgentModelPattern) { _, _ in save() }
            .task { refreshModelOptions() }

            if !usesHubCards {
                Text(L10n.t("settings.field.piModel.helpText"))
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(supportingTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: LocalizedStringKey,
        summary: LocalizedStringKey,
        details: [LocalizedStringKey],
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesHubCards {
            VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    Text(title)
                        .font(PickyHUDTypography.title)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(summary)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(supportingTextColor)
                        .lineSpacing(DS.Spacing.space1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content()
                    .lineSpacing(DS.Spacing.space1)

                detailsView(details)
            }
            .padding(DS.Spacing.space5)
            .pickyHubCard(radius: DS.CornerRadius.surface)
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                Text(title)
                    .font(PickyHUDTypography.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                content()
                    .lineSpacing(DS.Spacing.space1)
            }
        }
    }

    @ViewBuilder
    private func summary(_ key: LocalizedStringKey) -> some View {
        if usesHubCards {
            Text(key)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .lineSpacing(DS.Spacing.space1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func standaloneNote(_ key: LocalizedStringKey) -> some View {
        if !usesHubCards {
            Text(key)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .lineSpacing(DS.Spacing.space1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warning(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(PickyHUDTypography.supporting)
            .foregroundColor(DS.Colors.warningText)
            .lineSpacing(DS.Spacing.space1)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func detailsView(_ details: [LocalizedStringKey]) -> some View {
        if !details.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: DS.Spacing.space3) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(supportingTextColor)
                            .lineSpacing(DS.Spacing.space1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, DS.Spacing.space2)
            } label: {
                Text("settings.mainAgent.details")
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
            }
            .disclosureGroupStyle(PickySettingsDisclosureStyle())
            .tint(DS.Colors.accent)
        }
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(presentation.showsNavigationChrome ? PickyHUDTypography.metaSemibold : PickyHUDTypography.labelSemibold)
            .foregroundColor(presentation.showsNavigationChrome ? DS.Colors.textTertiary : PickyHubTheme.Colors.textPrimary)
    }
}

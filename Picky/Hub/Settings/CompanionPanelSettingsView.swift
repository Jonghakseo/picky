//
//  CompanionPanelSettingsView.swift
//  Picky
//
//  Settings controls shared by the companion panel and Hub.
//

import AppKit
import Combine
import SwiftUI

struct CompanionPanelSettingsView: View {
    @Environment(\.pickyHubTypographyEnabled) private var usesHubTypography
    @ObservedObject var viewModel: PickySettingsViewModel
    let companionManager: CompanionManager
    @ObservedObject var mainConversation: PickyMainAgentConversationStore
    /// Archive membership and commands are deliberately narrow so Settings
    /// observes the registry list rather than the global session façade.
    let archiveMembership: any PickySessionArchiveMembership
    let archiveCommands: any PickySessionArchiveCommands
    /// Hub owns page and group headings, so embedded routes keep only their
    /// controls and save/error affordances instead of nesting panel navigation.
    let presentation: CompanionPanelSettingsPresentation
    @State private var mainAgentCwdDraft: String = ""
    @State private var piBinaryPathDraft: String = ""
    @State private var piCodingAgentDirDraft: String = ""
    @State private var pickleCwdDraft: String = ""
    @State private var azureSTTEndpointDraft: String = ""
    @State private var azureSTTAPIKeyDraft: String = ""
    @State private var azureTTSEndpointDraft: String = ""
    @State private var azureTTSAPIKeyDraft: String = ""
    @State private var azureTTSVoiceDraft: String = ""
    @State private var azureLanguageDraft: String = ""
    @State private var openAITTSAPIKeyDraft: String = ""
    @State private var openAITTSVoiceDraft: String = ""
    @State private var openAITTSModelDraft: String = ""
    @State private var openAITTSBaseURLDraft: String = ""
    @State private var openAISTTAPIKeyDraft: String = ""
    @State private var openAISTTModelDraft: String = ""
    @State private var openAISTTLanguageDraft: String = ""
    @State private var openAISTTBaseURLDraft: String = ""
    // ElevenLabs provider drafts.
    @State private var elevenLabsTTSAPIKeyDraft: String = ""
    @State private var elevenLabsTTSVoiceIDDraft: String = ""
    @State private var elevenLabsTTSModelDraft: String = ""
    @State private var elevenLabsTTSOutputFormatDraft: String = ""
    @State private var elevenLabsTTSBaseURLDraft: String = ""
    @State private var elevenLabsSTTAPIKeyDraft: String = ""
    @State private var elevenLabsSTTModelDraft: String = ""
    @State private var elevenLabsSTTLanguageDraft: String = ""
    @State private var groqSTTAPIKeyDraft: String = ""
    @State private var sttVocabularyDraft: String = ""
    @State private var sttConnectionCheck: PickySTTConnectionCheck?
    @StateObject private var oauthLoginController: PickyPiOAuthLoginController
    @StateObject private var edgeTTSVoiceCatalog = EdgeTTSVoiceCatalog()
    @State private var saveStatuses = CompanionPanelSettingsSaveStatuses()
    @State private var saveStatusResets: [CompanionPanelSettingsSection: AnyCancellable] = [:]
    /// Monotonically identifies user edits made after a voice save was
    /// admitted. Its completion must not overwrite those newer private drafts.
    @State private var voiceDraftRevision = 0
    /// Whether the archived-Pickle list at the bottom of the Pickle page is
    /// expanded. Lives as @State so re-opening the panel collapses it again —
    /// archive management is an occasional task, not a persistent setting.
    @State private var isArchivedSessionsExpanded: Bool = false
    @Binding var route: CompanionPanelSettingsRoute

    init(
        viewModel: PickySettingsViewModel,
        companionManager: CompanionManager,
        mainConversation: PickyMainAgentConversationStore,
        archiveMembership: any PickySessionArchiveMembership,
        archiveCommands: any PickySessionArchiveCommands,
        route: Binding<CompanionPanelSettingsRoute>,
        presentation: CompanionPanelSettingsPresentation = .navigation
    ) {
        self.viewModel = viewModel
        self.companionManager = companionManager
        self.mainConversation = mainConversation
        self.archiveMembership = archiveMembership
        self.archiveCommands = archiveCommands
        self.presentation = presentation
        _route = route
        _oauthLoginController = StateObject(
            wrappedValue: PickyPiOAuthLoginController(runner: companionManager.makePiOAuthLoginRunner())
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.showsNavigationChrome {
                navHeader
            }
            content

            if route != .index, let error = viewModel.validationError {
                Text(error)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
                    .padding(.top, 12)
            }
        }
        .animation(.easeOut(duration: 0.16), value: route)
        .onAppear { initializeOwnedState(for: route) }
        // Standalone panel navigation reuses the view; initialize the new route's drafts.
        .onChange(of: route) { _, newRoute in initializeOwnedState(for: newRoute) }
        .onChange(of: viewModel.settings.notifications) { _, _ in
            guard owns(.notifications) else { return }
            saveImmediately(for: .overlayAndNotifications)
        }
        .onChange(of: viewModel.settings.cursor) { _, _ in
            guard owns(.cursor) else { return }
            saveImmediately(for: .overlayAndNotifications)
        }
        .onChange(of: viewModel.settings.overlayBubbles) { _, _ in
            guard owns(.overlayBubbles) else { return }
            saveImmediately(for: .overlayAndNotifications)
        }
        .onChange(of: viewModel.settings.ttsEnabled) { _, _ in
            guard owns(.ttsEnabled) else { return }
            // Only the voice owner may fold its private drafts into settings.
            commitVoiceField()
        }
        .onChange(of: viewModel.settings.disabledBuiltinTools) { _, _ in
            guard owns(.disabledBuiltinTools) else { return }
            saveImmediately(for: .builtinTools)
        }
    }

    /// Hub cards use a different surface palette than the standalone panel.
    /// Explanations are reading content, not disabled metadata.
    // design-token-exception: 320pt popup measure accommodates model/provider names without spanning a Hub card
    private var embeddedMenuMaximumWidth: CGFloat { presentation.showsNavigationChrome ? .infinity : 320 }

    private var supportingTextColor: Color {
        presentation.showsNavigationChrome ? DS.Colors.textTertiary : PickyHubTheme.Colors.textSecondary
    }

    private func owns(_ observedSetting: CompanionPanelSettingsObservedSetting) -> Bool {
        CompanionPanelSettingsOwnership.owns(
            observedSetting,
            on: route,
            presentation: presentation
        )
    }

    private func initializeOwnedState(for route: CompanionPanelSettingsRoute) {
        for owner in CompanionPanelSettingsOwnership.draftOwners(for: route) {
            switch owner {
            case .mainAgent:
                mainAgentCwdDraft = viewModel.settings.mainAgentCwd
                piBinaryPathDraft = viewModel.settings.piBinaryPath
                piCodingAgentDirDraft = viewModel.settings.piCodingAgentDir
            case .oauth:
                oauthLoginController.refreshAll()
            case .pickle:
                pickleCwdDraft = viewModel.settings.defaultCwd
            case .voice:
                syncVoiceDrafts()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .index: indexView
        case .general: generalSection
        case .oauth: oauthSection
        case .mainAgent: mainAgentSection
        case .pickle: pickleSection
        case .overlayAndNotifications: overlayAndNotificationsSection
        case .voice: voiceSection
        case .shortcuts: shortcutsSection
        case .builtinTools: builtinToolsSection
        }
    }

    @ViewBuilder
    private var navHeader: some View {
        if route != .index {
            HStack(spacing: 8) {
                Button(action: { route = .index }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(PickyHUDTypography.statusSemibold)
                        Text(L10n.t("tab.settings"))
                            .font(PickyHUDTypography.labelMedium)
                    }
                    .foregroundColor(supportingTextColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverAffordance()

                Spacer(minLength: 6)
            }
            .padding(.bottom, 8)
        }
    }

    private var indexView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            ForEach(companionPanelSettingsGroups) { group in
                indexGroupHeader(group)
                ForEach(Array(group.routes.enumerated()), id: \.element) { rowIndex, item in
                    indexRow(for: item)
                    if rowIndex < group.routes.count - 1 {
                        Divider()
                            .background(DS.Colors.borderSubtle.opacity(0.3))
                    }
                }
            }
        }
    }

    private func indexGroupHeader(_ group: CompanionPanelSettingsGroup) -> some View {
        Text(group.titleKey)
            .font(PickyHUDTypography.minimumSemibold)
            .foregroundColor(supportingTextColor)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .padding(.leading, 2)
    }

    /// Single tappable row on the Settings index. Subtitle prefers the live
    /// summary built from the current settings (so the user can recognise the
    /// state without drilling in) and falls back to the route's static blurb
    /// when no summary is meaningful.
    private func indexRow(for item: CompanionPanelSettingsRoute) -> some View {
        Button(action: { route = item }) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    Text(item.title)
                        .font(PickyHUDTypography.bodyCompactSemibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    if let subtitle = indexSubtitle(for: item) {
                        Text(subtitle)
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(supportingTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let section = item.section {
                    statusIndicator(for: section)
                }
                Image(systemName: "chevron.right")
                    .font(PickyHUDTypography.minimumSemibold)
                    .foregroundColor(supportingTextColor)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAffordance()
    }

    /// Resolves the subtitle text shown under each index row. Live summaries
    /// win over the static description so the index always reflects the
    /// user's current configuration.
    private func indexSubtitle(for route: CompanionPanelSettingsRoute) -> String? {
        if let summary = indexSummary(for: route), !summary.isEmpty {
            return summary
        }
        return route.subtitle
    }

    /// Short value-summary for each route, built from the live view-model so
    /// the index doubles as a status overview. Returns `nil` for routes where
    /// no compact summary exists; the caller then falls back to the static
    /// subtitle.
    private func indexSummary(for route: CompanionPanelSettingsRoute) -> String? {
        let settings = viewModel.settings
        switch route {
        case .index:
            return nil
        case .general:
            return L10n.t(settings.appLanguage.displayKey)
        case .oauth:
            return oauthLoginController.indexSummary
        case .shortcuts:
            let ptt = settings.pushToTalkShortcut.summaryString
            let qi = settings.quickInputShortcut.summaryString
            let focus = settings.focusPickleShortcut.summaryString
            return L10n.t("settings.summary.shortcuts", ptt, qi, focus)
        case .mainAgent:
            return indexModelLabel(settings.mainAgentModelPattern)
        case .pickle:
            return indexModelLabel(settings.pickleAgentModelPattern)
        case .builtinTools:
            let total = PickyBuiltinTool.allCases.count
            let enabled = total - settings.disabledBuiltinTools.count
            return L10n.t("settings.summary.tools", enabled, total)
        case .voice:
            let stt = settings.sttProvider.displayName(for: .transcription)
            let tts: String = settings.ttsEnabled
                ? settings.ttsProvider.displayName(for: .speechPlayback)
                : L10n.t("settings.summary.off")
            return L10n.t("settings.summary.voice", stt, tts)
        case .overlayAndNotifications:
            let cursor = settings.cursor.showPiCursor
                ? L10n.t("settings.summary.cursorOn")
                : L10n.t("settings.summary.cursorOff")
            let n = settings.notifications
            let alertsOn = [
                n.notifyMainOnCompletionForNewPickles,
                n.notifyMacOSOnCompletionForNewPickles,
                n.notifyOnFailed,
                n.notifyOnWaitingForInput,
            ].filter { $0 }.count
            return L10n.t("settings.summary.overlayAndNotifications", cursor, alertsOn, 4)
        }
    }

    private func indexModelLabel(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.t("settings.summary.auto") : trimmed
    }

    private var pickleSection: some View {
        sectionHeader(
            section: .pickle,
            title: L10n.t("settings.section.pickle.title"),
            subtitle: L10n.t("settings.section.pickle.subtitle")
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    fieldLabel("settings.field.defaultCwd")
                    cwdField(
                        placeholder: "~/",
                        text: $pickleCwdDraft,
                        onChange: { newValue in
                            updateDraftStatus(for: .pickle, isDirty: newValue != viewModel.settings.defaultCwd)
                        },
                        onSubmit: commitPickleCwdField,
                        onChoose: choosePickleDirectory
                    )
                }

                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))

                pickleModelPicker

                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    fieldLabel("settings.field.reasoningLevel")
                    PickyNativeMenuPicker(
                        title: L10n.t("settings.field.reasoningLevel"),
                        selection: $viewModel.settings.pickleAgentThinkingLevel,
                        options: PickyPickleAgentThinkingLevel.allCases.map { .init(value: $0, title: $0.displayName) }
                    )
                    .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.settings.pickleAgentThinkingLevel) { _, _ in saveImmediately(for: .pickle) }
                    Text("settings.field.reasoningLevel.pickleNote")
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(supportingTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .pickyHubSelectableText()
                }

                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))

                gitChipActionsGroup

                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))

                archivedPickleAutoDeleteToggle

                if !archiveMembership.archivedSessionIDs.isEmpty {
                    Divider()
                        .background(DS.Colors.borderSubtle.opacity(0.3))

                    archivedSessionsDisclosure
                }
            }
        }
    }

    /// agentd reads this on its next launch, which is also when the purge runs.
    private var archivedPickleAutoDeleteToggle: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            toggleRow(
                "settings.pickle.archiveAutoDelete.toggle",
                isOn: $viewModel.settings.archivedPickleAutoDeleteEnabled,
                divider: false
            )
            .onChange(of: viewModel.settings.archivedPickleAutoDeleteEnabled) { _, _ in saveImmediately(for: .pickle) }
            Text("settings.pickle.archiveAutoDelete.note")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
        }
    }

    /// Footer disclosure on the Pickle settings page. Collapsed by default so
    /// the page reads as settings; the archive list only renders when the user
    /// asks for it. Hidden entirely when there is nothing to manage so the
    /// settings page does not carry an empty data section.
    private var archivedSessionsDisclosure: some View {
        DisclosureGroup(isExpanded: $isArchivedSessionsExpanded) {
            PickyHUDArchivedSessionsListView(
                archiveMembership: archiveMembership,
                commands: archiveCommands,
                showsHeader: false
            )
        } label: {
            HStack(spacing: DS.Spacing.space2) {
                Text("settings.pickle.archive.toggle")
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("\(archiveMembership.archivedSessionIDs.count)")
                    .font(PickyHUDTypography.metaMedium)
                    .foregroundColor(supportingTextColor)
            }
        }
        .disclosureGroupStyle(PickySettingsDisclosureStyle())
    }

    private var gitChipActionsGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            fieldLabel("settings.pickle.gitChipActions.title")
            gitChipActionEditor(
                label: "settings.pickle.gitChipActions.diffLabel",
                action: gitChipDiffBinding
            )
            gitChipActionEditor(
                label: "settings.pickle.gitChipActions.branchLabel",
                action: gitChipBranchBinding
            )
        }
    }

    /// Single slot editor: kind picker + command text field. Empty command
    /// stays as `nil` in the source-of-truth binding so the chip click handler
    /// can tell "unconfigured" from "empty draft about to be filled".
    @ViewBuilder
    private func gitChipActionEditor(
        label: String,
        action: Binding<PickyGitChipAction?>
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(LocalizedStringKey(label))
            if presentation.showsNavigationChrome {
                gitChipKindSegment(label: label, action: action)
                gitChipCommandField(action: action)
            } else {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    gitChipCommandField(action: action)
                    PickyHubMenuPicker(
                        title: L10n.t(label),
                        selection: gitChipKindBinding(action),
                        options: [
                            .init(value: .pi, title: L10n.t("settings.pickle.gitChipActions.kindPi")),
                            .init(value: .shell, title: L10n.t("settings.pickle.gitChipActions.kindShell")),
                        ]
                    )
                    .frame(width: 112)
                }
            }
        }
    }

    private func gitChipKindSegment(label: String, action: Binding<PickyGitChipAction?>) -> some View {
        Picker(L10n.t(label), selection: gitChipKindBinding(action)) {
            Text("settings.pickle.gitChipActions.kindPi").tag(PickyGitChipActionKind.pi)
            Text("settings.pickle.gitChipActions.kindShell").tag(PickyGitChipActionKind.shell)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
    }

    private func gitChipCommandField(action: Binding<PickyGitChipAction?>) -> some View {
        TextField(
            "settings.pickle.gitChipActions.commandPlaceholder",
            text: gitChipCommandBinding(action)
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(presentation.showsNavigationChrome ? .small : .regular)
        .onSubmit { saveImmediately(for: .pickle) }
    }

    private var gitChipDiffBinding: Binding<PickyGitChipAction?> {
        Binding(
            get: { viewModel.settings.gitChipActions.diffAction },
            set: { newValue in
                viewModel.settings.gitChipActions.diffAction = newValue
                saveImmediately(for: .pickle)
            }
        )
    }

    private var gitChipBranchBinding: Binding<PickyGitChipAction?> {
        Binding(
            get: { viewModel.settings.gitChipActions.branchAction },
            set: { newValue in
                viewModel.settings.gitChipActions.branchAction = newValue
                saveImmediately(for: .pickle)
            }
        )
    }

    /// Kind picker writes through to the slot binding, defaulting to `.pi`
    /// when the slot was previously nil (the user is starting to configure a
    /// brand new action).
    private func gitChipKindBinding(_ action: Binding<PickyGitChipAction?>) -> Binding<PickyGitChipActionKind> {
        Binding(
            get: { action.wrappedValue?.kind ?? .pi },
            set: { newKind in
                if var current = action.wrappedValue {
                    current.kind = newKind
                    action.wrappedValue = current
                } else {
                    action.wrappedValue = PickyGitChipAction(kind: newKind, command: "")
                }
            }
        )
    }

    /// Command field writes through to the slot binding. Empty text leaves
    /// the slot in place with whatever kind was selected so the picker does
    /// not flicker back to ".pi" while the user is still editing. The chip
    /// click handler treats empty `command` as "not configured" via
    /// `PickyGitChipAction.isConfigured`, so persisting `{kind, command: ""}`
    /// is safe.
    private func gitChipCommandBinding(_ action: Binding<PickyGitChipAction?>) -> Binding<String> {
        Binding(
            get: { action.wrappedValue?.command ?? "" },
            set: { newValue in
                if var current = action.wrappedValue {
                    current.command = newValue
                    action.wrappedValue = current
                } else {
                    action.wrappedValue = PickyGitChipAction(kind: .pi, command: newValue)
                }
            }
        )
    }

    /// Combined page that replaced the standalone `cursorBubblesSection` and
    /// `notificationSection`. The three logical buckets (cursor visuals,
    /// speech bubbles, macOS banners) stay distinguishable through small
    /// subgroup headers — reusing the same style the Voice section uses for
    /// STT vs TTS so the panel feels consistent.
    private var overlayAndNotificationsSection: some View {
        sectionHeader(
            section: .overlayAndNotifications,
            title: L10n.t("settings.section.overlayAndNotifications.title"),
            subtitle: L10n.t("settings.section.overlayAndNotifications.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    voiceSubgroupHeader("settings.overlayAndNotifications.subgroup.cursor")
                    toggleRow("settings.cursorBubbles.toggle.showCursor", isOn: $viewModel.settings.cursor.showPiCursor, divider: true)
                    toggleRow(
                        "settings.cursorBubbles.toggle.smoothFollow",
                        isOn: $viewModel.settings.cursor.enableFollowSpringAnimation,
                        divider: true,
                        isEnabled: viewModel.settings.cursor.showPiCursor
                    )
                    toggleRow(
                        "settings.cursorBubbles.toggle.idleAnimations",
                        isOn: $viewModel.settings.cursor.enableIdleAnimations,
                        divider: false,
                        isEnabled: viewModel.settings.cursor.showPiCursor
                    )
                    if !viewModel.settings.cursor.showPiCursor {
                        Text("settings.cursor.disabledNote")
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(supportingTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .pickyHubSelectableText()
                            .padding(.top, 7)
                    }
                }

                voiceGroupDivider()

                VStack(alignment: .leading, spacing: 0) {
                    voiceSubgroupHeader("settings.overlayAndNotifications.subgroup.bubbles")
                    toggleRow(
                        "settings.cursorBubbles.toggle.userSTT",
                        isOn: $viewModel.settings.overlayBubbles.showUserSpeechRecognitionBubble,
                        divider: true
                    )
                    toggleRow(
                        "settings.cursorBubbles.toggle.pickyReply",
                        isOn: $viewModel.settings.overlayBubbles.showPickyResponseBubble,
                        divider: false
                    )
                }

                if presentation.includesOverlayNotificationControls {
                    voiceGroupDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        voiceSubgroupHeader("settings.overlayAndNotifications.subgroup.alerts")
                        toggleRow(
                            "settings.notification.toggle.newPicklesMain",
                            isOn: $viewModel.settings.notifications.notifyMainOnCompletionForNewPickles,
                            divider: true
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            toggleRow(
                                "settings.notification.toggle.newPicklesMacOS",
                                isOn: $viewModel.settings.notifications.notifyMacOSOnCompletionForNewPickles,
                                divider: false
                            )
                            Text("settings.notification.toggle.newPickles.note")
                                .font(PickyHUDTypography.supporting)
                                .foregroundColor(supportingTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .pickyHubSelectableText()
                                .padding(.bottom, DS.Spacing.space2)
                            Divider()
                                .background(DS.Colors.borderSubtle.opacity(0.3))
                        }
                        toggleRow("settings.notification.toggle.onFailure", isOn: $viewModel.settings.notifications.notifyOnFailed, divider: true)
                        toggleRow("settings.notification.toggle.onInputRequest", isOn: $viewModel.settings.notifications.notifyOnWaitingForInput, divider: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mainAgentSection: some View {
        if usesHubMainAgentCards {
            mainAgentSettingsContent
            embeddedSaveStatus(for: .mainAgent)
        } else {
            sectionHeader(
                section: .mainAgent,
                title: L10n.t("settings.section.picky.title"),
                subtitle: L10n.t("settings.section.picky.subtitle")
            ) {
                mainAgentSettingsContent
            }
        }
    }

    private var usesHubMainAgentCards: Bool {
        presentation == .embedded
    }

    private var mainAgentSettingsContent: some View {
        PickyMainAgentSettingsContent(
            presentation: presentation,
            modelOptions: mainConversation.modelOptions,
            isLoadingModelOptions: mainConversation.isLoadingModelOptions,
            automaticTaskModels: mainConversation.automaticTaskModels,
            mainAgentCwdDraft: $mainAgentCwdDraft,
            piBinaryPathDraft: $piBinaryPathDraft,
            piCodingAgentDirDraft: $piCodingAgentDirDraft,
            settings: $viewModel.settings,
            onMainAgentCwdChanged: { newValue in
                updateDraftStatus(for: .mainAgent, isDirty: isMainAgentDraftDirty(mainAgentCwd: newValue))
            },
            onPiBinaryPathChanged: { newValue in
                updateDraftStatus(for: .mainAgent, isDirty: isMainAgentDraftDirty(piBinaryPath: newValue))
            },
            onPiCodingAgentDirChanged: { newValue in
                updateDraftStatus(for: .mainAgent, isDirty: isMainAgentDraftDirty(piCodingAgentDir: newValue))
            },
            commitMainAgentCwdField: commitMainAgentCwdField,
            chooseMainAgentDirectory: chooseMainAgentDirectory,
            choosePiBinaryFile: choosePiBinaryFile,
            choosePiCodingAgentDirectory: choosePiCodingAgentDirectory,
            save: { saveImmediately(for: .mainAgent) },
            refreshModelOptions: { companionManager.refreshMainAgentModelOptions() },
            directoryField: { placeholder, text, onChange, onSubmit, onChoose in
                AnyView(cwdField(
                    placeholder: placeholder,
                    text: text,
                    onChange: onChange,
                    onSubmit: onSubmit,
                    onChoose: onChoose
                ))
            }
        ) {
            openAgentsFileButton
        }
    }

    @ViewBuilder
    private func embeddedSaveStatus(for section: CompanionPanelSettingsSection) -> some View {
        if saveStatuses[section] != .idle {
            HStack {
                Spacer(minLength: 0)
                statusIndicator(for: section)
            }
        }
    }

    private var pickleModelPicker: some View {
        modelPicker(
            label: "settings.field.pickleModel",
            selection: $viewModel.settings.pickleAgentModelPattern,
            shouldShowSavedOption: shouldShowSavedPickleModelOption,
            savedValue: viewModel.settings.pickleAgentModelPattern,
            onSave: { saveImmediately(for: .pickle) },
            helpText: L10n.t("settings.field.pickleModel.helpText")
        )
    }

    private func modelPicker(
        label: String,
        selection: Binding<String>,
        shouldShowSavedOption: Bool,
        savedValue: String,
        onSave: @escaping () -> Void,
        helpText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            HStack(spacing: DS.Spacing.space2) {
                fieldLabel(LocalizedStringKey(label))
                if mainConversation.isLoadingModelOptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
            }
            PickyNativeMenuPicker(
                title: L10n.t(label),
                selection: selection,
                options: [PickyNativeMenuOption(value: "", title: L10n.t("settings.field.modelOption.automatic"))]
                    + (shouldShowSavedOption ? [.init(value: savedValue, title: L10n.t("settings.field.modelOption.saved", savedValue))] : [])
                    + mainConversation.modelOptions.map { .init(value: $0.pattern, title: $0.displayName) }
            )
            .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selection.wrappedValue) { _, _ in onSave() }
            .task { companionManager.refreshMainAgentModelOptions() }

            Text(helpText)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
        }
    }

    private var shouldShowSavedPickleModelOption: Bool {
        let saved = viewModel.settings.pickleAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return false }
        return !mainConversation.modelOptions.contains { $0.pattern == saved }
    }

    private var shortcutsSection: some View {
        sectionHeader(
            section: .shortcuts,
            title: L10n.t("settings.section.shortcuts.title"),
            subtitle: L10n.t("settings.section.shortcuts.subtitle")
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                ShortcutSettingsRow(
                    title: L10n.t("settings.shortcuts.pushToTalk.title"),
                    subtitle: L10n.t("settings.shortcuts.pushToTalk.subtitle"),
                    allowance: .pushToTalk,
                    currentSpec: viewModel.settings.pushToTalkShortcut
                ) { newSpec in
                    saveShortcut(newSpec, role: .pushToTalk)
                }

                ShortcutSettingsRow(
                    title: L10n.t("settings.shortcuts.quickInput.title"),
                    subtitle: L10n.t("settings.shortcuts.quickInput.subtitle"),
                    allowance: .quickInput,
                    currentSpec: viewModel.settings.quickInputShortcut
                ) { newSpec in
                    saveShortcut(newSpec, role: .quickInput)
                }

                ShortcutSettingsRow(
                    title: L10n.t("settings.shortcuts.focusPickle.title"),
                    subtitle: L10n.t("settings.shortcuts.focusPickle.subtitle"),
                    allowance: .focusPickle,
                    currentSpec: viewModel.settings.focusPickleShortcut
                ) { newSpec in
                    saveShortcut(newSpec, role: .focusPickle)
                }

                Button(action: resetShortcutsToDefaults) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(PickyHUDTypography.minimumSemibold)
                        Text("common.resetDefaults")
                            .font(PickyHUDTypography.statusSemibold)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, DS.Spacing.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface1.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .hoverAffordance()
            }
        }
    }

    private var generalSection: some View {
        sectionHeader(
            section: .general,
            title: L10n.t("settings.general.title"),
            subtitle: L10n.t("settings.general.subtitle.section")
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    fieldLabel("settings.general.language.label")
                    PickyNativeMenuPicker(
                        title: L10n.t("settings.general.language.label"),
                        selection: $viewModel.settings.appLanguage,
                        options: PickyLanguage.allCases.map {
                            .init(value: $0, title: L10n.t($0.displayKey))
                        }
                    )
                    .fixedSize(horizontal: !presentation.showsNavigationChrome, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.settings.appLanguage) { _, newValue in
                        // Two effects: persist via saveImmediately (the
                        // settings observer in PickyApp will pick the change
                        // up and call LocaleManager.apply too), and apply
                        // locally so the picker label itself retranslates
                        // without waiting for the disk round-trip.
                        LocaleManager.shared.apply(newValue)
                        saveImmediately(for: .general)
                    }

                    Text("settings.general.language.note")
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(supportingTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .pickyHubSelectableText()
                }

                if presentation.includesShellCommandControl {
                    pickyShellCommandSubsection
                }
            }
        }
    }

    private var oauthSection: some View {
        sectionHeader(
            section: .oauth,
            title: L10n.t("settings.oauth.title"),
            subtitle: L10n.t("settings.oauth.subtitle.section")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.oauth.body")
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundColor(supportingTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(PickyPiOAuthLoginProvider.allCases) { provider in
                        oauthProviderRow(provider)
                    }
                }

                Button(action: { oauthLoginController.refreshAll() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(PickyHUDTypography.minimumSemibold)
                        Text("settings.oauth.refresh")
                            .font(PickyHUDTypography.statusSemibold)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Spacing.space3)
                    .padding(.vertical, DS.Spacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface1.opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .hoverAffordance()

                Text("settings.oauth.fallback")
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(supportingTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
            }
        }
    }

    private func oauthProviderRow(_ provider: PickyPiOAuthLoginProvider) -> some View {
        PickySettingsOAuthProviderRow(
            controller: oauthLoginController,
            provider: provider,
            supportingTextColor: supportingTextColor
        )
        .padding(10)
        .alert(
            L10n.t("settings.oauth.disconnect.confirmation.title"),
            isPresented: Binding(
                get: { oauthLoginController.pendingSignOutProvider == provider },
                set: { isPresented in
                    if !isPresented { oauthLoginController.cancelSignOutConfirmation() }
                }
            )
        ) {
            Button("settings.oauth.cancel", role: .cancel) {
                oauthLoginController.cancelSignOutConfirmation()
            }
            Button("settings.oauth.disconnect", role: .destructive) {
                oauthLoginController.confirmSignOut(provider: provider)
            }
        } message: {
            Text("settings.oauth.disconnect.confirmation.message")
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.5)
                )
        )
    }

    /// Settings entry that lets the user install or uninstall the `picky`
    /// shell command. Lives in General because Picky is an LSUIElement app
    /// whose panels never activate the macOS top menu bar, so a normal
    /// "Install Shell Command…" menu item would never be visible.
    private var pickyShellCommandSubsection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel("settings.general.shellCommand.label")

            Button(action: {
                ShellCommandMenuController.shared.showInstallerAlert()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(PickyHUDTypography.minimumSemibold)
                    Text("settings.general.shellCommand.button")
                        .font(PickyHUDTypography.statusSemibold)
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, DS.Spacing.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .hoverAffordance()

            Text("settings.general.shellCommand.note")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
        }
    }

    private var builtinToolsSection: some View {
        sectionHeader(section: .builtinTools, title: L10n.t("settings.section.builtinTools.title"), subtitle: L10n.t("settings.section.builtinTools.subtitle")) {
            VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                Text("settings.section.builtinTools.note")
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundColor(supportingTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()

                VStack(spacing: 0) {
                    let tools = PickyBuiltinTool.allCases
                    ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                        builtinToolRow(tool: tool, divider: index != tools.count - 1)
                    }
                }
            }
        }
    }

    private func builtinToolRow(tool: PickyBuiltinTool, divider: Bool) -> some View {
        let binding = Binding<Bool>(
            get: { !viewModel.settings.disabledBuiltinTools.contains(tool) },
            set: { enabled in
                if enabled {
                    viewModel.settings.disabledBuiltinTools.remove(tool)
                } else {
                    viewModel.settings.disabledBuiltinTools.insert(tool)
                }
            }
        )
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    Text(L10n.t(tool.displayNameKey))
                        .font(PickyHUDTypography.labelSemibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(L10n.t(tool.descriptionKey))
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(supportingTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .pickyHubSelectableText()
                    Text(verbatim: tool.rawValue)
                        .font(PickyHUDTypography.supportingMonospaced)
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
                        .pickyHubSelectableText()
                }
                Spacer(minLength: 8)
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .controlSize(.small)
            }
            .padding(.vertical, 8)

            if divider {
                Divider().background(DS.Colors.borderSubtle.opacity(0.3))
            }
        }
    }

    private var voiceSection: some View {
        sectionHeader(
            section: .voice,
            title: L10n.t("settings.section.voice.title"),
            subtitle: L10n.t("settings.section.voice.subtitle")
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                // ─── STT group ───
                VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                    voiceSubgroupHeader("settings.voice.subgroup.stt")

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        providerPicker(title: "settings.voice.provider.stt", capability: .transcription, selection: $viewModel.settings.sttProvider)
                        if let noteKey = PickySTTProviderNote.key(for: viewModel.settings.sttProvider) {
                            Text(LocalizedStringKey(noteKey))
                                .font(PickyHUDTypography.supporting)
                                .foregroundColor(supportingTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .pickyHubSelectableText()
                        }
                    }

                    if viewModel.settings.sttProvider == .local {
                        PickySTTSwitchToGroqView {
                            viewModel.settings.sttProvider = .groq
                        }
                    }

                    if viewModel.settings.sttProvider == .groq {
                        sttKeySection(
                            provider: .groq,
                            label: "settings.voice.stt.apiKey",
                            placeholder: "gsk_…",
                            text: $groqSTTAPIKeyDraft
                        )
                        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                            fieldLabel("settings.voice.stt.model")
                            PickyGroqModelChoiceView(modelName: groqModelBinding)
                        }
                        groqLanguagePicker
                    }

                    if viewModel.settings.sttProvider == .azure {
                        azureTextField(
                            label: "settings.voice.azure.stt.url",
                            placeholder: "{endpoint}/openai/deployments/{deploymentName}/audio/transcriptions?api-version={apiVersion}",
                            text: $azureSTTEndpointDraft
                        )
                        azureSecureField(
                            label: "settings.voice.azure.stt.apiKey",
                            placeholder: L10n.t("settings.voice.azure.stt.apiKey.placeholder"),
                            text: $azureSTTAPIKeyDraft
                        )
                        azureTextField(
                            label: "settings.voice.azure.stt.language",
                            placeholder: L10n.t("settings.voice.placeholder.languageAuto"),
                            text: $azureLanguageDraft
                        )
                    }

                    if viewModel.settings.sttProvider == .openai {
                        sttKeySection(
                            provider: .openai,
                            label: "settings.voice.openai.stt.apiKey",
                            placeholder: "sk-…",
                            text: $openAISTTAPIKeyDraft
                        )
                        voiceTextField(
                            label: "settings.voice.openai.stt.model",
                            placeholder: L10n.t("settings.voice.openai.stt.model.placeholder"),
                            text: $openAISTTModelDraft
                        )
                        voiceTextField(
                            label: "settings.voice.openai.stt.language",
                            placeholder: L10n.t("settings.voice.placeholder.languageAuto"),
                            text: $openAISTTLanguageDraft
                        )
                        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                            voiceTextField(
                                label: "settings.voice.openai.stt.baseUrl",
                                placeholder: L10n.t("settings.voice.openai.stt.baseUrl.placeholder"),
                                text: $openAISTTBaseURLDraft
                            )

                            Text("settings.voice.openaiBaseUrlNote")
                                .font(PickyHUDTypography.supporting)
                                .foregroundColor(supportingTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .pickyHubSelectableText()
                        }
                    }

                    if viewModel.settings.sttProvider == .elevenLabs {
                        voiceSecureField(
                            label: "settings.voice.elevenlabs.stt.apiKey",
                            placeholder: L10n.t("settings.voice.elevenlabs.stt.apiKey.placeholder"),
                            text: $elevenLabsSTTAPIKeyDraft
                        )
                        voiceTextField(
                            label: "settings.voice.elevenlabs.stt.model",
                            placeholder: L10n.t("settings.voice.elevenlabs.stt.model.placeholder"),
                            text: $elevenLabsSTTModelDraft
                        )
                        voiceTextField(
                            label: "settings.voice.elevenlabs.stt.language",
                            placeholder: L10n.t("settings.voice.placeholder.languageAutoElevenLabs"),
                            text: $elevenLabsSTTLanguageDraft
                        )
                    }

                    if [.groq, .openai, .azure].contains(viewModel.settings.sttProvider) {
                        sttVocabularySection
                    }
                }

                voiceGroupDivider()

                // ─── TTS group ───
                VStack(alignment: .leading, spacing: DS.Spacing.space4) {
                    voiceSubgroupHeader("settings.voice.subgroup.tts")

                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        toggleRow("settings.voice.toggle.ttsEnabled", isOn: $viewModel.settings.ttsEnabled, divider: false)
                        Text("settings.tts.disabledNote")
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(supportingTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .pickyHubSelectableText()
                    }

                    providerPicker(title: "settings.voice.provider.tts", capability: .speechPlayback, selection: $viewModel.settings.ttsProvider, isEnabled: viewModel.settings.ttsEnabled)

                    if viewModel.settings.ttsEnabled,
                       viewModel.settings.ttsProvider == .local {
                        openMacOSSpeechSettingsButton
                    }

                    if viewModel.settings.ttsEnabled, viewModel.settings.ttsProvider == .edge {
                        edgeTTSSettings
                            .task { edgeTTSVoiceCatalog.refresh() }
                    }

                    if viewModel.settings.ttsEnabled, viewModel.settings.ttsProvider == .azure {
                        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                            azureTextField(
                                label: "settings.voice.azure.tts.url",
                                placeholder: "{endpoint}/openai/deployments/{deploymentName}/audio/speech?api-version={apiVersion}",
                                text: $azureTTSEndpointDraft
                            )

                            Text("settings.azure.ttsUrlNote")
                                .font(PickyHUDTypography.supporting)
                                .foregroundColor(supportingTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .pickyHubSelectableText()
                        }
                        azureSecureField(
                            label: "settings.voice.azure.tts.apiKey",
                            placeholder: L10n.t("settings.voice.azure.tts.apiKey.placeholder"),
                            text: $azureTTSAPIKeyDraft
                        )
                        azureTextField(
                            label: "settings.voice.azure.tts.voice",
                            placeholder: L10n.t("settings.voice.azure.tts.voice.placeholder"),
                            text: $azureTTSVoiceDraft
                        )
                    }

                    if viewModel.settings.ttsEnabled, viewModel.settings.ttsProvider == .openai {
                        voiceSecureField(
                            label: "settings.voice.openai.tts.apiKey",
                            placeholder: L10n.t("settings.voice.openai.tts.apiKey.placeholder"),
                            text: $openAITTSAPIKeyDraft
                        )
                        voiceTextField(
                            label: "settings.voice.openai.tts.voice",
                            placeholder: "alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse, marin, cedar",
                            text: $openAITTSVoiceDraft
                        )
                        voiceTextField(
                            label: "settings.voice.openai.tts.model",
                            placeholder: L10n.t("settings.voice.openai.tts.model.placeholder"),
                            text: $openAITTSModelDraft
                        )
                        voiceTextField(
                            label: "settings.voice.openai.tts.baseUrl",
                            placeholder: L10n.t("settings.voice.openai.tts.baseUrl.placeholder"),
                            text: $openAITTSBaseURLDraft
                        )
                    }

                    if viewModel.settings.ttsEnabled, viewModel.settings.ttsProvider == .elevenLabs {
                        voiceSecureField(
                            label: "settings.voice.elevenlabs.tts.apiKey",
                            placeholder: L10n.t("settings.voice.elevenlabs.tts.apiKey.placeholder"),
                            text: $elevenLabsTTSAPIKeyDraft
                        )
                        voiceTextField(
                            label: "settings.voice.elevenlabs.tts.voiceId",
                            placeholder: L10n.t("settings.voice.elevenlabs.tts.voiceId.placeholder"),
                            text: $elevenLabsTTSVoiceIDDraft
                        )
                        voiceTextField(
                            label: "settings.voice.elevenlabs.tts.model",
                            placeholder: L10n.t("settings.voice.elevenlabs.tts.model.placeholder"),
                            text: $elevenLabsTTSModelDraft
                        )
                        voiceTextField(
                            label: "settings.voice.elevenlabs.tts.outputFormat",
                            placeholder: L10n.t("settings.voice.elevenlabs.tts.outputFormat.placeholder"),
                            text: $elevenLabsTTSOutputFormatDraft
                        )
                        voiceTextField(
                            label: "settings.voice.elevenlabs.tts.baseUrl",
                            placeholder: L10n.t("settings.voice.elevenlabs.tts.baseUrl.placeholder"),
                            text: $elevenLabsTTSBaseURLDraft
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader<Content: View>(
        section: CompanionPanelSettingsSection,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            if presentation.showsSectionChrome {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
                        Text(title)
                            .font(PickyHUDTypography.statusSemibold)
                            .foregroundColor(DS.Colors.textSecondary)
                            .textCase(.uppercase)
                            .tracking(0.4)

                        Spacer(minLength: DS.Spacing.space2)

                        statusIndicator(for: section)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(supportingTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !presentation.showsSectionChrome, section != .general, presentation != .embeddedOverlayControls {
                Text(title)
                    .font(PickyHUDTypography.title)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            content()

            // Text and credential drafts retain their local durable Save action
            // when the Hub suppresses the panel section heading.
            if !presentation.showsSectionChrome, saveStatuses[section] != .idle {
                HStack {
                    Spacer(minLength: 0)
                    statusIndicator(for: section)
                }
            }
        }
    }

    /// Inline autosave indicator. Only renders one of the three states at a time so
    /// section headers stay quiet when nothing has changed. The `.dirty` state renders
    /// as a distinct action pill so it is not confused with the passive `Saved` label.
    @ViewBuilder
    private func statusIndicator(for section: CompanionPanelSettingsSection) -> some View {
        switch saveStatuses[section] {
        case .idle:
            EmptyView()
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(PickyHUDTypography.minimumSemibold)
                    .foregroundColor(DS.Colors.successText)
                Text("common.saved")
                    .font(PickyHUDTypography.minimumMedium)
                    .foregroundColor(DS.Colors.successText)
            }
        case .dirty:
            Button(action: { commitEdits(in: section) }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(PickyHUDTypography.minimumSemibold)
                    Text("common.save")
                        .font(usesHubTypography ? PickyHUDTypography.metaMedium : PickyHUDTypography.metaBold)
                }
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accentText.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.accentText.opacity(0.38), lineWidth: 0.7)
                        )
                )
            }
            .buttonStyle(.plain)
            .hoverAffordance()
        }
    }

    private func azureTextField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.supportingMonospacedMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, DS.Spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    voiceDraftDidChange()
                }
                .onSubmit { commitVoiceField() }
        }
    }

    private func azureSecureField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(label)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.supportingMonospacedMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, DS.Spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    voiceDraftDidChange()
                }
                .onSubmit { commitVoiceField() }
        }
    }

    // MARK: Speech recognition helpers

    private func sttKeySection(
        provider: PickySTTKeyProvider,
        label: LocalizedStringKey,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        let check = sttConnectionCheck.flatMap { $0.applies(to: provider, apiKey: text.wrappedValue) ? $0 : nil }
        let hasKey = !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(label)
            HStack(spacing: DS.Spacing.space2) {
                voiceSecureInput(placeholder: placeholder, text: text, isInvalid: check?.phase == .finished(.invalidKey))
                    .frame(maxWidth: 420)
                PickyHubButton(
                    title: check?.phase == .checking ? "settings.voice.stt.checking" : "settings.voice.stt.check",
                    role: .secondary,
                    isBusy: check?.phase == .checking,
                    isEnabled: hasKey
                ) {
                    runSTTConnectionCheck(provider: provider)
                }
                Spacer(minLength: 0)
            }
            if case .finished(let result)? = check?.phase {
                PickySTTConnectionStatusView(provider: provider, result: result)
            }
            if PickySTTConnectionCheck.showsKeyGuide(apiKey: text.wrappedValue, check: check) {
                PickySTTKeyGuideView(provider: provider)
            } else {
                PickySTTConsoleLinkView(provider: provider)
            }
        }
    }

    private var groqModelBinding: Binding<String> {
        Binding(
            get: { GroqTranscriptionDefaults.modelName(from: viewModel.settings) },
            set: { newValue in
                viewModel.settings.groqSTTModel = newValue
                commitVoiceField()
            }
        )
    }

    private var groqLanguagePicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel("settings.voice.stt.language")
            PickyNativeMenuPicker(
                title: L10n.t("settings.voice.stt.language"),
                selection: $viewModel.settings.groqSTTLanguage,
                options: [
                    .init(value: "", title: L10n.t("settings.voice.stt.language.auto")),
                    .init(value: "ko", title: "한국어"),
                    .init(value: "en", title: "English"),
                    .init(value: "ja", title: "日本語"),
                    .init(value: "zh", title: "中文"),
                ]
            )
            .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: viewModel.settings.groqSTTLanguage) { _, _ in commitVoiceField() }
        }
    }

    private var sttVocabularySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel("settings.voice.stt.vocabulary")
            TextField(L10n.t("settings.voice.stt.vocabulary.placeholder"), text: $sttVocabularyDraft, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.supportingMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, DS.Spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: sttVocabularyDraft) { _, _ in voiceDraftDidChange() }
                .onSubmit { commitVoiceField() }
            Text("settings.voice.stt.vocabulary.note")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
            toggleRow(
                "settings.voice.stt.vocabulary.context",
                isOn: $viewModel.settings.sttIncludesContextTerms,
                divider: false
            )
            .onChange(of: viewModel.settings.sttIncludesContextTerms) { _, _ in commitVoiceField() }
        }
    }

    /// Saves pending voice drafts, then verifies the typed key against the
    /// provider. The result is shown only while the same key stays in the field.
    private func runSTTConnectionCheck(provider: PickySTTKeyProvider) {
        commitVoiceField()
        let configuration: OpenAIAudioConfiguration
        let modelName: String
        let apiKey: String
        switch provider {
        case .groq:
            apiKey = groqSTTAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration = OpenAIAudioConfiguration(apiKey: apiKey, baseURL: GroqTranscriptionDefaults.baseURL)
            modelName = GroqTranscriptionDefaults.modelName(from: viewModel.settings)
        case .openai:
            apiKey = openAISTTAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration = OpenAIAudioConfiguration(
                apiKey: apiKey,
                baseURL: OpenAIAudioConfiguration.parseBaseURLOverride(openAISTTBaseURLDraft) ?? OpenAIAudioConfiguration.defaultBaseURL
            )
            let draftModel = openAISTTModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            modelName = draftModel.isEmpty ? OpenAITranscriptionProvider.defaultModelName : draftModel
        }
        let pending = PickySTTConnectionCheck(provider: provider, apiKey: apiKey, phase: .checking)
        sttConnectionCheck = pending
        Task { @MainActor in
            let result = await OpenAITranscriptionProvider.checkConnection(configuration: configuration, modelName: modelName)
            guard sttConnectionCheck == pending else { return }
            sttConnectionCheck?.phase = .finished(result)
        }
    }

    private func voiceSecureInput(placeholder: String, text: Binding<String>, isInvalid: Bool) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(PickyHUDTypography.supportingMonospacedMedium)
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, DS.Spacing.space2)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(
                        isInvalid ? DS.Colors.destructiveText : DS.Colors.borderSubtle.opacity(0.6),
                        lineWidth: isInvalid ? 1 : 0.5
                    )
            )
            .onChange(of: text.wrappedValue) { _, _ in voiceDraftDidChange() }
            .onSubmit { commitVoiceField() }
    }

    /// Sub-section label inside the Voice section. Visually subdues the STT vs TTS
    /// boundary using the same secondary text style as field labels — no big
    /// section chrome, just enough hierarchy to keep credential cards from
    /// blending together.
    private func voiceSubgroupHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(PickyHUDTypography.metaSemibold)
            .foregroundColor(DS.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.bottom, DS.Spacing.space2)
    }

    /// Hairline divider between the STT and TTS groups. Uses the same subtle
    /// border tone as field card outlines so it feels native to this panel.
    private func voiceGroupDivider() -> some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle.opacity(0.4))
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }

    private func voiceTextField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.supportingMonospacedMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, DS.Spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    voiceDraftDidChange()
                }
                .onSubmit { commitVoiceField() }
        }
    }

    private func voiceSecureField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(label)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.supportingMonospacedMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, DS.Spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    voiceDraftDidChange()
                }
                .onSubmit { commitVoiceField() }
        }
    }

    private func voiceDraftDidChange() {
        voiceDraftRevision &+= 1
        updateDraftStatus(for: .voice, isDirty: isVoiceDraftDirty())
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(presentation.showsNavigationChrome ? PickyHUDTypography.metaSemibold : PickyHUDTypography.labelSemibold)
            .foregroundColor(presentation.showsNavigationChrome ? DS.Colors.textTertiary : PickyHubTheme.Colors.textPrimary)
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, divider: Bool, isEnabled: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(PickyHUDTypography.labelMedium)
                    .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                Spacer(minLength: 8)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .controlSize(.small)
                    .disabled(!isEnabled)
            }
            .padding(.vertical, DS.Spacing.space2)

            if divider {
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))
            }
        }
    }

    private func cwdField(
        placeholder: String,
        text: Binding<String>,
        onChange: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void,
        onChoose: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DS.Spacing.space2) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.supportingMonospacedMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, DS.Spacing.space2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, newValue in onChange(newValue) }
                .onSubmit { onSubmit() }
            Button("common.choose") { onChoose() }
                .font(PickyHUDTypography.supportingMedium)
                .foregroundColor(DS.Colors.accentText)
                .buttonStyle(.plain)
                .hoverAffordance()
        }
    }

    /// Opens the Spoken Content pane in System Settings so users can pick the
    /// macOS system voice used by the local TTS provider.
    private var openMacOSSpeechSettingsButton: some View {
        Button(action: {
            // Sonoma+ Settings URL for Accessibility > Spoken Content.
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Speech") else { return }
            NSWorkspace.shared.open(url)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(PickyHUDTypography.supportingMedium)
                Text("settings.macSpeechLink")
                    .font(PickyHUDTypography.statusSemibold)
                Image(systemName: "arrow.up.right")
                    .font(PickyHUDTypography.minimumSemibold)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.vertical, DS.Spacing.space2)
            .background(
                Capsule()
                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(L10n.t("settings.macSpeechLink.help"))
        .hoverAffordance()
    }

    /// Opens the AGENTS.md file inside the main-agent cwd. If the file is
    /// missing we seed the workspace default markdown via
    /// `PickyWorkspaceSeeder.seed(workspacePath:)` so the user always lands on
    /// a real file (the seeder is idempotent and never overwrites existing
    /// content).
    private var openAgentsFileButton: some View {
        Button(action: {
            let cwd = viewModel.settings.mainAgentCwd
            guard !cwd.isEmpty else { return }
            PickyWorkspaceSeeder.seed(workspacePath: cwd)
            let url = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename, isDirectory: false)
            NSWorkspace.shared.open(url)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(PickyHUDTypography.supportingMedium)
                Text("settings.action.openAgentsFile")
                    .font(PickyHUDTypography.statusSemibold)
                Image(systemName: "arrow.up.right")
                    .font(PickyHUDTypography.minimumSemibold)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.vertical, DS.Spacing.space2)
            .background(
                Capsule()
                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverAffordance()
    }

    private var edgeTTSSettings: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            Text("settings.voice.edge.disclosure")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()

            switch edgeTTSVoiceCatalog.state {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("settings.voice.edge.loading")
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(supportingTextColor)
                        .pickyHubSelectableText()
                }
            case .failed(let message):
                Text(L10n.t("settings.voice.edge.selectedVoice", viewModel.settings.edgeTTSVoice))
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(supportingTextColor)
                    .pickyHubSelectableText()
                Text(message)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
                Button("settings.voice.edge.retry") { edgeTTSVoiceCatalog.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .loaded:
                edgeTTSVoicePickers
            }
        }
    }

    private var edgeTTSVoicePickers: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                fieldLabel("settings.voice.edge.language")
                PickyNativeMenuPicker(
                    title: L10n.t("settings.voice.edge.language"),
                    selection: edgeTTSLocaleBinding,
                    options: edgeTTSVoiceCatalog.locales(selectedVoice: viewModel.settings.edgeTTSVoice).map {
                        .init(value: $0, title: edgeTTSLocaleLabel($0))
                    }
                )
                .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                fieldLabel("settings.voice.edge.voice")
                PickyNativeMenuPicker(
                    title: L10n.t("settings.voice.edge.voice"),
                    selection: $viewModel.settings.edgeTTSVoice,
                    options: edgeTTSMenuOptions
                )
                .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: viewModel.settings.edgeTTSVoice) { _, _ in commitVoiceField() }
            }
        }
    }

    private var edgeTTSMenuOptions: [PickyNativeMenuOption<String>] {
        var options: [PickyNativeMenuOption<String>] = []
        if !EdgeTTSVoiceCatalogProjection.isSelectedVoiceAvailable(viewModel.settings.edgeTTSVoice, voices: edgeTTSVoiceCatalog.voices) {
            options.append(.init(value: viewModel.settings.edgeTTSVoice, title: L10n.t("settings.voice.edge.savedVoiceUnavailable", viewModel.settings.edgeTTSVoice)))
        }
        options += edgeTTSVoiceCatalog.voices(in: selectedEdgeTTSLocale).map {
            .init(value: $0.shortName, title: edgeTTSVoiceLabel($0))
        }
        return options
    }

    private var selectedEdgeTTSLocale: String {
        EdgeTTSVoiceCatalogProjection.selectedLocale(
            voice: viewModel.settings.edgeTTSVoice,
            voices: edgeTTSVoiceCatalog.voices
        ) ?? EdgeTTSVoiceCatalogProjection.unavailableLocale
    }

    private func edgeTTSLocaleLabel(_ locale: String) -> String {
        locale == EdgeTTSVoiceCatalogProjection.unavailableLocale
            ? L10n.t("settings.voice.edge.localeUnavailable")
            : edgeTTSVoiceCatalog.voices(in: locale).isEmpty
                ? L10n.t("settings.voice.edge.localeUnavailableWithName", locale)
                : locale
    }

    private func edgeTTSVoiceLabel(_ voice: EdgeTTSVoice) -> String {
        guard let genderKey = EdgeTTSVoiceCatalogProjection.genderLocalizationKey(voice.gender) else {
            return voice.friendlyName
        }
        return "\(voice.friendlyName) (\(L10n.t(genderKey)))"
    }

    private var edgeTTSLocaleBinding: Binding<String> {
        Binding(
            get: { selectedEdgeTTSLocale },
            set: { locale in
                guard let voice = edgeTTSVoiceCatalog.voices(in: locale).first else { return }
                // The voice picker observes this binding and persists once.
                viewModel.settings.edgeTTSVoice = voice.shortName
            }
        )
    }

    private func providerPicker(title: String, capability: PickyVoiceProviderCapability, selection: Binding<PickyVoiceProviderSelection>, isEnabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            fieldLabel(LocalizedStringKey(title))
            PickyNativeMenuPicker(
                title: L10n.t(title),
                selection: selection,
                options: PickyVoiceProviderSelection.cases(for: capability).map {
                    .init(value: $0, title: $0.displayName(for: capability))
                }
            )
            .frame(maxWidth: embeddedMenuMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.55)
            // Picker changes must also persist any in-flight voice text drafts;
            // saveImmediately alone would re-sync drafts from settings and erase
            // them. providerPicker is voice-only today, so commit is safe here.
            .onChange(of: selection.wrappedValue) { _, _ in commitVoiceField() }
        }
    }

    /// Submit handler shared by text field Return keys and the section-local "Save"
    /// button shown in `.dirty` mode. Only folds the edited section draft back into
    /// the view-model so unrelated dirty sections keep their unsaved text intact.
    private func commitEdits(in section: CompanionPanelSettingsSection) {
        switch section {
        case .general, .overlayAndNotifications, .shortcuts, .builtinTools:
            saveImmediately(for: section)
        case .mainAgent:
            commitMainAgentCwdField()
        case .pickle:
            commitPickleCwdField()
        case .voice:
            commitVoiceField()
        case .oauth:
            break
        }
    }

    /// Persists the new shortcut spec via the view-model. The view-model
    /// refuses the change when it would collide with the other shortcut so
    /// the runtime never has two paths fighting over the same keypress.
    private func saveShortcut(
        _ newSpec: PickyShortcutSpec,
        role: PickyShortcutRole
    ) {
        guard viewModel.updateShortcut(newSpec, role: role) else {
            saveStatuses.markDirty(.shortcuts)
            return
        }
        saveSectionDurably(.shortcuts)
    }

    private func resetShortcutsToDefaults() {
        guard viewModel.resetShortcutsToDefaults() else {
            saveStatuses.markDirty(.shortcuts)
            return
        }
        saveSectionDurably(.shortcuts)
    }

    private func saveSectionDurably(_ section: CompanionPanelSettingsSection) {
        viewModel.save { didSave in
            if didSave {
                self.saveStatuses.markSaved(section)
                self.scheduleSaveStatusReset(for: section)
            } else {
                self.saveStatuses.markDirty(section)
            }
        }
    }

    private func isMainAgentDraftDirty(
        mainAgentCwd: String? = nil,
        piBinaryPath: String? = nil,
        piCodingAgentDir: String? = nil
    ) -> Bool {
        (mainAgentCwd ?? mainAgentCwdDraft) != viewModel.settings.mainAgentCwd
            || (piBinaryPath ?? piBinaryPathDraft) != viewModel.settings.piBinaryPath
            || (piCodingAgentDir ?? piCodingAgentDirDraft) != viewModel.settings.piCodingAgentDir
    }

    private func commitMainAgentCwdField() {
        viewModel.settings.mainAgentCwd = mainAgentCwdDraft
        viewModel.settings.piBinaryPath = piBinaryPathDraft
        viewModel.settings.piCodingAgentDir = piCodingAgentDirDraft
        saveImmediately(for: .mainAgent)
    }

    private func commitPickleCwdField() {
        viewModel.settings.defaultCwd = pickleCwdDraft
        saveImmediately(for: .pickle)
    }

    private func commitVoiceField() {
        viewModel.settings.azureOpenAIEndpoint = azureSTTEndpointDraft
        viewModel.settings.azureOpenAIAPIKey = azureSTTAPIKeyDraft
        viewModel.settings.azureOpenAITTSEndpoint = azureTTSEndpointDraft
        viewModel.settings.azureOpenAITTSAPIKey = azureTTSAPIKeyDraft
        viewModel.settings.azureOpenAITTSVoice = azureTTSVoiceDraft
        viewModel.settings.azureSTTPreferredLanguage = azureLanguageDraft
        viewModel.settings.openAITTSAPIKey = openAITTSAPIKeyDraft
        viewModel.settings.openAITTSVoice = openAITTSVoiceDraft
        viewModel.settings.openAITTSModel = openAITTSModelDraft
        viewModel.settings.openAITTSBaseURL = openAITTSBaseURLDraft
        viewModel.settings.openAISTTAPIKey = openAISTTAPIKeyDraft
        viewModel.settings.openAISTTModel = openAISTTModelDraft
        viewModel.settings.openAISTTPreferredLanguage = openAISTTLanguageDraft
        viewModel.settings.openAISTTBaseURL = openAISTTBaseURLDraft
        viewModel.settings.elevenLabsTTSAPIKey = elevenLabsTTSAPIKeyDraft
        viewModel.settings.elevenLabsTTSVoiceID = elevenLabsTTSVoiceIDDraft
        viewModel.settings.elevenLabsTTSModel = elevenLabsTTSModelDraft
        viewModel.settings.elevenLabsTTSOutputFormat = elevenLabsTTSOutputFormatDraft
        viewModel.settings.elevenLabsTTSBaseURL = elevenLabsTTSBaseURLDraft
        viewModel.settings.elevenLabsSTTAPIKey = elevenLabsSTTAPIKeyDraft
        viewModel.settings.elevenLabsSTTModel = elevenLabsSTTModelDraft
        viewModel.settings.elevenLabsSTTLanguage = elevenLabsSTTLanguageDraft
        viewModel.settings.groqSTTAPIKey = groqSTTAPIKeyDraft
        viewModel.settings.sttVocabulary = sttVocabularyDraft
        saveImmediately(for: .voice)
    }

    private func chooseMainAgentDirectory() {
        chooseDirectory(initialPath: mainAgentCwdDraft) { url in
            mainAgentCwdDraft = url.path
            commitMainAgentCwdField()
        }
    }

    private func choosePiCodingAgentDirectory() {
        chooseDirectory(initialPath: piCodingAgentDirDraft) { url in
            piCodingAgentDirDraft = url.path
            commitMainAgentCwdField()
        }
    }

    private func choosePiBinaryFile() {
        chooseFile(initialPath: piBinaryPathDraft.isEmpty ? piCodingAgentDirDraft : piBinaryPathDraft) { url in
            piBinaryPathDraft = url.path
            commitMainAgentCwdField()
        }
    }

    private func choosePickleDirectory() {
        chooseDirectory(initialPath: pickleCwdDraft) { url in
            pickleCwdDraft = url.path
            commitPickleCwdField()
        }
    }

    private func chooseDirectory(initialPath: String, commit: (URL) -> Void) {
        choosePath(initialPath: initialPath, canChooseFiles: false, canChooseDirectories: true, commit: commit)
    }

    private func chooseFile(initialPath: String, commit: (URL) -> Void) {
        choosePath(initialPath: initialPath, canChooseFiles: true, canChooseDirectories: false, commit: commit)
    }

    private func choosePath(initialPath: String, canChooseFiles: Bool, canChooseDirectories: Bool, commit: (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        let expanded = NSString(string: initialPath).expandingTildeInPath
        if !expanded.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: canChooseDirectories)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commit(url)
    }

    /// Persist whatever is currently in `viewModel.settings`, then briefly flash the
    /// saved indicator for the section that changed. On validation failure only that
    /// section falls back to dirty; the validation message itself renders at the
    /// bottom of the form.
    private func saveImmediately(for section: CompanionPanelSettingsSection) {
        if section == .mainAgent {
            if mainAgentCwdDraft != viewModel.settings.mainAgentCwd {
                viewModel.settings.mainAgentCwd = mainAgentCwdDraft
            }
            if piBinaryPathDraft != viewModel.settings.piBinaryPath {
                viewModel.settings.piBinaryPath = piBinaryPathDraft
            }
            if piCodingAgentDirDraft != viewModel.settings.piCodingAgentDir {
                viewModel.settings.piCodingAgentDir = piCodingAgentDirDraft
            }
        }
        let shouldPreserveDirtyPickleDraft = section == .pickle && pickleCwdDraft != viewModel.settings.defaultCwd
        let voiceDraftRevisionAtSave = section == .voice ? voiceDraftRevision : nil
        viewModel.save { didSave in
            if didSave {
                let hasNewerVoiceDraft = voiceDraftRevisionAtSave.map {
                    !CompanionVoiceDraftSyncPolicy.shouldSynchronize(
                        completedRevision: $0,
                        currentRevision: self.voiceDraftRevision
                    )
                } ?? false
                if shouldPreserveDirtyPickleDraft || hasNewerVoiceDraft {
                    self.saveStatuses.markDirty(section)
                } else {
                    self.syncDraft(for: section)
                    self.saveStatuses.markSaved(section)
                    self.scheduleSaveStatusReset(for: section)
                }
            } else {
                self.saveStatuses.markDirty(section)
                self.saveStatusResets[section]?.cancel()
                self.saveStatusResets[section] = nil
            }
        }
    }

    private func syncDraft(for section: CompanionPanelSettingsSection) {
        switch section {
        case .mainAgent:
            mainAgentCwdDraft = viewModel.settings.mainAgentCwd
            piBinaryPathDraft = viewModel.settings.piBinaryPath
            piCodingAgentDirDraft = viewModel.settings.piCodingAgentDir
        case .pickle:
            pickleCwdDraft = viewModel.settings.defaultCwd
        case .general, .oauth, .overlayAndNotifications, .shortcuts, .builtinTools:
            break
        case .voice:
            syncVoiceDrafts()
        }
    }

    private func syncVoiceDrafts() {
        azureSTTEndpointDraft = viewModel.settings.azureOpenAIEndpoint
        azureSTTAPIKeyDraft = viewModel.settings.azureOpenAIAPIKey
        azureTTSEndpointDraft = viewModel.settings.azureOpenAITTSEndpoint
        azureTTSAPIKeyDraft = viewModel.settings.azureOpenAITTSAPIKey
        azureTTSVoiceDraft = viewModel.settings.azureOpenAITTSVoice
        azureLanguageDraft = viewModel.settings.azureSTTPreferredLanguage
        openAITTSAPIKeyDraft = viewModel.settings.openAITTSAPIKey
        openAITTSVoiceDraft = viewModel.settings.openAITTSVoice
        openAITTSModelDraft = viewModel.settings.openAITTSModel
        openAITTSBaseURLDraft = viewModel.settings.openAITTSBaseURL
        openAISTTAPIKeyDraft = viewModel.settings.openAISTTAPIKey
        openAISTTModelDraft = viewModel.settings.openAISTTModel
        openAISTTLanguageDraft = viewModel.settings.openAISTTPreferredLanguage
        openAISTTBaseURLDraft = viewModel.settings.openAISTTBaseURL
        elevenLabsTTSAPIKeyDraft = viewModel.settings.elevenLabsTTSAPIKey
        elevenLabsTTSVoiceIDDraft = viewModel.settings.elevenLabsTTSVoiceID
        elevenLabsTTSModelDraft = viewModel.settings.elevenLabsTTSModel
        elevenLabsTTSOutputFormatDraft = viewModel.settings.elevenLabsTTSOutputFormat
        elevenLabsTTSBaseURLDraft = viewModel.settings.elevenLabsTTSBaseURL
        elevenLabsSTTAPIKeyDraft = viewModel.settings.elevenLabsSTTAPIKey
        elevenLabsSTTModelDraft = viewModel.settings.elevenLabsSTTModel
        elevenLabsSTTLanguageDraft = viewModel.settings.elevenLabsSTTLanguage
        groqSTTAPIKeyDraft = viewModel.settings.groqSTTAPIKey
        sttVocabularyDraft = viewModel.settings.sttVocabulary
    }

    private func isVoiceDraftDirty() -> Bool {
        azureSTTEndpointDraft != viewModel.settings.azureOpenAIEndpoint
            || azureSTTAPIKeyDraft != viewModel.settings.azureOpenAIAPIKey
            || azureTTSEndpointDraft != viewModel.settings.azureOpenAITTSEndpoint
            || azureTTSAPIKeyDraft != viewModel.settings.azureOpenAITTSAPIKey
            || azureTTSVoiceDraft != viewModel.settings.azureOpenAITTSVoice
            || azureLanguageDraft != viewModel.settings.azureSTTPreferredLanguage
            || openAITTSAPIKeyDraft != viewModel.settings.openAITTSAPIKey
            || openAITTSVoiceDraft != viewModel.settings.openAITTSVoice
            || openAITTSModelDraft != viewModel.settings.openAITTSModel
            || openAITTSBaseURLDraft != viewModel.settings.openAITTSBaseURL
            || openAISTTAPIKeyDraft != viewModel.settings.openAISTTAPIKey
            || openAISTTModelDraft != viewModel.settings.openAISTTModel
            || openAISTTLanguageDraft != viewModel.settings.openAISTTPreferredLanguage
            || openAISTTBaseURLDraft != viewModel.settings.openAISTTBaseURL
            || elevenLabsTTSAPIKeyDraft != viewModel.settings.elevenLabsTTSAPIKey
            || elevenLabsTTSVoiceIDDraft != viewModel.settings.elevenLabsTTSVoiceID
            || elevenLabsTTSModelDraft != viewModel.settings.elevenLabsTTSModel
            || elevenLabsTTSOutputFormatDraft != viewModel.settings.elevenLabsTTSOutputFormat
            || elevenLabsTTSBaseURLDraft != viewModel.settings.elevenLabsTTSBaseURL
            || elevenLabsSTTAPIKeyDraft != viewModel.settings.elevenLabsSTTAPIKey
            || elevenLabsSTTModelDraft != viewModel.settings.elevenLabsSTTModel
            || elevenLabsSTTLanguageDraft != viewModel.settings.elevenLabsSTTLanguage
            || groqSTTAPIKeyDraft != viewModel.settings.groqSTTAPIKey
            || sttVocabularyDraft != viewModel.settings.sttVocabulary
    }

    private func updateDraftStatus(for section: CompanionPanelSettingsSection, isDirty: Bool) {
        if isDirty {
            saveStatuses.markDirty(section)
            saveStatusResets[section]?.cancel()
            saveStatusResets[section] = nil
        } else if saveStatuses[section] == .dirty {
            saveStatuses.clear(section)
        }
    }

    private func scheduleSaveStatusReset(for section: CompanionPanelSettingsSection) {
        saveStatusResets[section]?.cancel()
        saveStatusResets[section] = Just(())
            .delay(for: .seconds(1.6), scheduler: RunLoop.main)
            .sink { _ in
                saveStatuses.clearSaved(section)
                saveStatusResets[section] = nil
            }
    }
}

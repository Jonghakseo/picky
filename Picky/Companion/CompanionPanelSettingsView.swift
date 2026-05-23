//
//  CompanionPanelSettingsView.swift
//  Picky
//
//  Friendly settings surface for the menu bar panel.
//
//  Minimal redesign: every section is just a label + body, separated by hairline
//  dividers — no card chrome. Toggle changes autosave immediately because they
//  cannot fail validation; text fields (which validate as directories) keep an
//  explicit save path that surfaces only when the user has unsaved edits.
//

import AppKit
import Combine
import SwiftUI

enum CompanionPanelSettingsSection: CaseIterable, Hashable {
    case general
    case mainAgent
    case pickle
    case overlayAndNotifications
    case voice
    case shortcuts
    case builtinTools
    case onboarding
}

/// One screen of the Settings tab. The index screen lists the categories;
/// every other case is a leaf page hosting that category's content. Adding a
/// new category amounts to: extend this enum, add a label/subtitle, and route
/// to the matching helper view inside CompanionPanelSettingsView.
enum CompanionPanelSettingsRoute: Hashable {
    case index
    case general
    case mainAgent
    case pickle
    /// Combined page that used to live as two separate routes (`.cursorBubbles`
    /// and `.notification`). Old `picky://` URLs still resolve here through
    /// `PickyDeepLink.fromDeepLinkPath` aliases.
    case overlayAndNotifications
    case voice
    case shortcuts
    case builtinTools
    case onboarding

    var section: CompanionPanelSettingsSection? {
        switch self {
        case .index: nil
        case .general: .general
        case .mainAgent: .mainAgent
        case .pickle: .pickle
        case .overlayAndNotifications: .overlayAndNotifications
        case .voice: .voice
        case .shortcuts: .shortcuts
        case .builtinTools: .builtinTools
        case .onboarding: .onboarding
        }
    }

    /// Localized title for the route. Resolved through `L10n.t(_:)` rather
    /// than `Text(...)` because callers store the string in `String` fields
    /// (navigation breadcrumbs, button labels) and we want a value, not a view.
    var title: String {
        switch self {
        case .index: L10n.t("settings.indexTitle")
        case .general: L10n.t("settings.general.title")
        case .mainAgent: L10n.t("settings.section.picky.title")
        case .pickle: L10n.t("settings.section.pickle.title")
        case .overlayAndNotifications: L10n.t("settings.section.overlayAndNotifications.title")
        case .voice: L10n.t("settings.section.voice.title")
        case .shortcuts: L10n.t("settings.section.shortcuts.title")
        case .builtinTools: L10n.t("settings.section.builtinTools.title")
        case .onboarding: L10n.t("settings.section.onboarding.title")
        }
    }

    var subtitle: String? {
        switch self {
        case .index: nil
        case .general: L10n.t("settings.general.subtitle.index")
        case .mainAgent: L10n.t("settings.section.picky.subtitle")
        case .pickle: L10n.t("settings.section.pickle.subtitle")
        case .overlayAndNotifications: L10n.t("settings.section.overlayAndNotifications.subtitle")
        case .voice: L10n.t("settings.section.voice.subtitle")
        case .shortcuts: L10n.t("settings.section.shortcuts.subtitle")
        case .builtinTools: L10n.t("settings.section.builtinTools.subtitle")
        case .onboarding: L10n.t("settings.section.onboarding.subtitle")
        }
    }
}

/// Visual grouping for the Settings index. Each group renders as a small
/// uppercase header followed by its leaf rows. Order inside the file is the
/// order the user sees — rearrange here, not by editing the enum.
///
/// `.onboarding` is intentionally absent from every group. The route/section/
/// view still exist so the takeover overlay (later phases) can mark completion
/// through the same plumbing, and so dev builds can re-enable the Replay entry
/// with a single-line edit. Don't remove the case.
///
/// Feedback is not a Settings sub-page anymore — it renders as a panel-level
/// overlay reached from the Status tab’s entry row.
struct CompanionPanelSettingsGroup: Identifiable {
    let id: String
    let titleKey: LocalizedStringKey
    let routes: [CompanionPanelSettingsRoute]
}

private let companionPanelSettingsGroups: [CompanionPanelSettingsGroup] = [
    CompanionPanelSettingsGroup(
        id: "general",
        titleKey: "settings.group.general.title",
        routes: [.general, .shortcuts]
    ),
    CompanionPanelSettingsGroup(
        id: "agents",
        titleKey: "settings.group.agents.title",
        routes: [.mainAgent, .pickle, .builtinTools]
    ),
    CompanionPanelSettingsGroup(
        id: "surface",
        titleKey: "settings.group.surface.title",
        routes: [.voice, .overlayAndNotifications]
    )
]

/// Flat order of every user-visible route, derived from the groups. Kept as a
/// computed convenience for any caller that just needs to iterate every leaf.
private var companionPanelSettingsRouteOrder: [CompanionPanelSettingsRoute] {
    companionPanelSettingsGroups.flatMap(\.routes)
}

enum CompanionPanelSettingsSaveStatus: Equatable {
    case idle
    case saved
    case dirty
}

struct CompanionPanelSettingsSaveStatuses: Equatable {
    private var statuses: [CompanionPanelSettingsSection: CompanionPanelSettingsSaveStatus] = [:]

    subscript(_ section: CompanionPanelSettingsSection) -> CompanionPanelSettingsSaveStatus {
        statuses[section] ?? .idle
    }

    mutating func markSaved(_ section: CompanionPanelSettingsSection) {
        set(.saved, for: section)
    }

    mutating func markDirty(_ section: CompanionPanelSettingsSection) {
        set(.dirty, for: section)
    }

    mutating func clear(_ section: CompanionPanelSettingsSection) {
        set(.idle, for: section)
    }

    mutating func clearSaved(_ section: CompanionPanelSettingsSection) {
        if self[section] == .saved { clear(section) }
    }

    private mutating func set(_ status: CompanionPanelSettingsSaveStatus, for section: CompanionPanelSettingsSection) {
        if status == .idle {
            statuses.removeValue(forKey: section)
        } else {
            statuses[section] = status
        }
    }
}

struct CompanionPanelSettingsView: View {
    @ObservedObject var viewModel: PickySettingsViewModel
    @ObservedObject var companionManager: CompanionManager
    /// Shared HUD session list. The Pickle settings section renders the
    /// archived-Pickle list (restore + permanent delete) directly off this
    /// view model so the menu bar panel and the HUD see the same data.
    @ObservedObject var sessionListViewModel: PickySessionListViewModel
    @State private var mainAgentCwdDraft: String = ""
    @State private var pickleCwdDraft: String = ""
    @State private var azureSTTEndpointDraft: String = ""
    @State private var azureSTTAPIKeyDraft: String = ""
    @State private var azureTTSEndpointDraft: String = ""
    @State private var azureTTSAPIKeyDraft: String = ""
    @State private var azureTTSVoiceDraft: String = ""
    @State private var azureLanguageDraft: String = ""
    // OpenAI direct provider drafts (Task 5/6 — base URL is shared via OPENAI_BASE_URL fallback at runtime).
    @State private var openAITTSAPIKeyDraft: String = ""
    @State private var openAITTSVoiceDraft: String = ""
    @State private var openAITTSModelDraft: String = ""
    @State private var openAITTSBaseURLDraft: String = ""
    @State private var openAISTTAPIKeyDraft: String = ""
    @State private var openAISTTModelDraft: String = ""
    @State private var openAISTTLanguageDraft: String = ""
    @State private var openAISTTBaseURLDraft: String = ""
    // ElevenLabs STT drafts (TTS reuses ELEVENLABS_API_KEY env var via the existing TTS provider).
    @State private var elevenLabsSTTAPIKeyDraft: String = ""
    @State private var elevenLabsSTTModelDraft: String = ""
    @State private var elevenLabsSTTLanguageDraft: String = ""
    @State private var saveStatuses = CompanionPanelSettingsSaveStatuses()
    @State private var saveStatusResets: [CompanionPanelSettingsSection: AnyCancellable] = [:]
    /// Whether the archived-Pickle list at the bottom of the Pickle page is
    /// expanded. Lives as @State so re-opening the panel collapses it again —
    /// archive management is an occasional task, not a persistent setting.
    @State private var isArchivedSessionsExpanded: Bool = false
    @Binding var route: CompanionPanelSettingsRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navHeader
            content

            if route != .index, let error = viewModel.validationError {
                Text(error)
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .animation(.easeOut(duration: 0.16), value: route)
        .onAppear {
            mainAgentCwdDraft = viewModel.settings.mainAgentCwd
            pickleCwdDraft = viewModel.settings.defaultCwd
            syncVoiceDrafts()
        }
        .onChange(of: viewModel.settings.notifications) { _, _ in
            // Toggles only flip booleans, so they cannot fail directory validation.
            // Persist immediately and flash the saved indicator on the unified
            // Overlay & Notifications section. Draft text in other sections
            // remains untouched.
            saveImmediately(for: .overlayAndNotifications)
        }
        .onChange(of: viewModel.settings.cursor) { _, _ in
            saveImmediately(for: .overlayAndNotifications)
        }
        .onChange(of: viewModel.settings.overlayBubbles) { _, _ in
            saveImmediately(for: .overlayAndNotifications)
        }
        .onChange(of: viewModel.settings.ttsEnabled) { _, _ in
            // Fold voice text drafts into settings before saving so an
            // in-progress edit (e.g. a half-typed API key) is not clobbered
            // when syncVoiceDrafts() runs after a successful save.
            commitVoiceField()
        }
        .onChange(of: viewModel.settings.disabledBuiltinTools) { _, _ in
            saveImmediately(for: .builtinTools)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .index: indexView
        case .general: generalSection
        case .mainAgent: mainAgentSection
        case .pickle: pickleSection
        case .overlayAndNotifications: overlayAndNotificationsSection
        case .voice: voiceSection
        case .shortcuts: shortcutsSection
        case .builtinTools: builtinToolsSection
        case .onboarding: onboardingSection
        }
    }

    @ViewBuilder
    private var navHeader: some View {
        if route != .index {
            HStack(spacing: 8) {
                Button(action: { route = .index }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .pickyFont(size: 11, weight: .semibold)
                        Text(L10n.t("tab.settings"))
                            .pickyFont(size: 11.5, weight: .medium)
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer(minLength: 6)
            }
            .padding(.bottom, 8)
        }
    }

    private var indexView: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            .pickyFont(size: 10, weight: .semibold)
            .foregroundColor(DS.Colors.textTertiary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .padding(.leading, 2)
    }

    /// Single tappable row on the Settings index. Subtitle prefers the live
    /// summary built from the current settings (so the user can recognise the
    /// state without drilling in) and falls back to the route's static blurb
    /// when no summary is meaningful (e.g. the hidden onboarding route).
    private func indexRow(for item: CompanionPanelSettingsRoute) -> some View {
        Button(action: { route = item }) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .pickyFont(size: 12.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    if let subtitle = indexSubtitle(for: item) {
                        Text(subtitle)
                            .pickyFont(size: 10.5, weight: .medium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let section = item.section {
                    statusIndicator(for: section)
                }
                Image(systemName: "chevron.right")
                    .pickyFont(size: 10, weight: .semibold)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
    /// no compact summary exists (e.g. the hidden onboarding entry); the
    /// caller then falls back to the static subtitle.
    private func indexSummary(for route: CompanionPanelSettingsRoute) -> String? {
        let settings = viewModel.settings
        switch route {
        case .index, .onboarding:
            return nil
        case .general:
            return String(localized: settings.appLanguage.displayKey)
        case .shortcuts:
            let ptt = settings.pushToTalkShortcut.summaryString
            let qi = settings.quickInputShortcut.summaryString
            return L10n.t("settings.summary.shortcuts", ptt, qi)
        case .mainAgent:
            let runtime = settings.mainAgentRuntimeMode.displayName
            let model = indexModelLabel(settings.mainAgentModelPattern)
            return "\(runtime) \u{00B7} \(model)"
        case .pickle:
            let model = indexModelLabel(settings.pickleAgentModelPattern)
            let dock = settings.hudDockSizePreset.displayName
            return L10n.t("settings.summary.pickle", model, dock)
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
            let alertsOn = [n.notifyOnCompleted, n.notifyOnFailed, n.notifyOnWaitingForInput]
                .filter { $0 }
                .count
            return L10n.t("settings.summary.overlayAndNotifications", cursor, alertsOn, 3)
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
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
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

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.field.reasoningLevel")
                    Picker("settings.field.reasoningLevel", selection: $viewModel.settings.pickleAgentThinkingLevel) {
                        ForEach(PickyPickleAgentThinkingLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.settings.pickleAgentThinkingLevel) { _, _ in saveImmediately(for: .pickle) }
                    Text("settings.field.reasoningLevel.pickleNote")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))

                dockSizePresetPicker

                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))

                gitChipActionsGroup

                if !sessionListViewModel.archivedSessions.isEmpty {
                    Divider()
                        .background(DS.Colors.borderSubtle.opacity(0.3))

                    archivedSessionsDisclosure
                }
            }
        }
    }

    /// Footer disclosure on the Pickle settings page. Collapsed by default so
    /// the page reads as settings; the archive list only renders when the user
    /// asks for it. Hidden entirely when there is nothing to manage so the
    /// settings page does not carry an empty data section.
    private var archivedSessionsDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    isArchivedSessionsExpanded.toggle()
                }
            }) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: isArchivedSessionsExpanded ? "chevron.down" : "chevron.right")
                        .pickyFont(size: 10, weight: .semibold)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 12)
                    Text("settings.pickle.archive.toggle")
                        .pickyFont(size: 11.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("\(sessionListViewModel.archivedSessions.count)")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer(minLength: 4)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isArchivedSessionsExpanded {
                PickyHUDArchivedSessionsListView(
                    viewModel: sessionListViewModel,
                    showsHeader: false
                )
                .padding(.top, 4)
            }
        }
    }

    private var gitChipActionsGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        label: LocalizedStringKey,
        action: Binding<PickyGitChipAction?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            Picker(label, selection: gitChipKindBinding(action)) {
                Text("settings.pickle.gitChipActions.kindPi").tag(PickyGitChipActionKind.pi)
                Text("settings.pickle.gitChipActions.kindShell").tag(PickyGitChipActionKind.shell)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            TextField(
                "settings.pickle.gitChipActions.commandPlaceholder",
                text: gitChipCommandBinding(action)
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .onSubmit { saveImmediately(for: .pickle) }
        }
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
                            .pickyFont(size: 10.5, weight: .medium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
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

                voiceGroupDivider()

                VStack(alignment: .leading, spacing: 0) {
                    voiceSubgroupHeader("settings.overlayAndNotifications.subgroup.alerts")
                    toggleRow("settings.notification.toggle.onSuccess", isOn: $viewModel.settings.notifications.notifyOnCompleted, divider: true)
                    toggleRow("settings.notification.toggle.onFailure", isOn: $viewModel.settings.notifications.notifyOnFailed, divider: true)
                    toggleRow("settings.notification.toggle.onInputRequest", isOn: $viewModel.settings.notifications.notifyOnWaitingForInput, divider: false)
                }
            }
        }
    }

    private var mainAgentSection: some View {
        sectionHeader(
            section: .mainAgent,
            title: L10n.t("settings.section.picky.title"),
            subtitle: L10n.t("settings.section.picky.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("settings.field.pickyCwd")
                    cwdField(
                        placeholder: "~/",
                        text: $mainAgentCwdDraft,
                        onChange: { newValue in
                            updateDraftStatus(for: .mainAgent, isDirty: newValue != viewModel.settings.mainAgentCwd)
                        },
                        onSubmit: commitMainAgentCwdField,
                        onChoose: chooseMainAgentDirectory
                    )
                    Text("settings.field.pickyCwd.note")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("settings.field.pickyCwd.workspaceWarning")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                mainAgentRuntimePicker

                if isMainAgentRuntimeRestartPending {
                    runtimeRestartNotice
                }

                if viewModel.settings.mainAgentRuntimeMode == .openAIRealtime {
                    realtimeSettingsFields
                } else {
                    piMainAgentModelPicker
                }

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.field.reasoningLevel")
                    Picker("settings.field.reasoningLevel", selection: $viewModel.settings.mainAgentThinkingLevel) {
                        ForEach(PickyMainAgentThinkingLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.settings.mainAgentThinkingLevel) { _, _ in saveImmediately(for: .mainAgent) }
                }

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.field.screenContext")
                    Picker("settings.field.screenContext", selection: $viewModel.settings.screenContextScope) {
                        ForEach(PickyScreenContextScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.settings.screenContextScope) { _, _ in saveImmediately(for: .mainAgent) }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("settings.field.attachScreenshotsOnlyWhenInked")
                            .pickyFont(size: 11.5, weight: .medium)
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer(minLength: 8)
                        Toggle("settings.field.attachScreenshotsOnlyWhenInked",
                               isOn: $viewModel.settings.attachScreenshotsOnlyWhenInked)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(DS.Colors.accent)
                            .controlSize(.small)
                            .onChange(of: viewModel.settings.attachScreenshotsOnlyWhenInked) { _, _ in
                                saveImmediately(for: .mainAgent)
                            }
                    }
                    Text("settings.field.attachScreenshotsOnlyWhenInked.note")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.field.screenshotQuality")
                    Picker("settings.field.screenshotQuality", selection: $viewModel.settings.screenshotQuality) {
                        ForEach(PickyScreenshotQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: viewModel.settings.screenshotQuality) { _, _ in saveImmediately(for: .mainAgent) }
                    Text("settings.field.screenshotQuality.note")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appliedMainAgentRuntimeMode == .pi {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("settings.field.agentsFile")
                        Text("settings.field.agentsFile.note")
                            .pickyFont(size: 11)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        openAgentsFileButton
                    }
                }
            }
        }
    }

    private var appliedMainAgentRuntimeMode: PickyMainAgentRuntimeMode {
        AppBundleConfiguration.effectiveRuntimeMode
    }

    private var isMainAgentRuntimeRestartPending: Bool {
        viewModel.settings.mainAgentRuntimeMode != appliedMainAgentRuntimeMode
    }

    private var mainAgentRuntimePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("settings.field.mainAgentRuntime")
            Picker("settings.field.mainAgentRuntime", selection: $viewModel.settings.mainAgentRuntimeMode) {
                ForEach(PickyMainAgentRuntimeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: viewModel.settings.mainAgentRuntimeMode) { _, _ in
                saveImmediately(for: .mainAgent)
            }

            Text(L10n.t("settings.mainAgentRuntime.appliedNote", appliedMainAgentRuntimeMode.displayName))
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runtimeRestartNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .pickyFont(size: 12, weight: .semibold)
                    .foregroundColor(DS.Colors.warningText)
                Text(L10n.t("settings.mainAgentRuntime.restartNotice", viewModel.settings.mainAgentRuntimeMode.displayName, appliedMainAgentRuntimeMode.displayName))
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: quitPickyForRuntimeRestart) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .pickyFont(size: 10, weight: .semibold)
                    Text("settings.mainAgentRuntime.quitButton")
                        .pickyFont(size: 11, weight: .semibold)
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(L10n.t("settings.mainAgentRuntime.quitButton.help"))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.Colors.warningText.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.warningText.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    private var piMainAgentModelPicker: some View {
        modelPicker(
            label: "settings.field.piModel",
            selection: $viewModel.settings.mainAgentModelPattern,
            shouldShowSavedOption: shouldShowSavedMainAgentModelOption,
            savedValue: viewModel.settings.mainAgentModelPattern,
            onSave: { saveImmediately(for: .mainAgent) },
            helpText: L10n.t("settings.field.piModel.helpText")
        )
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
        label: LocalizedStringKey,
        selection: Binding<String>,
        shouldShowSavedOption: Bool,
        savedValue: String,
        onSave: @escaping () -> Void,
        helpText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                fieldLabel(label)
                if companionManager.isLoadingMainAgentModelOptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
            }
            Picker(label, selection: selection) {
                Text("settings.field.modelOption.automatic").tag("")
                if shouldShowSavedOption {
                    Text(L10n.t("settings.field.modelOption.saved", savedValue)).tag(savedValue)
                }
                ForEach(companionManager.mainAgentModelOptions) { option in
                    Text(option.displayName).tag(option.pattern)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selection.wrappedValue) { _, _ in onSave() }
            .task { companionManager.refreshMainAgentModelOptions() }

            Text(helpText)
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shouldShowSavedMainAgentModelOption: Bool {
        let saved = viewModel.settings.mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return false }
        return !companionManager.mainAgentModelOptions.contains { $0.pattern == saved }
    }

    private var shouldShowSavedPickleModelOption: Bool {
        let saved = viewModel.settings.pickleAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return false }
        return !companionManager.mainAgentModelOptions.contains { $0.pattern == saved }
    }

    private var realtimeSettingsFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("settings.field.realtimeProvider")
                Picker("settings.field.realtimeProvider", selection: $viewModel.settings.openAIRealtime.provider) {
                    ForEach(PickyOpenAIRealtimeProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: viewModel.settings.openAIRealtime.provider) { _, _ in saveImmediately(for: .mainAgent) }
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("settings.field.apiKey")
                SecureField(viewModel.settings.openAIRealtime.provider == .azureOpenAI ? L10n.t("settings.realtime.apiKey.placeholder.azure") : "sk-…", text: $viewModel.settings.openAIRealtime.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .pickyFont(size: 11, weight: .medium, design: .monospaced)
                    .onSubmit { saveImmediately(for: .mainAgent) }
                    .onChange(of: viewModel.settings.openAIRealtime.apiKey) { _, _ in saveImmediately(for: .mainAgent) }
            }

            if viewModel.settings.openAIRealtime.provider == .azureOpenAI {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.field.azureRealtimeUrl")
                    TextField("https://resource.openai.azure.com/openai/realtime?api-version=...&deployment=...", text: $viewModel.settings.openAIRealtime.azureRealtimeURL)
                        .textFieldStyle(.roundedBorder)
                        .pickyFont(size: 11, weight: .medium, design: .monospaced)
                        .onSubmit { saveImmediately(for: .mainAgent) }
                        .onChange(of: viewModel.settings.openAIRealtime.azureRealtimeURL) { _, _ in saveImmediately(for: .mainAgent) }
                    Text("settings.azure.realtimeUrlNote")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.field.model")
                    TextField("gpt-realtime-2", text: $viewModel.settings.openAIRealtime.modelOrDeployment)
                        .textFieldStyle(.roundedBorder)
                        .pickyFont(size: 11, weight: .medium, design: .monospaced)
                        .onSubmit { saveImmediately(for: .mainAgent) }
                        .onChange(of: viewModel.settings.openAIRealtime.modelOrDeployment) { _, _ in saveImmediately(for: .mainAgent) }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("settings.field.voice")
                        TextField("marin", text: $viewModel.settings.openAIRealtime.voice)
                            .textFieldStyle(.roundedBorder)
                            .pickyFont(size: 11, weight: .medium, design: .monospaced)
                            .onSubmit { saveImmediately(for: .mainAgent) }
                            .onChange(of: viewModel.settings.openAIRealtime.voice) { _, _ in saveImmediately(for: .mainAgent) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("settings.field.realtimeEffort")
                        Picker("settings.field.realtimeEffort", selection: $viewModel.settings.openAIRealtime.reasoningEffort) {
                            ForEach(PickyOpenAIRealtimeReasoningEffort.allCases) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: viewModel.settings.openAIRealtime.reasoningEffort) { _, _ in saveImmediately(for: .mainAgent) }
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.35))
        )
    }

    private var shortcutsSection: some View {
        sectionHeader(
            section: .shortcuts,
            title: L10n.t("settings.section.shortcuts.title"),
            subtitle: L10n.t("settings.section.shortcuts.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ShortcutSettingsRow(
                    title: L10n.t("settings.shortcuts.pushToTalk.title"),
                    subtitle: L10n.t("settings.shortcuts.pushToTalk.subtitle"),
                    allowance: .pushToTalk,
                    currentSpec: viewModel.settings.pushToTalkShortcut
                ) { newSpec in
                    saveShortcut(newSpec, keyPath: \.pushToTalkShortcut, conflictsWith: viewModel.settings.quickInputShortcut)
                }

                ShortcutSettingsRow(
                    title: L10n.t("settings.shortcuts.quickInput.title"),
                    subtitle: L10n.t("settings.shortcuts.quickInput.subtitle"),
                    allowance: .quickInput,
                    currentSpec: viewModel.settings.quickInputShortcut
                ) { newSpec in
                    saveShortcut(newSpec, keyPath: \.quickInputShortcut, conflictsWith: viewModel.settings.pushToTalkShortcut)
                }

                Button(action: resetShortcutsToDefaults) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .pickyFont(size: 10, weight: .semibold)
                        Text("common.resetDefaults")
                            .pickyFont(size: 11, weight: .semibold)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.surface1.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var generalSection: some View {
        sectionHeader(
            section: .general,
            title: L10n.t("settings.general.title"),
            subtitle: L10n.t("settings.general.subtitle.section")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("settings.general.language.label")
                    Picker("settings.general.language.label", selection: $viewModel.settings.appLanguage) {
                        ForEach(PickyLanguage.allCases) { language in
                            Text(String(localized: language.displayKey)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
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
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                pickyShellCommandSubsection
            }
        }
    }

    /// Settings entry that lets the user install or uninstall the `picky`
    /// shell command. Lives in General because Picky is an LSUIElement app
    /// whose panels never activate the macOS top menu bar, so a normal
    /// "Install Shell Command…" menu item would never be visible.
    private var pickyShellCommandSubsection: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("settings.general.shellCommand.label")

            Button(action: {
                ShellCommandMenuController.shared.showInstallerAlert()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .pickyFont(size: 10, weight: .semibold)
                    Text("settings.general.shellCommand.button")
                        .pickyFont(size: 11, weight: .semibold)
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Text("settings.general.shellCommand.note")
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var builtinToolsSection: some View {
        sectionHeader(section: .builtinTools, title: L10n.t("settings.section.builtinTools.title"), subtitle: L10n.t("settings.section.builtinTools.subtitle")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.section.builtinTools.note")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

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
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(tool.displayNameKey))
                        .pickyFont(size: 11.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(L10n.t(tool.descriptionKey))
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: tool.rawValue)
                        .pickyFont(size: 10, weight: .regular, design: .monospaced)
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
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

    private var onboardingSection: some View {
        sectionHeader(section: .onboarding, title: L10n.t("settings.section.onboarding.title"), subtitle: L10n.t("settings.section.onboarding.subtitle")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.section.onboarding.body")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: replayOnboarding) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .pickyFont(size: 10, weight: .semibold)
                        Text("settings.section.onboarding.replay")
                            .pickyFont(size: 11, weight: .semibold)
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.surface1.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var voiceSection: some View {
        sectionHeader(
            section: .voice,
            title: L10n.t("settings.section.voice.title"),
            subtitle: L10n.t("settings.section.voice.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // When the launch-time runtime is OpenAI Realtime, agentd owns
                // transcription through the Realtime session, so the dedicated
                // STT provider section is suppressed for this process. Changing
                // the desired runtime in Settings does not affect this until
                // Picky is restarted.
                if !AppBundleConfiguration.isRealtimeOnlyBuild {
                // ─── STT group ───
                VStack(alignment: .leading, spacing: 10) {
                    voiceSubgroupHeader("settings.voice.subgroup.stt")

                    providerPicker(title: "settings.voice.provider.stt", capability: .transcription, selection: $viewModel.settings.sttProvider)

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
                        voiceSecureField(
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
                        voiceTextField(
                            label: "settings.voice.openai.stt.baseUrl",
                            placeholder: L10n.t("settings.voice.openai.stt.baseUrl.placeholder"),
                            text: $openAISTTBaseURLDraft
                        )

                        Text("settings.voice.openaiBaseUrlNote")
                            .pickyFont(size: 10.5, weight: .medium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
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
                }

                voiceGroupDivider()
                }

                // ─── TTS group ───
                VStack(alignment: .leading, spacing: 10) {
                    voiceSubgroupHeader("settings.voice.subgroup.tts")

                    VStack(alignment: .leading, spacing: 4) {
                        toggleRow("settings.voice.toggle.ttsEnabled", isOn: $viewModel.settings.ttsEnabled, divider: false)
                        // On the Realtime runtime the model voices every
                        // assistant turn; `ttsEnabled` only gates onboarding
                        // narration there. The localized copy already
                        // describes the toggle generically.
                        Text("settings.tts.disabledNote")
                            .pickyFont(size: 10.5, weight: .medium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        toggleRow("settings.voice.toggle.narrationEnabled", isOn: $viewModel.settings.narrationEnabled, divider: false)
                        Text("settings.narration.disabledNote")
                            .pickyFont(size: 10.5, weight: .medium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Realtime runtime: only the bundled system TTS (Apple
                    // speech synthesizer) is available, and it is used solely
                    // for onboarding narration. Hide the provider picker and
                    // every external-API config block because Realtime owns
                    // assistant audio playback for this process.
                    if AppBundleConfiguration.isRealtimeOnlyBuild {
                        if viewModel.settings.ttsEnabled {
                            openMacOSSpeechSettingsButton
                        }
                    } else {
                    providerPicker(title: "settings.voice.provider.tts", capability: .speechPlayback, selection: $viewModel.settings.ttsProvider, isEnabled: viewModel.settings.ttsEnabled)

                    if viewModel.settings.ttsEnabled,
                       viewModel.settings.ttsProvider == .local {
                        openMacOSSpeechSettingsButton
                    }

                    if viewModel.settings.ttsEnabled, viewModel.settings.ttsProvider == .azure {
                        azureTextField(
                            label: "settings.voice.azure.tts.url",
                            placeholder: "{endpoint}/openai/deployments/{deploymentName}/audio/speech?api-version={apiVersion}",
                            text: $azureTTSEndpointDraft
                        )
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

                        Text("settings.azure.ttsUrlNote")
                            .pickyFont(size: 10.5, weight: .medium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(DS.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Spacer(minLength: 8)

                statusIndicator(for: section)
            }
            if let subtitle {
                Text(subtitle)
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
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
                    .pickyFont(size: 9, weight: .semibold)
                    .foregroundColor(DS.Colors.success)
                Text("common.saved")
                    .pickyFont(size: 10, weight: .medium)
                    .foregroundColor(DS.Colors.success)
            }
        case .dirty:
            Button(action: { commitEdits(in: section) }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .pickyFont(size: 9.5, weight: .semibold)
                    Text("common.save")
                        .pickyFont(size: 10.5, weight: .bold)
                }
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.accentText.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DS.Colors.accentText.opacity(0.38), lineWidth: 0.7)
                        )
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func azureTextField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .pickyFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    updateDraftStatus(for: .voice, isDirty: isVoiceDraftDirty())
                }
                .onSubmit { commitVoiceField() }
        }
    }

    private func azureSecureField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .pickyFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    updateDraftStatus(for: .voice, isDirty: isVoiceDraftDirty())
                }
                .onSubmit { commitVoiceField() }
        }
    }

    /// Sub-section label inside the Voice section. Visually subdues the STT vs TTS
    /// boundary using the same secondary text style as field labels — no big
    /// section chrome, just enough hierarchy to keep credential cards from
    /// blending together.
    private func voiceSubgroupHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .pickyFont(size: 10.5, weight: .semibold)
            .foregroundColor(DS.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.4)
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
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .pickyFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    updateDraftStatus(for: .voice, isDirty: isVoiceDraftDirty())
                }
                .onSubmit { commitVoiceField() }
        }
    }

    private func voiceSecureField(label: LocalizedStringKey, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .pickyFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    updateDraftStatus(for: .voice, isDirty: isVoiceDraftDirty())
                }
                .onSubmit { commitVoiceField() }
        }
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .pickyFont(size: 10.5, weight: .semibold)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private var dockSizePresetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("settings.field.dockSize")
            Picker("Dock size", selection: $viewModel.settings.hudDockSizePreset) {
                ForEach(PickyHUDDockSizePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .onChange(of: viewModel.settings.hudDockSizePreset) { _, _ in
                saveImmediately(for: .pickle)
            }

            Text("settings.field.dockSize.mediumNote")
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, divider: Bool, isEnabled: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .pickyFont(size: 11.5, weight: .medium)
                    .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                Spacer(minLength: 8)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .controlSize(.small)
                    .disabled(!isEnabled)
            }
            .padding(.vertical, 7)

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
        HStack(spacing: 7) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .pickyFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, newValue in onChange(newValue) }
                .onSubmit { onSubmit() }
            Button("common.choose") { onChoose() }
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(DS.Colors.accentText)
                .buttonStyle(.plain)
                .pointerCursor()
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
                    .pickyFont(size: 11, weight: .medium)
                Text("settings.macSpeechLink")
                    .pickyFont(size: 11, weight: .semibold)
                Image(systemName: "arrow.up.right")
                    .pickyFont(size: 9, weight: .semibold)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(L10n.t("settings.macSpeechLink.help"))
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
            PickyWorkspaceSeeder.seed(
                workspacePath: cwd,
                mainAgentRuntimeMode: AppBundleConfiguration.effectiveRuntimeMode
            )
            let url = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(PickyWorkspaceSeeder.agentsMarkdownFilename, isDirectory: false)
            NSWorkspace.shared.open(url)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .pickyFont(size: 11, weight: .medium)
                Text("settings.action.openAgentsFile")
                    .pickyFont(size: 11, weight: .semibold)
                Image(systemName: "arrow.up.right")
                    .pickyFont(size: 9, weight: .semibold)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func providerPicker(title: LocalizedStringKey, capability: PickyVoiceProviderCapability, selection: Binding<PickyVoiceProviderSelection>, isEnabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(title)
            Picker(title, selection: selection) {
                ForEach(PickyVoiceProviderSelection.cases(for: capability)) { provider in
                    Text(provider.displayName(for: capability)).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
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
        case .general:
            saveImmediately(for: .general)
        case .mainAgent:
            commitMainAgentCwdField()
        case .pickle:
            commitPickleCwdField()
        case .overlayAndNotifications:
            saveImmediately(for: .overlayAndNotifications)
        case .voice:
            commitVoiceField()
        case .shortcuts:
            saveImmediately(for: .shortcuts)
        case .builtinTools:
            saveImmediately(for: .builtinTools)
        case .onboarding:
            break
        }
    }

    /// Persists the new shortcut spec via the view-model. The view-model
    /// refuses the change when it would collide with the other shortcut so
    /// the runtime never has two paths fighting over the same keypress.
    private func saveShortcut(
        _ newSpec: PickyShortcutSpec,
        keyPath: WritableKeyPath<PickySettings, PickyShortcutSpec>,
        conflictsWith other: PickyShortcutSpec
    ) {
        let succeeded = viewModel.updateShortcut(newSpec, keyPath: keyPath, conflictsWith: other)
        if succeeded {
            saveStatuses.markSaved(.shortcuts)
            scheduleSaveStatusReset(for: .shortcuts)
        } else {
            saveStatuses.markDirty(.shortcuts)
        }
    }

    private func resetShortcutsToDefaults() {
        if viewModel.resetShortcutsToDefaults() {
            saveStatuses.markSaved(.shortcuts)
            scheduleSaveStatusReset(for: .shortcuts)
        } else {
            saveStatuses.markDirty(.shortcuts)
        }
    }

    /// Flips the persisted onboarding revision back to zero so the takeover
    /// overlay reappears on the next app launch. The actual overlay wiring
    /// lands in a later phase; for now flipping the flag is the user-visible
    /// contract.
    private func replayOnboarding() {
        viewModel.settings.onboardingCompletedVersion = 0
        let succeeded = viewModel.save()
        if succeeded {
            saveStatuses.markSaved(.onboarding)
            scheduleSaveStatusReset(for: .onboarding)
        } else {
            saveStatuses.markDirty(.onboarding)
        }
    }

    private func quitPickyForRuntimeRestart() {
        NSApp.terminate(nil)
    }

    private func commitMainAgentCwdField() {
        viewModel.settings.mainAgentCwd = mainAgentCwdDraft
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
        viewModel.settings.elevenLabsSTTAPIKey = elevenLabsSTTAPIKeyDraft
        viewModel.settings.elevenLabsSTTModel = elevenLabsSTTModelDraft
        viewModel.settings.elevenLabsSTTLanguage = elevenLabsSTTLanguageDraft
        saveImmediately(for: .voice)
    }

    private func chooseMainAgentDirectory() {
        chooseDirectory(initialPath: mainAgentCwdDraft) { url in
            mainAgentCwdDraft = url.path
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
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: initialPath).expandingTildeInPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commit(url)
    }

    /// Persist whatever is currently in `viewModel.settings`, then briefly flash the
    /// saved indicator for the section that changed. On validation failure only that
    /// section falls back to dirty; the validation message itself renders at the
    /// bottom of the form.
    private func saveImmediately(for section: CompanionPanelSettingsSection) {
        if section == .mainAgent, mainAgentCwdDraft != viewModel.settings.mainAgentCwd {
            viewModel.settings.mainAgentCwd = mainAgentCwdDraft
        }
        let shouldPreserveDirtyPickleDraft = section == .pickle && pickleCwdDraft != viewModel.settings.defaultCwd
        let succeeded = viewModel.save()
        if succeeded {
            if !shouldPreserveDirtyPickleDraft {
                syncDraft(for: section)
                saveStatuses.markSaved(section)
                scheduleSaveStatusReset(for: section)
            } else {
                saveStatuses.markDirty(section)
            }
        } else {
            saveStatuses.markDirty(section)
            saveStatusResets[section]?.cancel()
            saveStatusResets[section] = nil
        }
    }

    private func syncDraft(for section: CompanionPanelSettingsSection) {
        switch section {
        case .mainAgent:
            mainAgentCwdDraft = viewModel.settings.mainAgentCwd
        case .pickle:
            pickleCwdDraft = viewModel.settings.defaultCwd
        case .general, .overlayAndNotifications, .shortcuts, .builtinTools, .onboarding:
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
        elevenLabsSTTAPIKeyDraft = viewModel.settings.elevenLabsSTTAPIKey
        elevenLabsSTTModelDraft = viewModel.settings.elevenLabsSTTModel
        elevenLabsSTTLanguageDraft = viewModel.settings.elevenLabsSTTLanguage
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
            || elevenLabsSTTAPIKeyDraft != viewModel.settings.elevenLabsSTTAPIKey
            || elevenLabsSTTModelDraft != viewModel.settings.elevenLabsSTTModel
            || elevenLabsSTTLanguageDraft != viewModel.settings.elevenLabsSTTLanguage
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

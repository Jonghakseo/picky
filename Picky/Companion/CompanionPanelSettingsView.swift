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
    case mainAgent
    case pickle
    case notification
    case cursorBubbles
    case voice
    case shortcuts
}

/// One screen of the Settings tab. The index screen lists the categories;
/// every other case is a leaf page hosting that category's content. Adding a
/// new category amounts to: extend this enum, add a label/subtitle, and route
/// to the matching helper view inside CompanionPanelSettingsView.
enum CompanionPanelSettingsRoute: Hashable {
    case index
    case mainAgent
    case pickle
    case notification
    case cursorBubbles
    case voice
    case shortcuts

    var section: CompanionPanelSettingsSection? {
        switch self {
        case .index: nil
        case .mainAgent: .mainAgent
        case .pickle: .pickle
        case .notification: .notification
        case .cursorBubbles: .cursorBubbles
        case .voice: .voice
        case .shortcuts: .shortcuts
        }
    }

    var title: String {
        switch self {
        case .index: "Settings"
        case .mainAgent: "Picky"
        case .pickle: "Pickle"
        case .notification: "Notification"
        case .cursorBubbles: "Cursor & Bubbles"
        case .voice: "Voice (STT & TTS)"
        case .shortcuts: "Shortcuts"
        }
    }

    var subtitle: String? {
        switch self {
        case .index: nil
        case .mainAgent: "Runtime, cwd, reasoning, and captured screen context."
        case .pickle: "Default folder for Pickles."
        case .notification: "Banners for session events."
        case .cursorBubbles: "Pi cursor visibility, small animations, and speech bubbles."
        case .voice: "Speech providers and language."
        case .shortcuts: "Push to Talk and Quick Input bindings."
        }
    }
}

/// Order of the categories shown on the Settings index. Kept separate from
/// the enum so we can rearrange without disturbing the type.
private let companionPanelSettingsRouteOrder: [CompanionPanelSettingsRoute] = [
    .mainAgent,
    .pickle,
    .notification,
    .cursorBubbles,
    .voice,
    .shortcuts
]

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
    @State private var mainAgentCwdDraft: String = ""
    @State private var pickleCwdDraft: String = ""
    @State private var azureSTTEndpointDraft: String = ""
    @State private var azureSTTAPIKeyDraft: String = ""
    @State private var azureTTSEndpointDraft: String = ""
    @State private var azureTTSAPIKeyDraft: String = ""
    @State private var azureTTSVoiceDraft: String = ""
    @State private var azureLanguageDraft: String = ""
    @State private var saveStatuses = CompanionPanelSettingsSaveStatuses()
    @State private var saveStatusResets: [CompanionPanelSettingsSection: AnyCancellable] = [:]
    @State private var route: CompanionPanelSettingsRoute = .index

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navHeader
            content

            if route != .index, let error = viewModel.validationError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .animation(.easeOut(duration: 0.16), value: route)
        .onAppear {
            mainAgentCwdDraft = viewModel.settings.mainAgentCwd
            pickleCwdDraft = viewModel.settings.defaultCwd
            syncAzureDrafts()
        }
        .onChange(of: viewModel.settings.notifications) { _, _ in
            // Toggles only flip booleans, so they cannot fail directory validation.
            // Persist immediately and flash the saved indicator next to the changed
            // section only. Draft text in other sections remains untouched.
            saveImmediately(for: .notification)
        }
        .onChange(of: viewModel.settings.cursor) { _, _ in
            saveImmediately(for: .cursorBubbles)
        }
        .onChange(of: viewModel.settings.overlayBubbles) { _, _ in
            saveImmediately(for: .cursorBubbles)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .index: indexView
        case .mainAgent: mainAgentSection
        case .pickle: pickleSection
        case .notification: notificationSection
        case .cursorBubbles: cursorBubblesSection
        case .voice: voiceSection
        case .shortcuts: shortcutsSection
        }
    }

    @ViewBuilder
    private var navHeader: some View {
        if route != .index {
            HStack(spacing: 8) {
                Button(action: { route = .index }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 11.5, weight: .medium))
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
            ForEach(Array(companionPanelSettingsRouteOrder.enumerated()), id: \.element) { index, item in
                Button(action: { route = item }) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        if let section = item.section {
                            statusIndicator(for: section)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if index < companionPanelSettingsRouteOrder.count - 1 {
                    Divider()
                        .background(DS.Colors.borderSubtle.opacity(0.3))
                }
            }
        }
    }

    private var pickleSection: some View {
        sectionHeader(section: .pickle, title: "Pickle") {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Default cwd")
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
        }
    }

    private var notificationSection: some View {
        sectionHeader(section: .notification, title: "Notification", subtitle: "Pick which session events raise a banner.") {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("On success", isOn: $viewModel.settings.notifications.notifyOnCompleted, divider: true)
                toggleRow("On failure", isOn: $viewModel.settings.notifications.notifyOnFailed, divider: true)
                toggleRow("On input request", isOn: $viewModel.settings.notifications.notifyOnWaitingForInput, divider: false)
            }
        }
    }

    private var cursorBubblesSection: some View {
        sectionHeader(section: .cursorBubbles, title: "Cursor & Bubbles", subtitle: "Control the Pi cursor overlay, animations, and nearby speech bubbles.") {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("Show Picky Cursor", isOn: $viewModel.settings.cursor.showPiCursor, divider: true)
                toggleRow(
                    "Smooth cursor follow",
                    isOn: $viewModel.settings.cursor.enableFollowSpringAnimation,
                    divider: true,
                    isEnabled: viewModel.settings.cursor.showPiCursor
                )
                toggleRow(
                    "Idle animations",
                    isOn: $viewModel.settings.cursor.enableIdleAnimations,
                    divider: true,
                    isEnabled: viewModel.settings.cursor.showPiCursor
                )
                toggleRow(
                    "User STT recognition",
                    isOn: $viewModel.settings.overlayBubbles.showUserSpeechRecognitionBubble,
                    divider: true
                )
                toggleRow(
                    "Picky reply text",
                    isOn: $viewModel.settings.overlayBubbles.showPickyResponseBubble,
                    divider: false
                )

                if !viewModel.settings.cursor.showPiCursor {
                    Text("Smooth follow and idle animations are disabled while the Pi cursor is hidden.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }
            }
        }
    }

    private var mainAgentSection: some View {
        sectionHeader(section: .mainAgent, title: "Picky", subtitle: "Runtime, cwd, reasoning, captured screens, and standing instructions.") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Picky cwd")
                    cwdField(
                        placeholder: "~/",
                        text: $mainAgentCwdDraft,
                        onChange: { newValue in
                            updateDraftStatus(for: .mainAgent, isDirty: newValue != viewModel.settings.mainAgentCwd)
                        },
                        onSubmit: commitMainAgentCwdField,
                        onChoose: chooseMainAgentDirectory
                    )
                    Text("Applies to captured Picky context and the next Picky session.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if AppBundleConfiguration.realtimeOptIn {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Runtime")
                        Picker("Runtime", selection: $viewModel.settings.mainAgentRuntimeMode) {
                            ForEach(PickyMainAgentRuntimeMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: viewModel.settings.mainAgentRuntimeMode) { _, _ in saveImmediately(for: .mainAgent) }

                        Text(viewModel.settings.mainAgentRuntimeMode == .openAIRealtime
                             ? "Picky voice uses OpenAI/Azure Realtime audio. Pickle-hover voice follow-ups still go directly to Pickles."
                             : "Default local Pi Picky flow. Existing STT/TTS providers are unchanged.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if viewModel.settings.mainAgentRuntimeMode == .openAIRealtime {
                        realtimeSettingsFields
                    } else {
                        piMainAgentModelPicker
                    }
                } else {
                    piMainAgentModelPicker
                }

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Reasoning level")
                    Picker("Reasoning level", selection: $viewModel.settings.mainAgentThinkingLevel) {
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
                    fieldLabel("Screen context")
                    Picker("Screen context", selection: $viewModel.settings.screenContextScope) {
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
                    fieldLabel("Additional instructions")
                    Text("Baked into the Picky bootstrap. Edits apply on the next Picky session — reset Picky or relaunch Picky to pick up changes mid-session.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    TextEditor(text: $viewModel.settings.mainAgentExtraInstructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 96, maxHeight: 200)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(DS.Colors.surface2.opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
                        )
                        .scrollContentBackground(.hidden)
                        .onChange(of: viewModel.settings.mainAgentExtraInstructions) { _, _ in saveImmediately(for: .mainAgent) }
                }
            }
        }
    }

    private var piMainAgentModelPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                fieldLabel("Pi model")
                if companionManager.isLoadingMainAgentModelOptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
            }
            Picker("Pi model", selection: $viewModel.settings.mainAgentModelPattern) {
                Text("Automatic (Pi default)").tag("")
                if shouldShowSavedMainAgentModelOption {
                    Text("Saved: \(viewModel.settings.mainAgentModelPattern)").tag(viewModel.settings.mainAgentModelPattern)
                }
                ForEach(companionManager.mainAgentModelOptions) { option in
                    Text(option.displayName).tag(option.pattern)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: viewModel.settings.mainAgentModelPattern) { _, _ in saveImmediately(for: .mainAgent) }
            .task { companionManager.refreshMainAgentModelOptions() }

            Text("Choose Automatic to follow Pi settings, or pick a model to pin Picky. Reasoning level below is applied with the pinned model.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shouldShowSavedMainAgentModelOption: Bool {
        let saved = viewModel.settings.mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return false }
        return !companionManager.mainAgentModelOptions.contains { $0.pattern == saved }
    }

    private var realtimeSettingsFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Realtime provider")
                Picker("Realtime provider", selection: $viewModel.settings.openAIRealtime.provider) {
                    ForEach(PickyOpenAIRealtimeProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: viewModel.settings.openAIRealtime.provider) { _, _ in saveImmediately(for: .mainAgent) }
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("API key")
                SecureField(viewModel.settings.openAIRealtime.provider == .azureOpenAI ? "Azure OpenAI API key" : "sk-…", text: $viewModel.settings.openAIRealtime.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .onSubmit { saveImmediately(for: .mainAgent) }
                    .onChange(of: viewModel.settings.openAIRealtime.apiKey) { _, _ in saveImmediately(for: .mainAgent) }
            }

            if viewModel.settings.openAIRealtime.provider == .azureOpenAI {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Azure Realtime URL")
                    TextField("https://resource.openai.azure.com/openai/realtime?api-version=...&deployment=...", text: $viewModel.settings.openAIRealtime.azureRealtimeURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .onSubmit { saveImmediately(for: .mainAgent) }
                        .onChange(of: viewModel.settings.openAIRealtime.azureRealtimeURL) { _, _ in saveImmediately(for: .mainAgent) }
                    Text("Paste the full Azure Realtime URL. Picky derives deployment, API version, and preview/GA shape from it.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Model")
                    TextField("gpt-realtime-2", text: $viewModel.settings.openAIRealtime.modelOrDeployment)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .onSubmit { saveImmediately(for: .mainAgent) }
                        .onChange(of: viewModel.settings.openAIRealtime.modelOrDeployment) { _, _ in saveImmediately(for: .mainAgent) }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Voice")
                        TextField("marin", text: $viewModel.settings.openAIRealtime.voice)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .onSubmit { saveImmediately(for: .mainAgent) }
                            .onChange(of: viewModel.settings.openAIRealtime.voice) { _, _ in saveImmediately(for: .mainAgent) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Realtime effort")
                        Picker("Realtime effort", selection: $viewModel.settings.openAIRealtime.reasoningEffort) {
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
        sectionHeader(section: .shortcuts, title: "Shortcuts", subtitle: "Customize the global shortcuts for voice and quick text input.") {
            VStack(alignment: .leading, spacing: 14) {
                ShortcutSettingsRow(
                    title: "Push to Talk",
                    subtitle: "Hold to start a voice session. Release to send.",
                    allowance: .pushToTalk,
                    currentSpec: viewModel.settings.pushToTalkShortcut
                ) { newSpec in
                    saveShortcut(newSpec, keyPath: \.pushToTalkShortcut, conflictsWith: viewModel.settings.quickInputShortcut)
                }

                ShortcutSettingsRow(
                    title: "Quick Input",
                    subtitle: "Press to open the text composer.",
                    allowance: .quickInput,
                    currentSpec: viewModel.settings.quickInputShortcut
                ) { newSpec in
                    saveShortcut(newSpec, keyPath: \.quickInputShortcut, conflictsWith: viewModel.settings.pushToTalkShortcut)
                }

                Button(action: resetShortcutsToDefaults) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Reset to defaults")
                            .font(.system(size: 11, weight: .semibold))
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
        sectionHeader(section: .voice, title: "Voice (STT & TTS)", subtitle: "Speech providers. Azure STT and TTS use separate operation URLs; the Azure resource base may still be the same.") {
            VStack(alignment: .leading, spacing: 10) {
                providerPicker(title: "STT provider", capability: .transcription, selection: $viewModel.settings.sttProvider)
                providerPicker(title: "TTS provider", capability: .speechPlayback, selection: $viewModel.settings.ttsProvider)

                if viewModel.settings.ttsProvider == .local || viewModel.settings.ttsProvider == .automatic {
                    openMacOSSpeechSettingsButton
                }

                if viewModel.settings.sttProvider == .azure {
                    azureTextField(
                        label: "Azure STT transcription URL",
                        placeholder: "{endpoint}/openai/deployments/{deploymentName}/audio/transcriptions?api-version={apiVersion}",
                        text: $azureSTTEndpointDraft
                    )

                    azureSecureField(
                        label: "Azure STT API key",
                        placeholder: "AZURE_OPENAI_API_KEY",
                        text: $azureSTTAPIKeyDraft
                    )

                    azureTextField(
                        label: "Azure STT preferred language",
                        placeholder: "Auto detect, or e.g. ko / en",
                        text: $azureLanguageDraft
                    )
                }

                if viewModel.settings.ttsProvider == .azure {
                    azureTextField(
                        label: "Azure TTS speech URL",
                        placeholder: "{endpoint}/openai/deployments/{deploymentName}/audio/speech?api-version={apiVersion}",
                        text: $azureTTSEndpointDraft
                    )

                    azureSecureField(
                        label: "Azure TTS API key",
                        placeholder: "Leave empty to reuse the STT API key",
                        text: $azureTTSAPIKeyDraft
                    )

                    azureTextField(
                        label: "Azure TTS voice",
                        placeholder: "nova, alloy, shimmer, etc.",
                        text: $azureTTSVoiceDraft
                    )

                    Text("TTS should use the /audio/speech URL. It can share the same Azure resource and key as STT, but usually has its own deployment. The model/deployment is parsed from the URL.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Spacer(minLength: 8)

                statusIndicator(for: section)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.success)
                Text("Saved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            }
        case .dirty:
            Button(action: { commitEdits(in: section) }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("Save changes")
                        .font(.system(size: 10.5, weight: .bold))
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

    private func azureTextField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    updateDraftStatus(for: .voice, isDirty: isAzureDraftDirty())
                }
                .onSubmit { commitAzureField() }
        }
    }

    private func azureSecureField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    updateDraftStatus(for: .voice, isDirty: isAzureDraftDirty())
                }
                .onSubmit { commitAzureField() }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, divider: Bool, isEnabled: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                Spacer(minLength: 8)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
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
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
                .onChange(of: text.wrappedValue) { _, newValue in onChange(newValue) }
                .onSubmit { onSubmit() }
            Button("Choose") { onChoose() }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .buttonStyle(.plain)
                .pointerCursor()
        }
    }

    /// Opens the Spoken Content pane in System Settings so users can pick the
    /// system voice that `NSSpeechSynthesizer` (the local TTS provider) reads with.
    private var openMacOSSpeechSettingsButton: some View {
        Button(action: {
            // Sonoma+ Settings URL for Accessibility > Spoken Content. The voice
            // selected there is what `NSSpeechSynthesizer()` (no explicit voice)
            // uses, which is what PickySystemSpeechPlaybackProvider does today.
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Speech") else { return }
            NSWorkspace.shared.open(url)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium))
                Text("Open macOS Speech Settings")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
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
        .help("Choose the system voice used by Picky's local TTS in System Settings → Accessibility → Spoken Content.")
    }

    private func providerPicker(title: String, capability: PickyVoiceProviderCapability, selection: Binding<PickyVoiceProviderSelection>) -> some View {
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
            .onChange(of: selection.wrappedValue) { _, _ in saveImmediately(for: .voice) }
        }
    }

    /// Submit handler shared by text field Return keys and the section-local "Save"
    /// button shown in `.dirty` mode. Only folds the edited section draft back into
    /// the view-model so unrelated dirty sections keep their unsaved text intact.
    private func commitEdits(in section: CompanionPanelSettingsSection) {
        switch section {
        case .mainAgent:
            commitMainAgentCwdField()
        case .pickle:
            commitPickleCwdField()
        case .notification:
            saveImmediately(for: .notification)
        case .cursorBubbles:
            saveImmediately(for: .cursorBubbles)
        case .voice:
            commitAzureField()
        case .shortcuts:
            saveImmediately(for: .shortcuts)
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

    private func commitMainAgentCwdField() {
        viewModel.settings.mainAgentCwd = mainAgentCwdDraft
        saveImmediately(for: .mainAgent)
    }

    private func commitPickleCwdField() {
        viewModel.settings.defaultCwd = pickleCwdDraft
        saveImmediately(for: .pickle)
    }

    private func commitAzureField() {
        viewModel.settings.azureOpenAIEndpoint = azureSTTEndpointDraft
        viewModel.settings.azureOpenAIAPIKey = azureSTTAPIKeyDraft
        viewModel.settings.azureOpenAITTSEndpoint = azureTTSEndpointDraft
        viewModel.settings.azureOpenAITTSAPIKey = azureTTSAPIKeyDraft
        viewModel.settings.azureOpenAITTSVoice = azureTTSVoiceDraft
        viewModel.settings.azureSTTPreferredLanguage = azureLanguageDraft
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
        let succeeded = viewModel.save()
        if succeeded {
            syncDraft(for: section)
            saveStatuses.markSaved(section)
            scheduleSaveStatusReset(for: section)
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
        case .notification, .cursorBubbles, .shortcuts:
            break
        case .voice:
            syncAzureDrafts()
        }
    }

    private func syncAzureDrafts() {
        azureSTTEndpointDraft = viewModel.settings.azureOpenAIEndpoint
        azureSTTAPIKeyDraft = viewModel.settings.azureOpenAIAPIKey
        azureTTSEndpointDraft = viewModel.settings.azureOpenAITTSEndpoint
        azureTTSAPIKeyDraft = viewModel.settings.azureOpenAITTSAPIKey
        azureTTSVoiceDraft = viewModel.settings.azureOpenAITTSVoice
        azureLanguageDraft = viewModel.settings.azureSTTPreferredLanguage
    }

    private func isAzureDraftDirty() -> Bool {
        azureSTTEndpointDraft != viewModel.settings.azureOpenAIEndpoint
            || azureSTTAPIKeyDraft != viewModel.settings.azureOpenAIAPIKey
            || azureTTSEndpointDraft != viewModel.settings.azureOpenAITTSEndpoint
            || azureTTSAPIKeyDraft != viewModel.settings.azureOpenAITTSAPIKey
            || azureTTSVoiceDraft != viewModel.settings.azureOpenAITTSVoice
            || azureLanguageDraft != viewModel.settings.azureSTTPreferredLanguage
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

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
    case workspace
    case notifications
    case mainAgent
    case voice
    case shortcuts
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
    @State private var pathDraft: String = ""
    @State private var azureDraft: String = ""
    @State private var saveStatuses = CompanionPanelSettingsSaveStatuses()
    @State private var saveStatusResets: [CompanionPanelSettingsSection: AnyCancellable] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceSection
            sectionDivider
            notificationsSection
            sectionDivider
            mainAgentSection
            sectionDivider
            voiceSection
            sectionDivider
            shortcutsSection

            if let error = viewModel.validationError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .onAppear {
            pathDraft = viewModel.settings.defaultCwd
            azureDraft = viewModel.settings.azureSTTPreferredLanguage
        }
        .onChange(of: viewModel.settings.notifications) { _, _ in
            // Toggles only flip booleans, so they cannot fail directory validation.
            // Persist immediately and flash the saved indicator next to the changed
            // section only. Draft text in other sections remains untouched.
            saveImmediately(for: .notifications)
        }
    }

    private var workspaceSection: some View {
        sectionHeader(section: .workspace, title: "Workspace") {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Default folder")
                HStack(spacing: 7) {
                    TextField("~/", text: $pathDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                        )
                        .onChange(of: pathDraft) { _, newValue in
                            // The user is mid-type; mark this section dirty until they
                            // either submit (Return), pick a folder, or revert to the
                            // persisted value. Submitting routes through onSubmit below.
                            updateDraftStatus(for: .workspace, isDirty: newValue != viewModel.settings.defaultCwd)
                        }
                        .onSubmit { commitPathField() }
                    Button("Choose") { chooseDirectory() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                        .buttonStyle(.plain)
                        .pointerCursor()
                }
            }
        }
    }

    private var notificationsSection: some View {
        sectionHeader(section: .notifications, title: "Notifications", subtitle: "Pick which session events raise a banner.") {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("On success", isOn: $viewModel.settings.notifications.notifyOnCompleted, divider: true)
                toggleRow("On failure", isOn: $viewModel.settings.notifications.notifyOnFailed, divider: true)
                toggleRow("On input request", isOn: $viewModel.settings.notifications.notifyOnWaitingForInput, divider: false)
            }
        }
    }

    private var mainAgentSection: some View {
        sectionHeader(section: .mainAgent, title: "Main Agent", subtitle: "Reasoning level for the always-on command agent.") {
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
        }
    }

    private var shortcutsSection: some View {
        sectionHeader(section: .shortcuts, title: "Shortcuts", subtitle: "단축키를 자유롭게 설정하세요.") {
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
        sectionHeader(section: .voice, title: "Voice", subtitle: "Speech providers. Azure secrets stay in Keychain.") {
            VStack(alignment: .leading, spacing: 10) {
                providerPicker(title: "STT provider", capability: .transcription, selection: $viewModel.settings.sttProvider)
                providerPicker(title: "TTS provider", capability: .speechPlayback, selection: $viewModel.settings.ttsProvider)
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Azure STT preferred language")
                    TextField("Auto detect, or e.g. ko / en", text: $azureDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                        )
                        .onChange(of: azureDraft) { _, newValue in
                            updateDraftStatus(for: .voice, isDirty: newValue != viewModel.settings.azureSTTPreferredLanguage)
                        }
                        .onSubmit { commitAzureField() }
                }
            }
        }
    }

    private var sectionDivider: some View {
        Divider()
            .background(DS.Colors.borderSubtle.opacity(0.4))
            .padding(.vertical, 14)
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
    /// section headers stay quiet when nothing has changed. The `.dirty` state nudges
    /// the user to hit Return on a text field; toggles never enter `.dirty`.
    @ViewBuilder
    private func statusIndicator(for section: CompanionPanelSettingsSection) -> some View {
        switch saveStatuses[section] {
        case .idle:
            EmptyView()
        case .saved:
            HStack(spacing: 4) {
                Circle().fill(DS.Colors.success).frame(width: 5, height: 5)
                Text("Saved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            }
        case .dirty:
            Button(action: { commitEdits(in: section) }) {
                Text("Save")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, divider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.vertical, 7)

            if divider {
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.3))
            }
        }
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
        case .workspace:
            commitPathField()
        case .notifications:
            saveImmediately(for: .notifications)
        case .mainAgent:
            saveImmediately(for: .mainAgent)
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

    private func commitPathField() {
        viewModel.settings.defaultCwd = pathDraft
        saveImmediately(for: .workspace)
    }

    private func commitAzureField() {
        viewModel.settings.azureSTTPreferredLanguage = azureDraft
        saveImmediately(for: .voice)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: pathDraft).expandingTildeInPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathDraft = url.path
        commitPathField()
    }

    /// Persist whatever is currently in `viewModel.settings`, then briefly flash the
    /// saved indicator for the section that changed. On validation failure only that
    /// section falls back to dirty; the validation message itself renders at the
    /// bottom of the form.
    private func saveImmediately(for section: CompanionPanelSettingsSection) {
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
        case .workspace:
            pathDraft = viewModel.settings.defaultCwd
        case .notifications, .mainAgent, .shortcuts:
            break
        case .voice:
            azureDraft = viewModel.settings.azureSTTPreferredLanguage
        }
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

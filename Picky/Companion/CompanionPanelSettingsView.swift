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

struct CompanionPanelSettingsView: View {
    @ObservedObject var viewModel: PickySettingsViewModel
    @State private var pathDraft: String = ""
    @State private var azureDraft: String = ""
    @State private var saveStatus: SaveStatus = .idle
    @State private var saveStatusReset: AnyCancellable?

    /// Tristate banner used for autosave feedback. `.idle` hides the indicator,
    /// `.saved` flashes briefly after a successful write, `.dirty` stays visible
    /// until the user submits a text field that still differs from disk state.
    enum SaveStatus: Equatable { case idle, saved, dirty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceSection
            sectionDivider
            notificationsSection
            sectionDivider
            voiceSection

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
            // Persist immediately and flash the saved indicator next to the section
            // header. If the user has unsaved text edits queued in `pathDraft` /
            // `azureDraft`, those still need an explicit save (Return), so leave
            // the dirty banner alone.
            saveImmediately()
        }
    }

    private var workspaceSection: some View {
        sectionHeader(title: "Workspace") {
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
                            // The user is mid-type; mark dirty until they either submit
                            // (Return) or pick a folder via the panel. Submitting routes
                            // through onSubmit below.
                            if newValue != viewModel.settings.defaultCwd { markDirty() }
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
        sectionHeader(title: "Notifications", subtitle: "Pick which session events raise a banner.") {
            VStack(alignment: .leading, spacing: 0) {
                toggleRow("On success", isOn: $viewModel.settings.notifications.notifyOnCompleted, divider: true)
                toggleRow("On failure", isOn: $viewModel.settings.notifications.notifyOnFailed, divider: true)
                toggleRow("On input request", isOn: $viewModel.settings.notifications.notifyOnWaitingForInput, divider: false)
            }
        }
    }

    private var voiceSection: some View {
        sectionHeader(title: "Voice", subtitle: "Speech providers. Azure secrets stay in Keychain.") {
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
                            if newValue != viewModel.settings.azureSTTPreferredLanguage { markDirty() }
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

                statusIndicator
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
    private var statusIndicator: some View {
        switch saveStatus {
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
            Button(action: commitTextEdits) {
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
            .onChange(of: selection.wrappedValue) { _, _ in saveImmediately() }
        }
    }

    /// Submit handler shared by the Workspace path field's Return key and the global
    /// "Save" button shown in `.dirty` mode. Folds both pending text drafts back into
    /// the view-model in one shot so `viewModel.save()` validates everything together.
    private func commitTextEdits() {
        viewModel.settings.defaultCwd = pathDraft
        viewModel.settings.azureSTTPreferredLanguage = azureDraft
        saveImmediately()
    }

    private func commitPathField() {
        viewModel.settings.defaultCwd = pathDraft
        saveImmediately()
    }

    private func commitAzureField() {
        viewModel.settings.azureSTTPreferredLanguage = azureDraft
        saveImmediately()
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
    /// saved indicator. On validation failure the status falls back to dirty so the
    /// user has a visible affordance to retry; the validation message itself renders
    /// at the bottom of the form.
    private func saveImmediately() {
        let succeeded = viewModel.save()
        if succeeded {
            // Sync drafts back to the persisted snapshot so subsequent typing is compared
            // against the up-to-date baseline (otherwise the dirty heuristic stays stuck).
            pathDraft = viewModel.settings.defaultCwd
            azureDraft = viewModel.settings.azureSTTPreferredLanguage
            saveStatus = .saved
            scheduleSaveStatusReset()
        } else {
            saveStatus = .dirty
            saveStatusReset?.cancel()
        }
    }

    private func markDirty() {
        guard saveStatus != .dirty else { return }
        saveStatus = .dirty
        saveStatusReset?.cancel()
    }

    private func scheduleSaveStatusReset() {
        saveStatusReset?.cancel()
        saveStatusReset = Just(())
            .delay(for: .seconds(1.6), scheduler: RunLoop.main)
            .sink { _ in
                if saveStatus == .saved { saveStatus = .idle }
            }
    }
}

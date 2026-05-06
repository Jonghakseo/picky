//
//  PickySettingsView.swift
//  Picky
//

import SwiftUI

struct PickySettingsView: View {
    @ObservedObject var viewModel: PickySettingsViewModel

    var body: some View {
        Form {
            Section("Workspace") {
                TextField("Default cwd", text: $viewModel.settings.defaultCwd)
                TextField("Worktree parent", text: $viewModel.settings.worktreeParent)
                TextField("Preferred tool visibility", text: $viewModel.settings.preferredToolVisibility)
                Toggle("Prefer read-only investigation context", isOn: $viewModel.settings.readOnlyInvestigationPreference)
            }

            Section("Notifications") {
                Toggle("On success", isOn: $viewModel.settings.notifications.notifyOnCompleted)
                Toggle("On failure", isOn: $viewModel.settings.notifications.notifyOnFailed)
                Toggle("On input request", isOn: $viewModel.settings.notifications.notifyOnWaitingForInput)
            }

            Section("Main Agent") {
                Picker("Reasoning level", selection: $viewModel.settings.mainAgentThinkingLevel) {
                    ForEach(PickyMainAgentThinkingLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Picker("Screen context", selection: $viewModel.settings.screenContextScope) {
                    ForEach(PickyScreenContextScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Additional instructions")
                    Text("Baked into the main-agent bootstrap. Reset the main agent to apply edits mid-session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $viewModel.settings.mainAgentExtraInstructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                        )
                }
            }

            Section("Voice") {
                Picker("STT provider", selection: $viewModel.settings.sttProvider) {
                    ForEach(PickyVoiceProviderSelection.cases(for: .transcription)) { provider in
                        Text(provider.displayName(for: .transcription)).tag(provider)
                    }
                }
                Picker("TTS provider", selection: $viewModel.settings.ttsProvider) {
                    ForEach(PickyVoiceProviderSelection.cases(for: .speechPlayback)) { provider in
                        Text(provider.displayName(for: .speechPlayback)).tag(provider)
                    }
                }
                TextField("Azure STT preferred language (blank = auto, e.g. ko, en)", text: $viewModel.settings.azureSTTPreferredLanguage)
            }

            Section("Diagnostics") {
                LabeledContent("Daemon", value: viewModel.settings.daemonPath)
                LabeledContent("Logs", value: viewModel.settings.logPath)
            }

            if let error = viewModel.validationError {
                Text(error).foregroundColor(.red)
            }
            Button("Save") { _ = viewModel.save() }
        }
        .padding()
        .frame(width: 520)
    }
}

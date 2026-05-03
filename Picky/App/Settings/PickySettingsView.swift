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

//
//  PickySettingsView.swift
//  Picky
//

import SwiftUI

struct PickySettingsView: View {
    @ObservedObject var viewModel: PickySettingsViewModel

    var body: some View {
        Form {
            TextField("Default cwd", text: $viewModel.settings.defaultCwd)
            TextField("Worktree parent", text: $viewModel.settings.worktreeParent)
            TextField("Preferred tool visibility", text: $viewModel.settings.preferredToolVisibility)
            Toggle("Prefer read-only investigation context", isOn: $viewModel.settings.readOnlyInvestigationPreference)
            LabeledContent("Daemon", value: viewModel.settings.daemonPath)
            LabeledContent("Logs", value: viewModel.settings.logPath)
            if let error = viewModel.validationError {
                Text(error).foregroundColor(.red)
            }
            Button("Save") { _ = viewModel.save() }
        }
        .padding()
        .frame(width: 460)
    }
}

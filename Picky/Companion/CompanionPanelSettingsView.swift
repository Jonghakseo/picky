//
//  CompanionPanelSettingsView.swift
//  Picky
//
//  Friendly settings surface for the menu bar panel.
//

import AppKit
import SwiftUI

struct CompanionPanelSettingsView: View {
    @ObservedObject var viewModel: PickySettingsViewModel
    @State private var didSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompanionPanelSettingsSection(title: "Workspace", subtitle: "Where Pi starts when Picky needs local context.") {
                CompanionPanelPathField(
                    title: "Default folder",
                    text: $viewModel.settings.defaultCwd,
                    chooseAction: { chooseDirectory(binding: $viewModel.settings.defaultCwd) }
                )
            }

            CompanionPanelSettingsSection(title: "Voice", subtitle: "Choose speech providers. Azure secrets stay in Keychain.") {
                VStack(alignment: .leading, spacing: 10) {
                    CompanionPanelProviderPicker(
                        title: "STT provider",
                        capability: .transcription,
                        selection: $viewModel.settings.sttProvider
                    )
                    CompanionPanelProviderPicker(
                        title: "TTS provider",
                        capability: .speechPlayback,
                        selection: $viewModel.settings.ttsProvider
                    )
                    CompanionPanelTextField(
                        title: "Azure STT preferred language",
                        placeholder: "Auto detect, or e.g. ko / en",
                        text: $viewModel.settings.azureSTTPreferredLanguage
                    )
                }
            }

            if let error = viewModel.validationError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if didSave {
                Text("Saved. New voice captures use the updated settings.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            }

            HStack {
                Spacer()
                Button {
                    didSave = viewModel.save()
                } label: {
                    Text("Save changes")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule(style: .continuous).fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func chooseDirectory(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: binding.wrappedValue).expandingTildeInPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
        didSave = false
    }
}

private struct CompanionPanelSettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(12)
        .background(CompanionPanelCardBackground(tint: DS.Colors.accentText))
    }
}


private struct CompanionPanelProviderPicker: View {
    let title: String
    let capability: PickyVoiceProviderCapability
    @Binding var selection: PickyVoiceProviderSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Picker(title, selection: $selection) {
                ForEach(PickyVoiceProviderSelection.cases(for: capability)) { provider in
                    Text(provider.displayName(for: capability)).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompanionPanelTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DS.Colors.surface2.opacity(0.82))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.8))
                )
        }
    }
}

private struct CompanionPanelPathField: View {
    let title: String
    @Binding var text: String
    let chooseAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            HStack(spacing: 7) {
                TextField("~/", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.surface2.opacity(0.82))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.8))
                    )
                Button("Choose") { chooseAction() }
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(DS.Colors.surface2.opacity(0.7)))
                    .pointerCursor()
            }
        }
    }
}

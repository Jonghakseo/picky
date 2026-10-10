//
//  PickySTTSettingsComponents.swift
//  Picky
//
//  Speech-recognition settings pieces: provider notes, API key guidance,
//  connection check status and the Groq model choice.
//

import AppKit
import SwiftUI

/// Cloud STT providers whose key can be issued from a web console and checked
/// through the OpenAI-compatible transcription endpoint.
enum PickySTTKeyProvider: Equatable {
    case groq
    case openai

    var consoleName: String {
        switch self {
        case .groq: "Groq"
        case .openai: "OpenAI"
        }
    }

    var consoleURL: URL {
        switch self {
        case .groq: GroqTranscriptionDefaults.consoleKeysURL
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    var guideStepKeys: [String] {
        switch self {
        case .groq: ["settings.voice.stt.keyGuide.groq.1", "settings.voice.stt.keyGuide.groq.2", "settings.voice.stt.keyGuide.groq.3"]
        case .openai: ["settings.voice.stt.keyGuide.openai.1", "settings.voice.stt.keyGuide.openai.2", "settings.voice.stt.keyGuide.openai.3"]
        }
    }
}

/// A connection check tied to the exact provider and key it verified, so a
/// result never describes a key the user has since edited.
struct PickySTTConnectionCheck: Equatable {
    enum Phase: Equatable {
        case checking
        case finished(PickySTTConnectionCheckResult)
    }

    let provider: PickySTTKeyProvider
    let apiKey: String
    var phase: Phase

    func applies(to provider: PickySTTKeyProvider, apiKey: String) -> Bool {
        self.provider == provider && self.apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The setup guide stays visible until a key exists and has not been rejected.
    static func showsKeyGuide(apiKey: String, check: PickySTTConnectionCheck?) -> Bool {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return check?.phase == .finished(.invalidKey)
    }
}

enum PickySTTProviderNote {
    static func key(for provider: PickyVoiceProviderSelection) -> String? {
        switch provider {
        case .local: "settings.voice.stt.caption.local"
        case .groq: "settings.voice.stt.caption.groq"
        case .openai: "settings.voice.stt.caption.openai"
        case .azure: "settings.voice.stt.caption.azure"
        case .elevenLabs: "settings.voice.stt.caption.elevenLabs"
        case .edge: nil
        }
    }
}

struct PickySTTConnectionStatusView: View {
    let provider: PickySTTKeyProvider
    let result: PickySTTConnectionCheckResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(PickyHUDTypography.supportingMedium)
                .accessibilityHidden(true)
            Text(message)
                .font(PickyHUDTypography.supportingMedium)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
        }
        .foregroundColor(color)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch result {
        case .connected: "checkmark.circle.fill"
        case .invalidKey: "xmark.octagon.fill"
        case .rateLimited, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch result {
        case .connected: DS.Colors.successText
        case .invalidKey: DS.Colors.destructiveText
        case .rateLimited, .failed: DS.Colors.warningText
        }
    }

    private var message: String {
        switch result {
        case .connected(let milliseconds):
            let seconds = String(format: "%.1f", Double(milliseconds) / 1_000)
            return L10n.t("settings.voice.stt.check.connected", seconds)
        case .invalidKey:
            return L10n.t("settings.voice.stt.check.invalidKey", provider.consoleName)
        case .rateLimited:
            return provider == .groq
                ? L10n.t("settings.voice.stt.check.rateLimited.groq")
                : L10n.t("settings.voice.stt.check.rateLimited.openai")
        case .failed(let statusCode?):
            return L10n.t("settings.voice.stt.check.failedStatus", statusCode)
        case .failed(nil):
            return L10n.t("settings.voice.stt.check.failedNetwork")
        }
    }
}

struct PickySTTKeyGuideView: View {
    let provider: PickySTTKeyProvider

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text("settings.voice.stt.keyGuide.title")
                .font(PickyHUDTypography.labelSemibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                ForEach(Array(provider.guideStepKeys.enumerated()), id: \.offset) { index, key in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
                        Text(verbatim: "\(index + 1)")
                            .font(PickyHUDTypography.minimumSemibold)
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(DS.Colors.surface3))
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(key))
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(PickyHubTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .pickyHubSelectableText()
                    }
                }
            }
            PickyHubPillButton(
                title: LocalizedStringKey(L10n.t("settings.voice.stt.keyGuide.open", provider.consoleName)),
                systemImage: "arrow.up.right"
            ) {
                NSWorkspace.shared.open(provider.consoleURL)
            }
            .padding(.top, DS.Spacing.space1)
        }
        .padding(DS.Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }
}

struct PickySTTConsoleLinkView: View {
    let provider: PickySTTKeyProvider

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(L10n.t("settings.voice.stt.consoleLink.body", provider.consoleName))
                .font(PickyHUDTypography.supporting)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSWorkspace.shared.open(provider.consoleURL)
            } label: {
                HStack(spacing: 2) {
                    Text("settings.voice.stt.consoleLink.action")
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }
                .font(PickyHUDTypography.supportingMedium)
                .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .hoverAffordance()
        }
    }
}

struct PickySTTSwitchToGroqView: View {
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.space3) {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                Text("settings.voice.stt.upsell.title")
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Text("settings.voice.stt.upsell.body")
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.space2)
            PickyHubButton(title: "settings.voice.stt.upsell.action", role: .secondary, action: action)
        }
        .padding(DS.Spacing.space3)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }
}

/// Two-way Groq model choice styled like the dispatch-mode selection cards.
struct PickyGroqModelChoiceView: View {
    @Binding var modelName: String
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        Group {
            if fontScale >= 1.3 {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) { choices }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Spacing.space2) { choices }
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: DS.Spacing.space2) { choices }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var choices: some View {
        choice(
            model: GroqTranscriptionDefaults.accurateModelName,
            title: "settings.voice.stt.model.accurate",
            detail: "settings.voice.stt.model.accurate.detail"
        )
        choice(
            model: GroqTranscriptionDefaults.fastModelName,
            title: "settings.voice.stt.model.fast",
            detail: "settings.voice.stt.model.fast.detail"
        )
    }

    private func choice(model: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let isSelected = modelName == model
        return Button {
            modelName = model
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.space2) {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    Text(title).font(PickyHUDTypography.title)
                    Text(verbatim: model)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(detail)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Spacing.space2)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textSecondary)
                    .accessibilityHidden(true)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .padding(DS.Spacing.space3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accentText : DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Field sections

/// Label and menu styling resolved by the hosting settings view, which differs
/// between the standalone panel and the Hub.
struct PickyVoiceFieldStyle {
    let labelFont: Font
    let labelColor: Color
    let supportingColor: Color
    let menuMaxWidth: CGFloat

    func label(_ key: LocalizedStringKey) -> some View {
        Text(key).font(labelFont).foregroundColor(labelColor)
    }
}

/// API key input with the connection check, its status, and the key guide or
/// console link. The check result is shown only while the checked key remains.
struct PickySTTKeySection: View {
    let provider: PickySTTKeyProvider
    let label: LocalizedStringKey
    let placeholder: String
    @Binding var apiKey: String
    let style: PickyVoiceFieldStyle
    let checkRequest: () -> (configuration: OpenAIAudioConfiguration, modelName: String)
    let onDraftChange: () -> Void
    let onCommit: () -> Void
    @State private var check: PickySTTConnectionCheck?

    var body: some View {
        let current = check.flatMap { $0.applies(to: provider, apiKey: apiKey) ? $0 : nil }
        let isInvalid = current?.phase == .finished(.invalidKey)
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            style.label(label)
            HStack(spacing: DS.Spacing.space2) {
                SecureField(placeholder, text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(PickyHUDTypography.supportingMonospacedMedium)
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, DS.Spacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(isInvalid ? DS.Colors.destructiveText : DS.Colors.borderSubtle.opacity(0.6), lineWidth: isInvalid ? 1 : 0.5)
                    )
                    .onChange(of: apiKey) { _, _ in onDraftChange() }
                    .onSubmit(onCommit)
                    .frame(maxWidth: 420)
                PickyHubButton(
                    title: current?.phase == .checking ? "settings.voice.stt.checking" : "settings.voice.stt.check",
                    role: .secondary,
                    isBusy: current?.phase == .checking,
                    isEnabled: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: runCheck
                )
                Spacer(minLength: 0)
            }
            if case .finished(let result)? = current?.phase {
                PickySTTConnectionStatusView(provider: provider, result: result)
            }
            if PickySTTConnectionCheck.showsKeyGuide(apiKey: apiKey, check: current) {
                PickySTTKeyGuideView(provider: provider)
            } else {
                PickySTTConsoleLinkView(provider: provider)
            }
        }
    }

    /// Saves pending drafts first so a successful check matches what dictation uses.
    private func runCheck() {
        onCommit()
        let request = checkRequest()
        let pending = PickySTTConnectionCheck(
            provider: provider,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            phase: .checking
        )
        check = pending
        Task { @MainActor in
            let result = await OpenAITranscriptionProvider.checkConnection(
                configuration: request.configuration,
                modelName: request.modelName
            )
            guard check == pending else { return }
            check?.phase = .finished(result)
        }
    }
}

/// Groq key, model choice and spoken language.
struct PickyGroqSTTSettingsFields: View {
    @Binding var apiKey: String
    @Binding var modelName: String
    @Binding var language: String
    let style: PickyVoiceFieldStyle
    let onDraftChange: () -> Void
    let onCommit: () -> Void

    var body: some View {
        PickySTTKeySection(
            provider: .groq,
            label: "settings.voice.stt.apiKey",
            placeholder: "gsk_…",
            apiKey: $apiKey,
            style: style,
            checkRequest: {
                (OpenAIAudioConfiguration(apiKey: apiKey, baseURL: GroqTranscriptionDefaults.baseURL), modelName)
            },
            onDraftChange: onDraftChange,
            onCommit: onCommit
        )
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            style.label("settings.voice.stt.model")
            PickyGroqModelChoiceView(modelName: $modelName)
        }
        .onChange(of: modelName) { _, _ in onCommit() }
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            style.label("settings.voice.stt.language")
            PickyNativeMenuPicker(
                title: L10n.t("settings.voice.stt.language"),
                selection: $language,
                options: [
                    .init(value: "", title: L10n.t("settings.voice.stt.language.auto")),
                    .init(value: "ko", title: "한국어"),
                    .init(value: "en", title: "English"),
                    .init(value: "ja", title: "日本語"),
                    .init(value: "zh", title: "中文"),
                ]
            )
            .frame(maxWidth: style.menuMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: language) { _, _ in onCommit() }
        }
    }
}

/// Frequent words and the app/window context toggle for prompt-capable providers.
struct PickySTTVocabularySection: View {
    @Binding var terms: String
    @Binding var includesContextTerms: Bool
    let style: PickyVoiceFieldStyle
    let onDraftChange: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            style.label("settings.voice.stt.vocabulary")
            TextField(L10n.t("settings.voice.stt.vocabulary.placeholder"), text: $terms, axis: .vertical)
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
                .onChange(of: terms) { _, _ in onDraftChange() }
                .onSubmit(onCommit)
            Text("settings.voice.stt.vocabulary.note")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(style.supportingColor)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
            HStack {
                Text("settings.voice.stt.vocabulary.context")
                    .font(PickyHUDTypography.labelMedium)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                Toggle("settings.voice.stt.vocabulary.context", isOn: $includesContextTerms)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .controlSize(.small)
            }
            .padding(.vertical, DS.Spacing.space2)
            .onChange(of: includesContextTerms) { _, _ in onCommit() }
        }
    }
}

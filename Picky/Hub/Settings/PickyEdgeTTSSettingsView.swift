//
//  PickyEdgeTTSSettingsView.swift
//  Picky
//
//  Edge TTS language and voice selection inside the Voice settings.
//

import SwiftUI

struct PickyEdgeTTSSettingsView: View {
    @ObservedObject var catalog: EdgeTTSVoiceCatalog
    @Binding var voice: String
    let style: PickyVoiceFieldStyle
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            Text("settings.voice.edge.disclosure")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()

            switch catalog.state {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("settings.voice.edge.loading")
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(style.supportingColor)
                        .pickyHubSelectableText()
                }
            case .failed(let message):
                Text(L10n.t("settings.voice.edge.selectedVoice", voice))
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(style.supportingColor)
                    .pickyHubSelectableText()
                Text(message)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
                Button("settings.voice.edge.retry") { catalog.refresh() }
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
                style.label("settings.voice.edge.language")
                PickyNativeMenuPicker(
                    title: L10n.t("settings.voice.edge.language"),
                    selection: edgeTTSLocaleBinding,
                    options: catalog.locales(selectedVoice: voice).map {
                        .init(value: $0, title: edgeTTSLocaleLabel($0))
                    }
                )
                .frame(maxWidth: style.menuMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                style.label("settings.voice.edge.voice")
                PickyNativeMenuPicker(
                    title: L10n.t("settings.voice.edge.voice"),
                    selection: $voice,
                    options: edgeTTSMenuOptions
                )
                .frame(maxWidth: style.menuMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: voice) { _, _ in onCommit() }
            }
        }
    }

    private var edgeTTSMenuOptions: [PickyNativeMenuOption<String>] {
        var options: [PickyNativeMenuOption<String>] = []
        if !EdgeTTSVoiceCatalogProjection.isSelectedVoiceAvailable(voice, voices: catalog.voices) {
            options.append(.init(value: voice, title: L10n.t("settings.voice.edge.savedVoiceUnavailable", voice)))
        }
        options += catalog.voices(in: selectedEdgeTTSLocale).map {
            .init(value: $0.shortName, title: edgeTTSVoiceLabel($0))
        }
        return options
    }

    private var selectedEdgeTTSLocale: String {
        EdgeTTSVoiceCatalogProjection.selectedLocale(
            voice: voice,
            voices: catalog.voices
        ) ?? EdgeTTSVoiceCatalogProjection.unavailableLocale
    }

    private func edgeTTSLocaleLabel(_ locale: String) -> String {
        locale == EdgeTTSVoiceCatalogProjection.unavailableLocale
            ? L10n.t("settings.voice.edge.localeUnavailable")
            : catalog.voices(in: locale).isEmpty
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
                guard let firstVoice = catalog.voices(in: locale).first else { return }
                // The voice picker observes this binding and persists once.
                voice = firstVoice.shortName
            }
        )
    }
}

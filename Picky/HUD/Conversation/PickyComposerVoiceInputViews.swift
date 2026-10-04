//
//  PickyComposerVoiceInputViews.swift
//  Picky
//
//  Composer mic button and the one-line voice status shown above the composer.
//  Both observe the shared dictation controller so a recording only re-renders
//  these two small views, never the whole composer.
//

import SwiftUI

/// What the mic button of one Pickle's composer shows for the shared phase.
struct PickyComposerMicPresentation: Equatable {
    let symbolName: String
    let isActive: Bool
    let isEnabled: Bool
    let helpKey: String

    init(phase: PickyComposerDictationPhase, sessionID: String) {
        let ownsPhase = phase.sessionID == sessionID
        switch phase {
        case .preparing, .listening:
            symbolName = ownsPhase ? "waveform" : "mic"
            isActive = ownsPhase
            isEnabled = ownsPhase
            helpKey = ownsPhase ? "hud.composer.mic.stop.help" : "hud.composer.mic.busy.help"
        case .transcribing:
            symbolName = ownsPhase ? "ellipsis" : "mic"
            isActive = false
            isEnabled = false
            helpKey = ownsPhase ? "hud.composer.mic.transcribing.help" : "hud.composer.mic.busy.help"
        case .idle, .failed:
            symbolName = "mic"
            isActive = false
            isEnabled = true
            helpKey = "hud.composer.mic.start.help"
        }
    }
}

struct PickyComposerMicButton: View {
    @ObservedObject var controller: PickyComposerDictationController
    let sessionID: String

    var body: some View {
        let presentation = PickyComposerMicPresentation(phase: controller.phase, sessionID: sessionID)
        Button {
            controller.toggle(sessionID: sessionID)
        } label: {
            Image(systemName: presentation.symbolName)
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(presentation.isActive ? DS.Colors.accentText : DS.Colors.textSecondary)
                .frame(
                    width: PickyComposerToolbarMetrics.controlSize,
                    height: PickyComposerToolbarMetrics.controlSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: presentation.isActive))
        .disabled(!presentation.isEnabled)
        .help(L10n.t(presentation.helpKey))
        .accessibilityLabel(L10n.t("hud.composer.mic.accessibilityLabel"))
        .accessibilityHint(L10n.t(presentation.helpKey))
        .accessibilityAddTraits(presentation.isActive ? .isSelected : [])
    }
}

/// One line above the composer while this Pickle's dictation is running or
/// just failed. It says what the next press does; nothing is ever sent from here.
struct PickyComposerVoiceStatusRow: View {
    @ObservedObject var controller: PickyComposerDictationController
    let sessionID: String

    var body: some View {
        if controller.phase.sessionID == sessionID {
            switch controller.phase {
            case .preparing:
                row(symbol: "mic", tint: DS.Colors.textSecondary,
                    primary: L10n.t("hud.composer.voice.preparing"), hint: nil)
            case .listening(_, let startedAt):
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    row(symbol: "waveform", tint: DS.Colors.accentText,
                        primary: L10n.t("hud.composer.voice.listening", Self.elapsedText(from: startedAt, to: context.date)),
                        hint: L10n.t("hud.composer.voice.listening.hint"))
                }
            case .transcribing:
                row(symbol: "text.bubble", tint: DS.Colors.textSecondary,
                    primary: L10n.t("hud.composer.voice.transcribing"),
                    hint: L10n.t("hud.composer.voice.transcribing.hint"))
            case .failed(_, .permissionRequired):
                row(symbol: "exclamationmark.triangle", tint: DS.Colors.warningText,
                    primary: L10n.t("hud.composer.voice.permission"),
                    hint: L10n.t("hud.composer.voice.permission.hint"))
            case .failed:
                row(symbol: "exclamationmark.triangle", tint: DS.Colors.warningText,
                    primary: L10n.t("hud.composer.voice.failed"),
                    hint: L10n.t("hud.composer.voice.failed.hint"))
            case .idle:
                EmptyView()
            }
        }
    }

    static func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func row(symbol: String, tint: Color, primary: String, hint: String?) -> some View {
        HStack(spacing: DS.Spacing.space1) {
            Image(systemName: symbol)
                .pickyFont(size: 10, weight: .semibold)
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(primary)
                .monospacedDigit()
                .foregroundColor(tint)
                .fixedSize()
            if let hint {
                Text(verbatim: "· \(hint)")
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(PickyHUDTypography.status)
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.bottom, DS.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

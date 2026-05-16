//
//  ShortcutSettingsViews.swift
//  Picky
//
//  Reusable bits that render the Shortcuts section inside the menu bar
//  Settings panel: a small key-cap chip, a row that shows the current
//  shortcut + Change/Save/Cancel buttons, and an optional capture hint.
//

import AppKit
import SwiftUI

// MARK: - Single key cap

struct ShortcutKeyCapView: View {
    let cap: PickyShortcutKeyCap

    var body: some View {
        HStack(spacing: 4) {
            if let glyph = cap.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Text(cap.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Row

/// A single row inside the Shortcuts section. Owns its `ShortcutCaptureRecorder`
/// so two rows can capture independently. The host (Settings view) hands in the
/// persisted spec and a "save spec" callback that runs when the user confirms.
struct ShortcutSettingsRow: View {
    let title: String
    let subtitle: String
    let allowance: ShortcutCaptureRecorder.Allowance
    let currentSpec: PickyShortcutSpec
    let onSave: (PickyShortcutSpec) -> Void

    @StateObject private var recorder: ShortcutCaptureRecorder

    init(
        title: String,
        subtitle: String,
        allowance: ShortcutCaptureRecorder.Allowance,
        currentSpec: PickyShortcutSpec,
        onSave: @escaping (PickyShortcutSpec) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.allowance = allowance
        self.currentSpec = currentSpec
        self.onSave = onSave
        _recorder = StateObject(wrappedValue: ShortcutCaptureRecorder(allowance: allowance))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                keyCapsRow

                Spacer(minLength: 8)

                actionButtons
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
                    )
            )

            if recorder.isCapturing, let message = recorder.statusMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var keyCapsRow: some View {
        let displayedSpec = recorder.isCapturing ? (recorder.draftSpec ?? currentSpec) : currentSpec
        let caps = displayedSpec.keyCaps
        if caps.isEmpty {
            Text("shortcuts.row.notSet")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        } else {
            HStack(spacing: 6) {
                ForEach(caps) { cap in
                    ShortcutKeyCapView(cap: cap)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if recorder.isCapturing {
            HStack(spacing: 6) {
                Button("common.cancel") { recorder.cancel() }
                    .buttonStyle(ShortcutChipButtonStyle(kind: .secondary))
                    .keyboardShortcut(.escape, modifiers: [])

                Button("common.save") {
                    if let spec = recorder.commit() {
                        onSave(spec)
                    } else {
                        recorder.cancel()
                    }
                }
                .buttonStyle(ShortcutChipButtonStyle(kind: .primary))
                .disabled(recorder.draftSpec == nil)
            }
        } else {
            Button("common.change") { recorder.start() }
                .buttonStyle(ShortcutChipButtonStyle(kind: .secondary))
        }
    }
}

// MARK: - Button style

struct ShortcutChipButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(textColor(for: configuration))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(for: configuration))
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }

    private func textColor(for configuration: Configuration) -> Color {
        switch kind {
        case .primary: return Color.white
        case .secondary: return DS.Colors.textSecondary
        }
    }

    private func backgroundColor(for configuration: Configuration) -> Color {
        switch kind {
        case .primary:
            return DS.Colors.destructiveText.opacity(configuration.isPressed ? 0.85 : 1.0)
        case .secondary:
            return DS.Colors.borderSubtle.opacity(0.4)
        }
    }
}

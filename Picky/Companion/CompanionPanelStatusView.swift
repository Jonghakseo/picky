//
//  CompanionPanelStatusView.swift
//  Picky
//
//  Calm status content for the menu bar panel.
//

import SwiftUI

struct CompanionPanelStatusView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if companionManager.allPermissionsGranted {
                readyCard
                softContextCard
            } else {
                CompanionPanelPermissionsCopyView(companionManager: companionManager)
                CompanionPanelPermissionsView(companionManager: companionManager)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(DS.Colors.success.opacity(0.16))
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.success)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryStatusTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(primaryStatusSubtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                CompanionPanelPill(icon: "keyboard", text: "Control+Option")
                CompanionPanelPill(icon: "lock.shield", text: "Local-first")
            }
        }
        .padding(13)
        .background(CompanionPanelCardBackground(tint: DS.Colors.success))
    }

    private var softContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Picky captures")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                contextLine(icon: "display", text: "Screenshots only when you use the hotkey")
                contextLine(icon: "text.cursor", text: "Selected text and browser context when available")
                contextLine(icon: "terminal", text: "Default workspace from Settings")
            }
        }
        .padding(13)
        .background(CompanionPanelCardBackground(tint: DS.Colors.accentText))
    }

    private var primaryStatusTitle: String {
        switch companionManager.voiceState {
        case .idle:
            return "Ready when you are"
        case .listening:
            return "Listening…"
        case .processing:
            return "Preparing context…"
        case .responding:
            return "Answering…"
        }
    }

    private var primaryStatusSubtitle: String {
        switch companionManager.voiceState {
        case .idle:
            return "Hold the shortcut, speak naturally, then release."
        case .listening:
            return "Keep holding Control+Option while you speak."
        case .processing:
            return "Picky is collecting just enough context for Pi."
        case .responding:
            return "You can interrupt by starting a new voice input."
        }
    }

    private func contextLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CompanionPanelPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(DS.Colors.surface2.opacity(0.85)))
    }
}

struct CompanionPanelCardBackground: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.82))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.8))
    }
}

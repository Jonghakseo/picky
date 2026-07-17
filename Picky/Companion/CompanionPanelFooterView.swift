//
//  CompanionPanelFooterView.swift
//  Picky
//
//  Footer controls for the companion panel: Quit on the left, light/dark
//  appearance toggle on the right. The toggle flips PickyAppearanceStore.mode,
//  which feeds `.preferredColorScheme(...)` at every NSPanel root and persists
//  to the Picky settings file so the choice survives relaunches.
//

import AppKit
import SwiftUI

struct CompanionPanelFooterView: View {
    @EnvironmentObject private var appearanceStore: PickyAppearanceStore
    @State private var isQuitConfirmationPresented = false

    /// Settings edits that need a fresh Picky process to become the applied
    /// runtime/daemon environment. When present, the left footer action becomes
    /// Restart instead of Quit.
    var restartRequirement: PickyRestartRequirement = .none
    /// Tapped when the user hits the bug glyph next to the appearance toggle.
    /// Hoisted to the parent so the footer stays a leaf view; the parent
    /// routes the panel to `Status → Feedback` regardless of which tab is
    /// currently active.
    var onFeedbackTapped: () -> Void = {}
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var relaunchAndTerminate: () -> Void = { PickyRelauncher.relaunchAndTerminate() }

    private var primaryActionRequiresRestart: Bool { restartRequirement.isRequired }
    private var primaryActionTitleKey: String { primaryActionRequiresRestart ? "common.restart" : "common.quit" }
    private var primaryActionIcon: String { primaryActionRequiresRestart ? "arrow.clockwise" : "power" }
    private var primaryActionForeground: Color {
        primaryActionRequiresRestart ? DS.Colors.warningText : DS.Colors.destructiveText.opacity(0.82)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                isQuitConfirmationPresented = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: primaryActionIcon)
                        .pickyFont(size: 11, weight: .medium)
                    Text(LocalizedStringKey(primaryActionTitleKey))
                        .pickyFont(size: 12, weight: .medium)
                }
                .foregroundColor(primaryActionForeground)
            }
            .buttonStyle(.plain)

            Spacer()

            CompanionPanelFeedbackGlyphButton(onTap: onFeedbackTapped)

            CompanionPanelAppearanceToggle()
        }
        .alert(L10n.t(primaryActionRequiresRestart ? "footer.restart.title" : "footer.quit.title"), isPresented: $isQuitConfirmationPresented) {
            Button(L10n.t("common.cancel"), role: .cancel) {}
            Button(L10n.t(primaryActionRequiresRestart ? "common.restart" : "common.quit"), role: primaryActionRequiresRestart ? nil : .destructive) {
                if primaryActionRequiresRestart {
                    relaunchAndTerminate()
                } else {
                    terminate()
                }
            }
        } message: {
            Text(LocalizedStringKey(primaryActionRequiresRestart ? "footer.restart.body" : "footer.quit.body"))
        }
    }
}

/// Shared compact icon-action treatment for the Companion panel. It preserves
/// each glyph's optical size while giving small utility controls a 28pt target
/// and quiet hover/pressed feedback.
struct CompanionPanelIconActionStyle: ButtonStyle {
    var size: CGFloat = 28

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? DS.Colors.surface4
                            : isHovering ? DS.Colors.surface3.opacity(0.7) : Color.clear
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Subtle bug glyph that drills the panel into the feedback sub-page. Styled
/// to match the appearance toggle's icon buttons (same size, same tertiary
/// foreground, same primary-on-hover treatment) so it reads as part of the
/// footer's icon row rather than a separate CTA. The actual routing lives in
/// the parent so this stays a leaf view.
struct CompanionPanelFeedbackGlyphButton: View {
    var onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "ant.fill")
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(isHovering ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(CompanionPanelIconActionStyle())
        .help("footer.feedback.accessibilityLabel")
        .accessibilityLabel(Text("footer.feedback.accessibilityLabel"))
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

/// Compact light/dark switch shown in the footer's right edge. The sun and
/// moon icons act as both labels and click affordances so users can tap either
/// side as well as drag the SwiftUI Toggle thumb.
struct CompanionPanelAppearanceToggle: View {
    @EnvironmentObject private var appearanceStore: PickyAppearanceStore

    var body: some View {
        HStack(spacing: 6) {
            iconButton(systemName: "sun.max.fill", target: .light, accessibilityLabel: "Use light appearance")

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(DS.Colors.accent)
                .help("Switch between light and dark appearance")

            iconButton(systemName: "moon.fill", target: .dark, accessibilityLabel: "Use dark appearance")
        }
    }

    /// Binding maps `.dark → true` so the switch reads as "dark on / light off",
    /// matching the moon icon being on the right.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { appearanceStore.mode == .dark },
            set: { isDark in appearanceStore.setMode(isDark ? .dark : .light) }
        )
    }

    private func iconButton(systemName: String, target: PickyAppearanceMode, accessibilityLabel: String) -> some View {
        Button {
            appearanceStore.setMode(target)
        } label: {
            Image(systemName: systemName)
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(appearanceStore.mode == target ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(CompanionPanelIconActionStyle())
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

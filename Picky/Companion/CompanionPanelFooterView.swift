//
//  CompanionPanelFooterView.swift
//  Picky
//
//  Footer controls for the companion panel. App/surface actions stay grouped
//  on the left; feedback and direct light/dark appearance actions stay on the
//  right. Both HUD visibility and appearance persist across relaunches.
//

import AppKit
import SwiftUI

struct CompanionPanelFooterView: View {
    @State private var isQuitConfirmationPresented = false

    /// Settings edits that need a fresh Picky process to become the applied
    /// runtime/daemon environment. When present, the left footer action becomes
    /// Restart instead of Quit.
    var restartRequirement: PickyRestartRequirement = .none
    /// Tapped when the user hits the bug glyph next to the appearance controls.
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
            .hoverAffordance()

            CompanionPanelFooterDivider()

            CompanionPanelDockVisibilityButton()

            Spacer(minLength: 8)

            CompanionPanelFeedbackGlyphButton(onTap: onFeedbackTapped)

            CompanionPanelFooterDivider()

            CompanionPanelAppearancePicker()
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
    var isSelected = false

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed { return DS.Colors.surface4 }
        if isHovering { return DS.Colors.surface3.opacity(0.7) }
        if isSelected { return DS.Colors.surface2.opacity(0.72) }
        return .clear
    }
}

private struct CompanionPanelFooterDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle.opacity(0.55))
            .frame(width: 1, height: 18)
            .accessibilityHidden(true)
    }
}

private struct CompanionPanelDockVisibilityButton: View {
    @EnvironmentObject private var visibilityStore: PickyHUDVisibilityStore

    private var presentation: CompanionPanelDockActionPresentation {
        .resolve(isDockVisible: visibilityStore.isVisible)
    }

    var body: some View {
        Button {
            visibilityStore.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.systemImage)
                    .pickyFont(size: 11, weight: .medium)
                Text(LocalizedStringKey(presentation.titleKey))
                    .pickyFont(size: 12, weight: .medium)
            }
            .foregroundColor(DS.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .help(Text(LocalizedStringKey(presentation.titleKey)))
        .accessibilityLabel(Text(LocalizedStringKey(presentation.titleKey)))
    }
}

/// Subtle bug glyph that drills the panel into the feedback sub-page. Styled
/// to match the appearance icon buttons (same size, same tertiary foreground,
/// same primary-on-hover treatment) so it reads as part of the
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

/// Direct light/dark appearance actions shown at the footer's right edge.
/// Each icon selects its corresponding mode; no redundant switch is rendered.
struct CompanionPanelAppearancePicker: View {
    @EnvironmentObject private var appearanceStore: PickyAppearanceStore

    var body: some View {
        HStack(spacing: 2) {
            iconButton(systemName: "sun.max.fill", target: .light, accessibilityLabel: "Use light appearance")
            iconButton(systemName: "moon.fill", target: .dark, accessibilityLabel: "Use dark appearance")
        }
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
        .buttonStyle(CompanionPanelIconActionStyle(isSelected: appearanceStore.mode == target))
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

//
//  PickyHubSidebarView.swift
//  Picky
//
//  Fixed 190pt navigation rail: wordmark, the seven page links, and the
//  app-level controls (quit/restart, Dock visibility, feedback, appearance)
//  that the menu bar context menu also exposes.
//

import AppKit
import Combine
import SwiftUI

struct PickyHubSidebarView: View {
    @ObservedObject var navigator: PickyHubNavigator
    let restartRequirement: PickyRestartRequirement
    let dockDisplayIDProvider: () -> CGDirectDisplayID?
    let onFeedbackTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Native traffic lights occupy the top-left corner of the
            // full-size content view; keep the wordmark clear of them.
            Image("PickyHubBrandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 128)
                .padding(.top, 52)
                .padding(.leading, 4)
                .accessibilityLabel(Text("hub.brand.accessibilityLabel"))
                .accessibilityAddTraits(.isButton)
                .onTapGesture { navigator.select(.dashboard) }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(PickyHubPage.allCases) { page in
                    PickyHubNavRow(page: page, isSelected: navigator.selectedPage == page) {
                        navigator.select(page)
                    }
                }
            }
            .padding(.top, 35)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("hub.nav.accessibilityLabel"))

            Spacer(minLength: 16)

            PickyHubSidebarFooter(
                restartRequirement: restartRequirement,
                dockDisplayIDProvider: dockDisplayIDProvider,
                onFeedbackTapped: onFeedbackTapped
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .frame(width: PickyHubTheme.Layout.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PickyHubTheme.Colors.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PickyHubTheme.Colors.borderSoft)
                .frame(width: 1)
        }
    }
}

private struct PickyHubNavRow: View {
    let page: PickyHubPage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .pickyFont(size: 14, weight: .semibold)
                    .frame(width: 18, height: 18)
                Text(page.titleKey)
                    .pickyFont(size: PickyHubTheme.Typography.nav, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundColor(isSelected ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: PickyHubTheme.Layout.navRowMinHeight)
            .background(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.nav, style: .continuous)
                    .fill(isSelected || isHovering ? PickyHubTheme.Colors.navHighlight : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.nav, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.nav)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
        .accessibilityLabel(Text(page.titleKey))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Bottom-left controls. Mirrors the status item context menu so both entry
/// points expose the same actions.
struct PickyHubSidebarFooter: View {
    let restartRequirement: PickyRestartRequirement
    let dockDisplayIDProvider: () -> CGDirectDisplayID?
    let onFeedbackTapped: () -> Void
    @EnvironmentObject private var visibilityStore: PickyHUDVisibilityStore
    @EnvironmentObject private var appearanceStore: PickyAppearanceStore
    @State private var isQuitConfirmationPresented = false

    private var requiresRestart: Bool { restartRequirement.isRequired }

    private var dockDisplayID: CGDirectDisplayID? {
        let cursorDisplayID = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.pickyDisplayID
        return PickyHUDDockVisibilityTarget.resolve(companionDisplayID: dockDisplayIDProvider(), cursorDisplayID: cursorDisplayID)
    }

    private var dockPresentation: CompanionPanelDockActionPresentation {
        .resolve(isDockVisible: visibilityStore.isVisible(for: dockDisplayID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            footerRow(
                systemImage: dockPresentation.systemImage,
                title: LocalizedStringKey(dockPresentation.titleKey),
                foreground: PickyHubTheme.Colors.textSecondary
            ) {
                guard let dockDisplayID else { return }
                visibilityStore.toggle(for: dockDisplayID)
            }

            footerRow(
                systemImage: "ant.fill",
                title: "footer.feedback.accessibilityLabel",
                foreground: PickyHubTheme.Colors.textSecondary,
                action: onFeedbackTapped
            )

            HStack(spacing: 2) {
                footerRow(
                    systemImage: requiresRestart ? "arrow.clockwise" : "power",
                    title: LocalizedStringKey(requiresRestart ? "common.restart" : "common.quit"),
                    foreground: requiresRestart ? DS.Colors.warningText : DS.Colors.destructiveText.opacity(0.85)
                ) {
                    isQuitConfirmationPresented = true
                }
                Spacer(minLength: 0)
                appearanceButton(systemName: "sun.max.fill", target: .light, label: "hub.appearance.light")
                appearanceButton(systemName: "moon.fill", target: .dark, label: "hub.appearance.dark")
            }
        }
        .alert(L10n.t(requiresRestart ? "footer.restart.title" : "footer.quit.title"), isPresented: $isQuitConfirmationPresented) {
            Button(L10n.t("common.cancel"), role: .cancel) {}
            Button(L10n.t(requiresRestart ? "common.restart" : "common.quit"), role: requiresRestart ? nil : .destructive) {
                if requiresRestart {
                    PickyRelauncher.relaunchAndTerminate()
                } else {
                    NSApp.terminate(nil)
                }
            }
        } message: {
            Text(LocalizedStringKey(requiresRestart ? "footer.restart.body" : "footer.quit.body"))
        }
    }

    private func footerRow(systemImage: String, title: LocalizedStringKey, foreground: Color, action: @escaping () -> Void) -> some View {
        PickyHubFooterButton(systemImage: systemImage, title: title, foreground: foreground, action: action)
    }

    private func appearanceButton(systemName: String, target: PickyAppearanceMode, label: LocalizedStringKey) -> some View {
        Button { appearanceStore.setMode(target) } label: {
            Image(systemName: systemName)
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(appearanceStore.mode == target ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textTertiary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(CompanionPanelIconActionStyle(isSelected: appearanceStore.mode == target))
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(appearanceStore.mode == target ? [.isSelected] : [])
    }
}

private struct PickyHubFooterButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    let foreground: Color
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .pickyFont(size: 11, weight: .medium)
                    .frame(width: 14)
                Text(title)
                    .pickyFont(size: 12, weight: .medium)
                    .lineLimit(1)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovering ? PickyHubTheme.Colors.navHighlight : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: DS.CornerRadius.small)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

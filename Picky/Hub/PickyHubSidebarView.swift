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
    @FocusState.Binding var focusedControl: String?
    let onFeedbackTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Native traffic lights occupy the top-left corner of the
            // full-size content view; keep the wordmark clear of them.
            Button { navigator.select(.dashboard) } label: {
                Image("PickyHubBrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128)
                    .frame(minHeight: PickyHubTheme.Control.minimumHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: "home")
            .pickyHubFocusRing(isFocused: focusedControl == "home", cornerRadius: PickyHubTheme.Radius.control)
            .padding(.top, 52)
            .padding(.leading, DS.Spacing.space1)
            .accessibilityLabel(Text("hub.brand.accessibilityLabel"))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    ForEach(PickyHubPage.allCases) { page in
                        PickyHubNavRow(page: page, isSelected: navigator.selectedPage == page) {
                            navigator.select(page)
                        }
                    }
                }
            }
            .padding(.top, PickyHubTheme.Spacing.group)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("hub.nav.accessibilityLabel"))

            Spacer(minLength: 16)

            PickyHubSidebarFooter(
                restartRequirement: restartRequirement,
                dockDisplayIDProvider: dockDisplayIDProvider,
                focusedControl: $focusedControl,
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .pickyFont(size: 14, weight: .medium)
                    .frame(width: 18, height: 18)
                Text(page.titleKey)
                    .pickyFont(size: PickyHubTheme.Typography.nav, weight: isSelected ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(isSelected ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textSecondary)
            .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
            .padding(.vertical, DS.Spacing.space1)
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
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.hover, value: isHovering)
        .accessibilityLabel(Text(page.titleKey))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Bottom-left controls. Mirrors the status item context menu so both entry
/// points expose the same actions.
struct PickyHubSidebarFooter: View {
    let restartRequirement: PickyRestartRequirement
    let dockDisplayIDProvider: () -> CGDirectDisplayID?
    @FocusState.Binding var focusedControl: String?
    let onFeedbackTapped: () -> Void
    @EnvironmentObject private var visibilityStore: PickyHUDVisibilityStore
    @EnvironmentObject private var appearanceStore: PickyAppearanceStore
    @State private var isQuitConfirmationPresented = false
    @State private var isDockPickerPresented = false
    @State private var screens = NSScreen.screens

    private var requiresRestart: Bool { restartRequirement.isRequired }

    private var dockDisplayID: CGDirectDisplayID? {
        let cursorDisplayID = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.pickyDisplayID
        return PickyHUDDockVisibilityTarget.resolve(companionDisplayID: dockDisplayIDProvider(), cursorDisplayID: cursorDisplayID)
    }

    private var dockControl: PickyHubDockControl {
        PickyHubDockControl(
            displayIDs: screens.compactMap(\.pickyDisplayID),
            targetDisplayID: dockDisplayID,
            visibilityStore: visibilityStore
        )
    }

    private var dockPresentation: CompanionPanelDockActionPresentation { dockControl.presentation }

    private var dockPicker: some View {
        PickyHubDockPickerView(
            displays: PickyPerf.interval("hub_dock_display_names") {
                screens.compactMap { screen in
                    screen.pickyDisplayID.map { PickyHubDockPickerView.Display(id: $0, name: screen.localizedName) }
                }
            },
            hubDisplayID: dockDisplayID,
            visibilityBinding: dockControl.visibilityBinding
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            footerRow(
                systemImage: dockPresentation.systemImage,
                title: LocalizedStringKey(dockPresentation.titleKey),
                foreground: PickyHubTheme.Colors.textSecondary,
                focusID: "dock"
            ) {
                PickyPerf.event("hub_dock_picker_click")
                screens = PickyPerf.interval("hub_dock_screens") { NSScreen.screens }
                isDockPickerPresented = dockControl.activate()
            }
            .popover(isPresented: $isDockPickerPresented, arrowEdge: .trailing) {
                dockPicker
                    .onAppear { PickyPerf.event("hub_dock_picker_appear") }
                    .onDisappear { PickyPerf.event("hub_dock_picker_disappear") }
            }

            footerRow(
                systemImage: "ant.fill",
                title: "footer.feedback.accessibilityLabel",
                foreground: PickyHubTheme.Colors.textSecondary,
                focusID: "feedback",
                action: onFeedbackTapped
            )

            HStack(spacing: 2) {
                footerRow(
                    systemImage: requiresRestart ? "arrow.clockwise" : "power",
                    title: LocalizedStringKey(requiresRestart ? "common.restart" : "common.quit"),
                    foreground: requiresRestart ? DS.Colors.warningText : DS.Colors.destructiveText.opacity(0.85),
                    focusID: "quit"
                ) {
                    isQuitConfirmationPresented = true
                }
                Spacer(minLength: 0)
                appearanceButton(systemName: "sun.max.fill", target: .light, label: "hub.appearance.light")
                appearanceButton(systemName: "moon.fill", target: .dark, label: "hub.appearance.dark")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
            if !dockControl.showsDisplayPicker { isDockPickerPresented = false }
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

    private func footerRow(
        systemImage: String,
        title: LocalizedStringKey,
        foreground: Color,
        focusID: String,
        action: @escaping () -> Void
    ) -> some View {
        PickyHubFooterButton(
            systemImage: systemImage,
            title: title,
            foreground: foreground,
            focusedControl: $focusedControl,
            focusID: focusID,
            action: action
        )
    }

    private func appearanceButton(systemName: String, target: PickyAppearanceMode, label: LocalizedStringKey) -> some View {
        Button { appearanceStore.setMode(target) } label: {
            Image(systemName: systemName)
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(appearanceStore.mode == target ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textTertiary)
                .frame(width: PickyHubTheme.Control.minimumHeight, height: PickyHubTheme.Control.minimumHeight)
                .background(
                    RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control)
                        .fill(appearanceStore.mode == target ? PickyHubTheme.Colors.navHighlight : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PickyHubPressStyle())
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(appearanceStore.mode == target ? [.isSelected] : [])
    }
}

private struct PickyHubFooterButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    let foreground: Color
    @FocusState.Binding var focusedControl: String?
    let focusID: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isFocused: Bool { focusedControl == focusID }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .pickyFont(size: 11, weight: .medium)
                    .frame(width: 14)
                Text(title)
                    .pickyFont(size: 12, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 8)
            .frame(minHeight: PickyHubTheme.Control.minimumHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovering ? PickyHubTheme.Colors.navHighlight : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: focusID)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: DS.CornerRadius.small)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.hover, value: isHovering)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

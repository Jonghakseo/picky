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

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                isQuitConfirmationPresented = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("common.quit")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.destructiveText.opacity(0.82))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()

            CompanionPanelAppearanceToggle()
        }
        .alert("Quit?", isPresented: $isQuitConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive) {
                NSApp.terminate(nil)
            }
        } message: {
            Text("footer.quit.body")
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(appearanceStore.mode == target ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .pointerCursor()
    }
}

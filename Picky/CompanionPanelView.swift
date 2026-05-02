//
//  CompanionPanelView.swift
//  Picky
//
//  The SwiftUI content hosted inside the menu bar panel.
//

import SwiftUI

private enum CompanionPanelTab: String, CaseIterable, Identifiable {
    case status = "Status"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .status: "sparkles"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var settingsViewModel = PickySettingsViewModel()
    @State private var selectedTab: CompanionPanelTab = .status

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionPanelHeaderView(companionManager: companionManager)

            CompanionPanelTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.8))
                .padding(.horizontal, 16)

            Group {
                switch selectedTab {
                case .status:
                    CompanionPanelStatusView(companionManager: companionManager)
                case .settings:
                    CompanionPanelSettingsView(viewModel: settingsViewModel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Spacer(minLength: 10)

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.8))
                .padding(.horizontal, 16)

            CompanionPanelFooterView()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 360, height: 440)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(DS.Colors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 12)
            .shadow(color: Color.black.opacity(0.28), radius: 5, x: 0, y: 2)
    }
}

private struct CompanionPanelTabBar: View {
    @Binding var selectedTab: CompanionPanelTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CompanionPanelTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedTab == tab ? DS.Colors.surface2.opacity(0.95) : Color.clear)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selectedTab == tab ? DS.Colors.borderSubtle.opacity(0.8) : Color.clear, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.72))
        )
    }
}

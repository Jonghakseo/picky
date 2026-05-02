//
//  CompanionPanelView.swift
//  Picky
//
//  The SwiftUI content hosted inside the menu bar panel.
//

import SwiftUI

enum CompanionPanelMetrics {
    static let contentWidth: CGFloat = 360
    static let contentHeight: CGFloat = 480
    static let shadowPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 18

    static var panelWidth: CGFloat { contentWidth + shadowPadding * 2 }
    static var panelHeight: CGFloat { contentHeight + shadowPadding * 2 }
}

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

            ScrollView(.vertical, showsIndicators: selectedTab == .settings) {
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
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.8))
                .padding(.horizontal, 16)

            CompanionPanelFooterView()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: CompanionPanelMetrics.contentWidth, height: CompanionPanelMetrics.contentHeight)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.36), radius: 10, x: 0, y: 5)
        .shadow(color: Color.black.opacity(0.22), radius: 3, x: 0, y: 1)
        .padding(CompanionPanelMetrics.shadowPadding)
        .frame(width: CompanionPanelMetrics.panelWidth, height: CompanionPanelMetrics.panelHeight)
        .background(Color.clear)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous)
            .fill(DS.Colors.background)
            .overlay(
                RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
            )
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

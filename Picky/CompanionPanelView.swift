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
    static let cornerRadius: CGFloat = 18

    static var panelWidth: CGFloat { contentWidth }
    static var panelHeight: CGFloat { contentHeight }
}

private enum CompanionPanelTab: String, CaseIterable, Identifiable {
    case status = "Status"
    case messages = "Messages"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .status: "sparkles"
        case .messages: "bubble.left.and.bubble.right"
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
                .padding(.bottom, 0)

            Group {
                switch selectedTab {
                case .messages:
                    CompanionPanelMessagesView(companionManager: companionManager)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .status, .settings:
                    ScrollView(.vertical, showsIndicators: selectedTab == .settings) {
                        Group {
                            switch selectedTab {
                            case .status:
                                CompanionPanelStatusView(companionManager: companionManager)
                            case .messages:
                                EmptyView()
                            case .settings:
                                CompanionPanelSettingsView(viewModel: settingsViewModel, companionManager: companionManager)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))
                .padding(.horizontal, 16)

            CompanionPanelFooterView()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: CompanionPanelMetrics.contentWidth, height: CompanionPanelMetrics.contentHeight)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: CompanionPanelMetrics.cornerRadius, style: .continuous))
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

/// Minimal tab bar: text-only buttons sitting on a hairline divider. The active tab is
/// signalled by a 1.5pt indicator under its label rather than a pill background, so the
/// whole row reads as a row of text rather than a row of chips. The icons that the older
/// design used to lean on are dropped; the three labels (Status / Messages / Settings)
/// are short enough to identify themselves.
private struct CompanionPanelTabBar: View {
    @Binding var selectedTab: CompanionPanelTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CompanionPanelTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selectedTab == tab ? DS.Colors.textPrimary : Color.clear)
                                .frame(height: 1.5)
                                .offset(y: 0.5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}

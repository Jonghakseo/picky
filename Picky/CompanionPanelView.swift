//
//  CompanionPanelView.swift
//  Picky
//
//  The SwiftUI content hosted inside the menu bar panel.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionPanelHeaderView(companionManager: companionManager)
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            CompanionPanelPermissionsCopyView(companionManager: companionManager)
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                CompanionPanelPermissionsView(companionManager: companionManager)
                    .padding(.horizontal, 16)
            }

            // Show Picky toggle — hidden for now
            // if companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showPickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            CompanionPanelFooterView()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

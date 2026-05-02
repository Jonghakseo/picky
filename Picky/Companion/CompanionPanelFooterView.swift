//
//  CompanionPanelFooterView.swift
//  Picky
//
//  Footer controls for the companion panel.
//

import AppKit
import SwiftUI

struct CompanionPanelFooterView: View {
    var body: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Picky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

        }
    }


}

//
//  CompanionPanelExtensionsView.swift
//  Picky
//
//  Second tab in the menu bar panel. Hosts the bundled Pi extensions that
//  Picky ships (picky-handoff, etc. via `CompanionPanelExtensionsSection`)
//  and a placeholder section for the curated list of useful third-party
//  extensions we plan to surface. The placeholder is intentional — it lets
//  the new tab ship with the existing handoff entry without waiting on the
//  curation list to be finalized.
//

import SwiftUI

struct CompanionPanelExtensionsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionPanelExtensionsSection()

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.4))
                .padding(.vertical, 14)

            curatedSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Placeholder for the curated third-party extension list. Same section
    /// header style as the rest of the panel so it doesn't read as a separate
    /// component; the body text is the only signal that nothing is actionable
    /// here yet.
    private var curatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("extensions.curated.heading")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "sparkles")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text("extensions.curated.comingSoon")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

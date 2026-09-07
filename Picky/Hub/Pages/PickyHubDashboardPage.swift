//
//  PickyHubDashboardPage.swift
//  Picky
//

import SwiftUI

struct PickyHubDashboardPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.dashboard.titleKey, subtitle: "hub.page.dashboard.subtitle")
        }
    }
}

//
//  PickyHubStatisticsPage.swift
//  Picky
//

import SwiftUI

struct PickyHubStatisticsPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.statistics.titleKey, subtitle: "hub.page.statistics.subtitle")
        }
    }
}

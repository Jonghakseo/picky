//
//  PickyHubQuickStartPage.swift
//  Picky
//

import SwiftUI

struct PickyHubQuickStartPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.quickStart.titleKey, subtitle: "hub.page.quickStart.subtitle")
        }
    }
}

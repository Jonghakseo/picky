//
//  PickyHubGuidesPage.swift
//  Picky
//

import SwiftUI

struct PickyHubGuidesPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.guides.titleKey, subtitle: "hub.page.guides.subtitle")
        }
    }
}

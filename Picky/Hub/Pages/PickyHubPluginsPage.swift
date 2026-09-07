//
//  PickyHubPluginsPage.swift
//  Picky
//

import SwiftUI

struct PickyHubPluginsPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.plugins.titleKey, subtitle: "hub.page.plugins.subtitle")
        }
    }
}

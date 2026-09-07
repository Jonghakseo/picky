//
//  PickyHubSettingsPage.swift
//  Picky
//

import SwiftUI

struct PickyHubSettingsPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.settings.titleKey, subtitle: "hub.page.settings.subtitle")
        }
    }
}

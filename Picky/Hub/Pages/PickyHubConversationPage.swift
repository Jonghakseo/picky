//
//  PickyHubConversationPage.swift
//  Picky
//

import SwiftUI

struct PickyHubConversationPage: View {
    let dependencies: PickyHubDependencies

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.conversation.titleKey, subtitle: "hub.page.conversation.subtitle")
        }
    }
}

//
//  PickyHubRemotePage.swift
//  Picky
//
//  "원격 접속" in the hub sidebar: the access server switch, the entrance the
//  phone uses, and paired phones (docs/remote-pwa-plan.md). It used to be a
//  group on the Settings page; it has its own page because it is something
//  the user operates (pairing, revoking, watching the address), not a
//  preference they set once.
//

import SwiftUI

struct PickyHubRemotePage: View {
    let dependencies: PickyHubDependencies
    @EnvironmentObject private var modalHost: PickyHubModalHost

    var body: some View {
        PickyHubPageScroll(page: .remote) {
            PickyHubPageHeader(title: PickyHubPage.remote.titleKey, subtitle: "hub.page.remote.subtitle")
            PickyHubRemoteAccessSection(
                settingsViewModel: dependencies.settingsViewModel,
                controller: dependencies.remoteAccess,
                modalHost: modalHost
            )
            .environment(\.pickyUsesSubtleMenuChrome, true)
        }
    }
}

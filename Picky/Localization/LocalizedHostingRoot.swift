//
//  LocalizedHostingRoot.swift
//  Picky
//
//  Every SwiftUI subtree we mount inside an AppKit host (NSHostingView /
//  NSHostingController) is rooted in this wrapper. The wrapper observes
//  `LocaleManager.shared`, injects the current locale via
//  `.environment(\.locale, ...)`, and re-renders when the user switches
//  language so the subtree retranslates without a relaunch.
//
//  Usage:
//      let host = NSHostingView(rootView: LocalizedHostingRoot { MyView() })
//

import SwiftUI

struct LocalizedHostingRoot<Content: View>: View {
    @ObservedObject private var localeManager: LocaleManager = .shared
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .environment(\.locale, localeManager.effectiveLocale)
            .environmentObject(localeManager)
    }
}

//
//  PickyHubPageMountLifecycle.swift
//  Picky
//
//  Owns the Hub page-mount invariant: a destination is created only after it
//  is selected, then remains in the window's view tree for the lifetime of
//  that tree so SwiftUI keeps its identity and transient control state. Each
//  page remains responsible for its scroll position when selected.
//

import Combine
import SwiftUI

@MainActor
final class PickyHubPageMountLifecycle: ObservableObject {
    @Published private(set) var mountedPages: Set<PickyHubPage>

    init(initialPage: PickyHubPage) {
        mountedPages = [initialPage]
    }

    func orderedMountedPages(including selectedPage: PickyHubPage) -> [PickyHubPage] {
        // Show a new destination in the selection's first render, before the
        // onChange callback records the visit for subsequent renders.
        PickyHubPage.allCases.filter { $0 == selectedPage || mountedPages.contains($0) }
    }

    func mount(_ page: PickyHubPage) {
        guard !mountedPages.contains(page) else { return }
        mountedPages.insert(page)
    }
}

/// Hosts only pages the user has reached. Mounted pages remain in the ZStack,
/// rather than being conditionally removed, which keeps their SwiftUI identity
/// and local state while another destination is selected.
struct PickyHubRetainedPageHost<Content: View>: View {
    @ObservedObject var lifecycle: PickyHubPageMountLifecycle
    let selectedPage: PickyHubPage
    @ViewBuilder let content: (PickyHubPage) -> Content

    var body: some View {
        ZStack {
            ForEach(lifecycle.orderedMountedPages(including: selectedPage)) { page in
                content(page)
                    .opacity(selectedPage == page ? 1 : 0)
                    .allowsHitTesting(selectedPage == page)
                    .accessibilityHidden(selectedPage != page)
                    .disabled(selectedPage != page)
            }
        }
        .onChange(of: selectedPage, initial: true) { _, page in
            lifecycle.mount(page)
        }
    }
}

//
//  PickyHubPageMountTests.swift
//  PickyTests
//

import AppKit
import Combine
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubPageMountTests {
    @Test func unvisitedPagesDoNotCreateTheirMountedState() {
        let fixture = HubPageMountFixture()
        let host = mount(fixture)
        defer { dismantle(host, fixture: fixture) }

        #expect(waitForHost(host) { fixture.probe(for: .dashboard).stateInstances.count == 1 })
        #expect(fixture.lifecycle.mountedPages == [.dashboard])
        for page in PickyHubPage.allCases where page != .dashboard {
            #expect(fixture.probe(for: page).stateInstances.isEmpty)
        }
    }

    @Test func visitedPageKeepsItsTransientStateWhenSelectionChanges() throws {
        let fixture = HubPageMountFixture()
        let host = mount(fixture)
        defer { dismantle(host, fixture: fixture) }

        #expect(waitForHost(host) { fixture.probe(for: .dashboard).stateInstances.count == 1 })
        let dashboardState = try #require(fixture.probe(for: .dashboard).stateInstances.first)
        dashboardState.transientValue = "unsaved-filter-query"

        fixture.navigator.select(.settings)
        #expect(waitForHost(host) { fixture.probe(for: .settings).stateInstances.count == 1 })
        #expect(fixture.lifecycle.mountedPages == [.dashboard, .settings])

        fixture.navigator.select(.dashboard)
        #expect(waitForHost(host) { fixture.navigator.selectedPage == .dashboard })
        #expect(fixture.probe(for: .dashboard).stateInstances.count == 1)
        #expect(fixture.probe(for: .dashboard).stateInstances.first === dashboardState)
        #expect(dashboardState.transientValue == "unsaved-filter-query")
    }

    @Test func selectingVisitedPageResetsItsScrollViewToTop() throws {
        let fixture = HubPageMountFixture()
        let host = mount(fixture)
        defer { dismantle(host, fixture: fixture) }

        #expect(waitForHost(host) {
            scrollViews(in: host).contains { scrollView in
                (scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height
            }
        })
        let scrollView = try #require(scrollViews(in: host).first { scrollView in
            (scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height
        })
        let documentView = try #require(scrollView.documentView)
        let initialOffset = scrollView.contentView.bounds.origin.y
        let maximumOffset = documentView.bounds.height - scrollView.contentView.bounds.height
        let scrolledOffset = min(initialOffset + 240, maximumOffset)
        try #require(scrolledOffset > initialOffset + 1)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrolledOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.y > initialOffset + 1)

        fixture.navigator.select(.settings)
        #expect(waitForHost(host) { fixture.lifecycle.mountedPages.contains(.settings) })
        fixture.navigator.select(.dashboard)

        #expect(waitForHost(host) {
            abs(scrollView.contentView.bounds.origin.y + scrollView.contentInsets.top) <= 0.5
        })
    }

    @Test func deepLinksMountTheirDestinationWithoutConsumingSettingsNavigationRequests() throws {
        let fixture = HubPageMountFixture()
        let host = mount(fixture)
        defer { dismantle(host, fixture: fixture) }
        #expect(waitForHost(host) { fixture.probe(for: .dashboard).stateInstances.count == 1 })

        let conversationURL = try #require(URL(string: "picky://hub/conversation"))
        fixture.navigator.apply(deepLink: try #require(PickyDeepLink(url: conversationURL)))
        #expect(waitForHost(host) { fixture.probe(for: .conversation).stateInstances.count == 1 })

        let settingsURL = try #require(URL(string: "picky://settings/tools"))
        fixture.navigator.apply(deepLink: try #require(PickyDeepLink(url: settingsURL)))
        #expect(waitForHost(host) {
            fixture.lifecycle.mountedPages.contains(.settings)
                && fixture.probe(for: .settings).stateInstances.count == 1
        })
        let request = try #require(fixture.navigator.consumePendingSettingsNavigation())
        #expect(request.group == .agents)
        #expect(request.leaf == .builtinTools)
    }

    @Test func focusEnvironmentUpdatesDoNotCreateUnvisitedPagesOrReplaceVisitedState() throws {
        let fixture = HubPageMountFixture()
        let host = mount(fixture)
        defer { dismantle(host, fixture: fixture) }
        #expect(waitForHost(host) { fixture.probe(for: .dashboard).stateInstances.count == 1 })

        fixture.navigator.select(.statistics)
        #expect(waitForHost(host) { fixture.probe(for: .statistics).stateInstances.count == 1 })
        let statisticsState = try #require(fixture.probe(for: .statistics).stateInstances.first)
        let mountedBeforeFocusUpdate = fixture.lifecycle.mountedPages

        fixture.controlActiveState = .key
        #expect(waitForHost(host) { textValues(in: host).contains { $0.hasSuffix("-key") } })
        fixture.controlActiveState = .inactive
        #expect(waitForHost(host) { textValues(in: host).contains { $0.hasSuffix("-inactive") } })

        #expect(fixture.lifecycle.mountedPages == mountedBeforeFocusUpdate)
        #expect(fixture.probe(for: .statistics).stateInstances.count == 1)
        #expect(fixture.probe(for: .statistics).stateInstances.first === statisticsState)
        for page in PickyHubPage.allCases where !mountedBeforeFocusUpdate.contains(page) {
            #expect(fixture.probe(for: page).stateInstances.isEmpty)
        }
    }

    private func mount(_ fixture: HubPageMountFixture) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(HubPageMountFixtureView(fixture: fixture)))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        fixture.window = window
        return host
    }

    private func waitForHost(
        _ host: NSHostingView<AnyView>,
        timeout: TimeInterval = 1,
        until condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        host.layoutSubtreeIfNeeded()
        return condition()
    }

    private func textValues(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(textValues)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews)
    }

    private func dismantle(_ host: NSHostingView<AnyView>, fixture: HubPageMountFixture) {
        fixture.window?.contentView = nil
        fixture.window?.close()
        fixture.window = nil
        host.rootView = AnyView(EmptyView())
        host.frame = .zero
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class HubPageMountFixture: ObservableObject {
    let navigator = PickyHubNavigator()
    let lifecycle = PickyHubPageMountLifecycle(initialPage: .dashboard)
    @Published var controlActiveState: ControlActiveState = .inactive
    var window: NSWindow?

    private var probes = Dictionary(
        uniqueKeysWithValues: PickyHubPage.allCases.map { ($0, HubPageMountProbe()) }
    )

    func probe(for page: PickyHubPage) -> HubPageMountProbe {
        // The dictionary is initialized from every case above.
        probes[page]!
    }
}

@MainActor
private struct HubPageMountFixtureView: View {
    @ObservedObject var fixture: HubPageMountFixture
    @ObservedObject private var navigator: PickyHubNavigator

    init(fixture: HubPageMountFixture) {
        self.fixture = fixture
        _navigator = ObservedObject(wrappedValue: fixture.navigator)
    }

    var body: some View {
        PickyHubRetainedPageHost(
            lifecycle: fixture.lifecycle,
            selectedPage: navigator.selectedPage
        ) { page in
            HubPageMountProbeView(page: page, probe: fixture.probe(for: page))
        }
        .environmentObject(navigator)
        .environment(\.controlActiveState, fixture.controlActiveState)
    }
}

@MainActor
private final class HubPageMountProbe {
    private(set) var stateInstances: [HubPageMountProbeState] = []

    func makeState() -> HubPageMountProbeState {
        let state = HubPageMountProbeState()
        stateInstances.append(state)
        return state
    }
}

@MainActor
private final class HubPageMountProbeState: ObservableObject {
    @Published var transientValue = ""
}

private struct HubPageMountProbeLabel: NSViewRepresentable {
    let value: String
    func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: value) }
    func updateNSView(_ view: NSTextField, context: Context) { view.stringValue = value }
}

@MainActor
private struct HubPageMountProbeView: View {
    let page: PickyHubPage
    @StateObject private var state: HubPageMountProbeState
    @Environment(\.controlActiveState) private var controlActiveState

    init(page: PickyHubPage, probe: HubPageMountProbe) {
        self.page = page
        _state = StateObject(wrappedValue: probe.makeState())
    }

    var body: some View {
        PickyHubPageScroll(page: page) {
            HubPageMountProbeLabel(value: "\(state.transientValue)-\(controlActiveStateLabel)")
            Color.clear.frame(height: 900)
        }
    }

    private var controlActiveStateLabel: String {
        switch controlActiveState {
        case .key: "key"
        default: "inactive"
        }
    }
}

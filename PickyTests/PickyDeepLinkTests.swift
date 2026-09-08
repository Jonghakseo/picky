//
//  PickyDeepLinkTests.swift
//  PickyTests
//
//  Pins the `picky://` URL parser the LLM emits in conversation markdown so
//  every recognised tab/settings route round-trips, and unknown routes / wrong
//  schemes do not silently get swallowed. Mirrors `PICKY_DEEP_LINK_ROUTES` in
//  `agentd/src/application/user-guide-tool.ts` — if a route appears there but
//  not in `CompanionPanelSettingsRoute.fromDeepLinkPath`, the drift surfaces
//  here instead of in production.
//

import Foundation
import Testing
@testable import Picky

private struct PickySettingsRouteExpectation {
    let path: String
    let route: CompanionPanelSettingsRoute
    let leaf: PickyHubSettingsLeaf?
}

struct PickyDeepLinkTests {
    @Test func nonPickySchemeReturnsNilAndDispatcherIgnoresIt() async throws {
        #expect(PickyDeepLink(url: URL(string: "https://picky.app/panel/status")!) == nil)
        #expect(PickyDeepLink(url: URL(string: "picky-extra://panel/status")!) == nil)

        var deliveredHandled = false
        await MainActor.run {
            PickyDeepLinkDispatcher.shared.configure { _ in deliveredHandled = true }
            let handled = PickyDeepLinkDispatcher.shared.handle(URL(string: "https://example.com")!)
            #expect(handled == false)
        }
        #expect(deliveredHandled == false)
    }

    @Test func panelHostMapsKnownTabsAndRejectsUnknown() {
        #expect(PickyDeepLink(url: URL(string: "picky://panel/status")!) == PickyDeepLink(tab: .status))
        #expect(PickyDeepLink(url: URL(string: "picky://panel/messages")!) == PickyDeepLink(tab: .messages))
        #expect(PickyDeepLink(url: URL(string: "picky://panel/settings")!) == PickyDeepLink(tab: .settings))
        #expect(PickyDeepLink(url: URL(string: "picky://panel/unknown")!) == nil)
        #expect(PickyDeepLink(url: URL(string: "picky://panel")!) == nil) // missing tab path
    }

    @Test func settingsHostMapsEveryRouteListedInDeepLinkTable() throws {
        // Current canonical paths exposed through PICKY_DEEP_LINK_ROUTES.
        let expected = [
            PickySettingsRouteExpectation(path: "general", route: .general, leaf: nil),
            PickySettingsRouteExpectation(path: "shortcuts", route: .shortcuts, leaf: nil),
            PickySettingsRouteExpectation(path: "mainAgent", route: .mainAgent, leaf: nil),
            PickySettingsRouteExpectation(path: "pickle", route: .pickle, leaf: nil),
            PickySettingsRouteExpectation(path: "tools", route: .builtinTools, leaf: .builtinTools),
            PickySettingsRouteExpectation(path: "voice", route: .voice, leaf: nil),
            PickySettingsRouteExpectation(path: "overlayAndNotifications", route: .overlayAndNotifications, leaf: nil),
            PickySettingsRouteExpectation(path: "onboarding", route: .onboarding, leaf: nil),
            PickySettingsRouteExpectation(path: "index", route: .index, leaf: nil)
        ]
        for expectation in expected {
            let url = try #require(URL(string: "picky://settings/\(expectation.path)"))
            let link = PickyDeepLink(url: url)
            #expect(
                link == PickyDeepLink(
                    tab: .settings,
                    settingsRoute: expectation.route,
                    settingsLeaf: expectation.leaf
                ),
                "picky://settings/\(expectation.path) should preserve its leaf"
            )
        }
    }

    @Test func settingsHostKeepsLegacyAliasesForRouteReorg() throws {
        // Pre-reorg paths the assistant may have already emitted and external
        // bookmarks may still point at. They redirect into the new combined
        // routes so existing links keep working without surfacing a 404.
        let aliases = [
            PickySettingsRouteExpectation(
                path: "notification",
                route: .overlayAndNotifications,
                leaf: .notifications
            ),
            PickySettingsRouteExpectation(
                path: "cursorBubbles",
                route: .overlayAndNotifications,
                leaf: .cursorBubbles
            ),
            PickySettingsRouteExpectation(
                path: "builtinTools",
                route: .builtinTools,
                leaf: .builtinTools
            )
        ]
        for expectation in aliases {
            let url = try #require(URL(string: "picky://settings/\(expectation.path)"))
            let link = PickyDeepLink(url: url)
            #expect(
                link == PickyDeepLink(
                    tab: .settings,
                    settingsRoute: expectation.route,
                    settingsLeaf: expectation.leaf
                ),
                "picky://settings/\(expectation.path) should preserve its leaf"
            )
        }
    }

    @Test func settingsHostWithoutPathFallsBackToIndex() {
        #expect(PickyDeepLink(url: URL(string: "picky://settings")!) == PickyDeepLink(tab: .settings, settingsRoute: .index))
        #expect(PickyDeepLink(url: URL(string: "picky://settings/")!) == PickyDeepLink(tab: .settings, settingsRoute: .index))
    }

    @Test func settingsHostRejectsUnknownRoutes() {
        #expect(PickyDeepLink(url: URL(string: "picky://settings/totally-unknown")!) == nil)
    }

    @Test func parserIsCaseInsensitiveOnSchemeAndHostButNotOnPathComponent() {
        // Scheme + host go through `.lowercased()`.
        #expect(PickyDeepLink(url: URL(string: "PICKY://Panel/status")!) == PickyDeepLink(tab: .status))
        #expect(PickyDeepLink(url: URL(string: "picky://SETTINGS/general")!) == PickyDeepLink(tab: .settings, settingsRoute: .general))
        // Path components are matched verbatim — `OverlayAndNotifications` !== `overlayAndNotifications`.
        // This locks down the casing contract so the LLM-emitted table stays in sync.
        #expect(PickyDeepLink(url: URL(string: "picky://settings/OverlayAndNotifications")!) == nil)
        #expect(PickyDeepLink(url: URL(string: "picky://panel/STATUS")!) == nil)
    }

    @MainActor @Test func dispatcherReportsSchemeMatchEvenForUnknownPathsAndOnlyFiresHandlerOnSuccess() {
        var deliveredLinks: [PickyDeepLink] = []
        PickyDeepLinkDispatcher.shared.configure { deliveredLinks.append($0) }

        let knownHandled = PickyDeepLinkDispatcher.shared.handle(URL(string: "picky://settings/voice")!)
        #expect(knownHandled == true)
        #expect(deliveredLinks == [PickyDeepLink(tab: .settings, settingsRoute: .voice)])

        // Unknown `picky://` paths still report `true` so the system URL handler
        // doesn't try to open them in a browser, but the handler must not fire
        // with a bogus link.
        let unknownHandled = PickyDeepLinkDispatcher.shared.handle(URL(string: "picky://panel/whatever")!)
        #expect(unknownHandled == true)
        #expect(deliveredLinks.count == 1)

        // Non-`picky` schemes short-circuit before the handler entirely.
        let nonPicky = PickyDeepLinkDispatcher.shared.handle(URL(string: "mailto:hi@example.com")!)
        #expect(nonPicky == false)
        #expect(deliveredLinks.count == 1)
    }
}

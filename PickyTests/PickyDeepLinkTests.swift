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

    @Test func settingsHostMapsEveryRouteListedInDeepLinkTable() {
        // Current canonical paths exposed through PICKY_DEEP_LINK_ROUTES.
        let expected: [(String, CompanionPanelSettingsRoute)] = [
            ("general", .general),
            ("shortcuts", .shortcuts),
            ("mainAgent", .mainAgent),
            ("pickle", .pickle),
            ("tools", .builtinTools),
            ("voice", .voice),
            ("overlayAndNotifications", .overlayAndNotifications),
            ("onboarding", .onboarding),
            ("index", .index),
        ]
        for (path, route) in expected {
            let link = PickyDeepLink(url: URL(string: "picky://settings/\(path)")!)
            #expect(link == PickyDeepLink(tab: .settings, settingsRoute: route), "picky://settings/\(path) should map to \(route)")
        }
    }

    @Test func settingsHostKeepsLegacyAliasesForRouteReorg() {
        // Pre-reorg paths the assistant may have already emitted and external
        // bookmarks may still point at. They redirect into the new combined
        // routes so existing links keep working without surfacing a 404.
        let aliases: [(String, CompanionPanelSettingsRoute)] = [
            ("notification", .overlayAndNotifications),
            ("cursorBubbles", .overlayAndNotifications),
            ("builtinTools", .builtinTools),
        ]
        for (path, route) in aliases {
            let link = PickyDeepLink(url: URL(string: "picky://settings/\(path)")!)
            #expect(link == PickyDeepLink(tab: .settings, settingsRoute: route), "picky://settings/\(path) should alias to \(route)")
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

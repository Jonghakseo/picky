//
//  PickyHubSettingsRuntimeContractTests.swift
//  PickyTests
//
//  Production Root/Settings contracts exercised through native AppKit output.
//

import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHubSettingsRuntimeContractTests {
    @Test func toolsDeepLinkMountsSettingsAndExpandsBuiltinToolsOnFirstVisit() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = try PickyHubRenderGalleryFixture()
            let (window, host) = mountProductionHub(fixture)
            defer {
                window.contentView = nil
                window.close()
                dismantle(host)
                fixture.removeTemporaryState()
            }

            host.layoutSubtreeIfNeeded()
            #expect(nativePopUpButtons(in: host).filter { $0.itemTitles.first == "70%" && $0.itemTitles.last == "250%" }.isEmpty)

            let url = try #require(URL(string: "picky://settings/tools"))
            fixture.navigator.apply(deepLink: try #require(PickyDeepLink(url: url)))

            // Offscreen SwiftUI does not publish its AX text tree. Verify the
            // actual visible pixels instead, without ordering a window or asking
            // for screen-recording/accessibility permission.
            // This is a render/content assertion, not a latency budget. Allow
            // Vision's first model load; keep performance timing in its own host.
            #expect(waitForHost(host, timeout: 5) {
                guard fixture.navigator.pendingSettingsNavigation == nil else { return false }
                return (try? renderedText(in: host).contains("pickyscreenoverlay")) == true
            })
        }
    }

    @Test func settingsGroupLinksRemainPinnedAfterScrolling() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = try PickyHubRenderGalleryFixture()
            fixture.navigator.select(.settings)
            let (window, host) = mountProductionHub(fixture)
            defer {
                window.contentView = nil
                window.close()
                dismantle(host)
                fixture.removeTemporaryState()
            }

            #expect(waitForHost(host) {
                scrollViews(in: host).contains { $0.documentView?.bounds.height ?? 0 > $0.contentView.bounds.height }
            })
            let scrollView = try #require(scrollViews(in: host).first {
                $0.documentView?.bounds.height ?? 0 > $0.contentView.bounds.height
            })
            let documentView = try #require(scrollView.documentView)
            let maximumOffset = documentView.bounds.height - scrollView.contentView.bounds.height
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(280, maximumOffset)))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let pageSubtitle = normalized(L10n.t("hub.page.settings.subtitle"))
            let advancedGroup = normalized(L10n.t("hub.settings.group.advanced.title"))
            #expect(waitForHost(host) {
                guard let visibleText = try? renderedText(in: host) else { return false }
                return !visibleText.contains(pageSubtitle) && visibleText.contains(advancedGroup)
            })
        }
    }

    @Test func reportTerminalAndUpdateChannelMenusPersistIndependentSelectionsFromNativeActions() async throws {
        let fixture = try PickyHubRenderGalleryFixture()
        let (window, host) = mountProductionHub(fixture)
        defer {
            window.contentView = nil
            window.close()
            dismantle(host)
            fixture.removeTemporaryState()
        }

        fixture.navigator.select(.settings)
        try #require(waitForHost(host) {
            nativePopUpButtons(in: host).filter { $0.itemTitles.first == "70%" && $0.itemTitles.last == "250%" }.count == 2
        })

        let reportMenu = try popup(
            in: host,
            accessibilityLabel: L10n.t("hub.settings.reportFontScale"),
            items: percentageItems
        )
        let terminalMenu = try popup(
            in: host,
            accessibilityLabel: L10n.t("hub.settings.terminalFontScale"),
            items: percentageItems
        )
        let updateChannelMenu = try popup(
            in: host,
            accessibilityLabel: L10n.t("hub.settings.updateChannel"),
            items: PickyUpdateChannel.allCases.map(\.displayName)
        )

        let channel: PickyUpdateChannel = fixture.readPersistedSettings().updateChannel == .beta ? .stable : .beta
        try select("130%", in: reportMenu)
        try select("190%", in: terminalMenu)
        try select(channel.displayName, in: updateChannelMenu)

        try await waitUntilPersisted {
            host.layoutSubtreeIfNeeded()
            let settings = fixture.readPersistedSettings()
            return settings.fontScales.markdownReport == 1.3
                && settings.fontScales.terminal == 1.9
                && settings.updateChannel == channel
        }

        let persisted = fixture.readPersistedSettings()
        #expect(persisted.fontScales.markdownReport == 1.3)
        #expect(persisted.fontScales.terminal == 1.9)
        #expect(persisted.updateChannel == channel)
    }

    @Test func languageChangesRefreshNativeLabelsWithoutReplacingTheMenu() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = try PickyHubRenderGalleryFixture()
            fixture.navigator.select(.settings)
            let (window, host) = mountProductionHub(fixture)
            defer { window.contentView = nil; window.close(); dismantle(host); fixture.removeTemporaryState() }
            let keys = ["hub.settings.appearance.dark", "hub.settings.appearance.light"]
            try #require(waitForHost(host) { nativePopUpButtons(in: host).contains { $0.itemTitles == keys.map { L10n.t($0) } } })
            let control = try popup(in: host, accessibilityLabel: L10n.t("hub.settings.appearance"), items: keys.map { L10n.t($0) })
            let menu = control.menu
            let items = control.itemArray
            try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
                try #require(waitForHost(host) {
                    control.itemTitles == keys.map { L10n.t($0) }
                        && control.accessibilityLabel() == L10n.t("hub.settings.appearance")
                })
                #expect(control.menu === menu)
                #expect(zip(control.itemArray, items).allSatisfy { $0 === $1 })
            }
        }
    }

    private var percentageItems: [String] {
        (7...25).map { "\($0 * 10)%" }
    }

    private func mountProductionHub(_ fixture: PickyHubRenderGalleryFixture) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(
            PickyAppFontScaleRoot(store: fixture.fontScaleStore) {
                PickyHubRootView(dependencies: fixture.dependencies, dockDisplayIDProvider: { nil })
                    .environmentObject(fixture.appearanceStore)
                    .environmentObject(fixture.hudVisibilityStore)
                    .environmentObject(fixture.updaterController)
                    .environmentObject(fixture.pluginReloadController)
                    .transaction { $0.disablesAnimations = true }
                    .frame(width: 1020, height: 720)
            }
        )
        let host = NSHostingView(rootView: AnyView(LocalizedHostingRoot { root }))
        host.frame = NSRect(x: 0, y: 0, width: 1020, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Attach the real AX tree, but never order or activate this window.
        return (window, host)
    }

    private func popup(
        in host: NSView,
        accessibilityLabel: String,
        items: [String]
    ) throws -> NSPopUpButton {
        let matches = nativePopUpButtons(in: host).filter {
            $0.itemTitles == items && PickyHubAccessibilityObservation.label(of: $0) == accessibilityLabel
        }
        guard matches.count == 1, let popup = matches.first else {
            throw RuntimeContractError.popupNotFound(label: accessibilityLabel, count: matches.count)
        }
        return popup
    }

    private func select(_ title: String, in popup: NSPopUpButton) throws {
        popup.selectItem(withTitle: title)
        guard popup.titleOfSelectedItem == title else {
            throw RuntimeContractError.optionNotFound(title)
        }
        guard popup.sendAction(popup.action, to: popup.target) else {
            throw RuntimeContractError.actionNotDelivered(title)
        }
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

    private func waitUntilPersisted(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RuntimeContractError.persistenceTimedOut
    }

    private func nativePopUpButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(nativePopUpButtons)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func renderedText(in host: NSView) throws -> String {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/perf/hub-focus/deeplink.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return normalized(lines.joined())
    }

    private func dismantle(_ host: NSHostingView<AnyView>) {
        host.rootView = AnyView(EmptyView())
        host.frame = .zero
        host.layoutSubtreeIfNeeded()
    }

    private enum RuntimeContractError: Error {
        case popupNotFound(label: String, count: Int)
        case optionNotFound(String)
        case actionNotDelivered(String)
        case persistenceTimedOut
    }
}

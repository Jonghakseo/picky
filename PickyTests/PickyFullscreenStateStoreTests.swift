//
//  PickyFullscreenStateStoreTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
@Suite("PickyFullscreenStateStore")
struct PickyFullscreenStateStoreTests {
    @Test func defaultsToShowingWorkInfoPanelWithoutSelection() {
        let defaults = makeDefaults()
        let store = PickyFullscreenStateStore(defaults: defaults)

        #expect(store.isWorkInfoPanelVisible)
        #expect(store.selectedSessionID == nil)
    }

    @Test func persistsWorkInfoPanelVisibility() {
        let defaults = makeDefaults()
        let store = PickyFullscreenStateStore(defaults: defaults)

        store.isWorkInfoPanelVisible = false

        let reloaded = PickyFullscreenStateStore(defaults: defaults)
        #expect(!reloaded.isWorkInfoPanelVisible)
    }

    @Test func persistsSelectedSessionID() {
        let defaults = makeDefaults()
        let store = PickyFullscreenStateStore(defaults: defaults)

        store.selectedSessionID = "session-123"

        let reloaded = PickyFullscreenStateStore(defaults: defaults)
        #expect(reloaded.selectedSessionID == "session-123")
    }

    @Test func clearsEmptySelectedSessionID() {
        let defaults = makeDefaults()
        let store = PickyFullscreenStateStore(defaults: defaults)
        store.selectedSessionID = "session-123"

        store.selectedSessionID = ""

        let reloaded = PickyFullscreenStateStore(defaults: defaults)
        #expect(reloaded.selectedSessionID == nil)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "picky-fullscreen-state-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

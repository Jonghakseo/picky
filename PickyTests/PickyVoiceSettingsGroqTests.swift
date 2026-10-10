//
//  PickyVoiceSettingsGroqTests.swift
//  PickyTests
//
//  Mounts the production voice settings and exercises the Groq choice.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyVoiceSettingsGroqTests {
    @Test func choosingGroqInTheServiceMenuPersistsAndShowsGroqControls() async throws {
        let fixture = try PickyHubRenderGalleryFixture()
        defer { fixture.removeTemporaryState() }
        let root = CompanionPanelSettingsView(
            viewModel: fixture.dependencies.settingsViewModel,
            companionManager: fixture.dependencies.companionManager,
            mainConversation: fixture.dependencies.companionManager.mainConversation,
            archiveMembership: fixture.dependencies.sessionListViewModel.sessionRegistry,
            archiveCommands: fixture.dependencies.sessionListViewModel,
            route: .constant(.voice),
            presentation: .embedded
        )
        .environment(\.pickyUsesSubtleMenuChrome, true)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 2400)
        host.layoutSubtreeIfNeeded()

        func menus(in view: NSView) -> [NSPopUpButton] {
            ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap { menus(in: $0) }
        }
        let groqTitle = PickyVoiceProviderSelection.groq.displayName(for: .transcription)
        let serviceMenu = try #require(menus(in: host).first { $0.itemTitles.contains(groqTitle) })
        #expect(serviceMenu.itemTitles.first == "Apple Speech")
        #expect(!menus(in: host).contains { $0.itemTitles.contains("日本語") })

        serviceMenu.selectItem(withTitle: groqTitle)
        #expect(serviceMenu.sendAction(serviceMenu.action, to: serviceMenu.target))

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fixture.readPersistedSettings().sttProvider != .groq, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.readPersistedSettings().sttProvider == .groq)
        #expect(fixture.readPersistedSettings().sttVocabulary == PickyTranscriptionVocabulary.defaultTermsText)

        host.layoutSubtreeIfNeeded()
        // The Groq-only spoken-language menu appears once Groq is selected.
        #expect(menus(in: host).contains { $0.itemTitles.contains("日本語") })
    }
}

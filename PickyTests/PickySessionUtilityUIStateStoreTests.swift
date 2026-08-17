//
//  PickySessionUtilityUIStateStoreTests.swift
//  PickyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickySessionUtilityUIStateStoreTests {
    @Test func selectedTabPersistsPerSessionAndUnknownStoredValueFallsBackToTerminal() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let store = PickySessionUtilityUIStateStore(defaults: fixture.defaults)
        store.select(.activity, for: "pickle-a")
        store.select(.artifacts, for: "pickle-b")

        let reloaded = PickySessionUtilityUIStateStore(defaults: fixture.defaults)
        #expect(reloaded.selectedTab(for: "pickle-a") == .activity)
        #expect(reloaded.selectedTab(for: "pickle-b") == .artifacts)
        #expect(reloaded.selectedTab(for: "missing") == .terminal)

        let stalePayload = try JSONSerialization.data(withJSONObject: [
            "stale": ["selectedTabRawValue": "changes"]
        ])
        fixture.defaults.set(stalePayload, forKey: PickySessionUtilityUIStateStore.storageKey)
        let staleReloaded = PickySessionUtilityUIStateStore(defaults: fixture.defaults)
        #expect(staleReloaded.selectedTab(for: "stale") == .terminal)
    }

    @Test func markArtifactsSeenRequiresTheSelectedTabAndAnActuallyVisiblePanel() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let store = PickySessionUtilityUIStateStore(defaults: fixture.defaults)
        let panelVisibility = PickyHUDActualPanelVisibilityStore()
        let displayID: CGDirectDisplayID = 42
        let configuredDockIsVisible = true
        let firstArtifact = Date(timeIntervalSince1970: 1_700_000_000)
        let artifactDuringSuppression = firstArtifact.addingTimeInterval(1)

        panelVisibility.setVisible(true, for: displayID)
        store.markArtifactsSeen(
            for: "pickle-a",
            at: firstArtifact,
            isArtifactsTabSelected: false,
            isHUDPanelVisible: configuredDockIsVisible && panelVisibility.isVisible(for: displayID)
        )
        #expect(store.lastSeenArtifactsAt(for: "pickle-a") == nil)

        store.markArtifactsSeen(
            for: "pickle-a",
            at: firstArtifact,
            isArtifactsTabSelected: true,
            isHUDPanelVisible: configuredDockIsVisible && panelVisibility.isVisible(for: displayID)
        )
        #expect(store.lastSeenArtifactsAt(for: "pickle-a") == firstArtifact)

        // The persisted dock preference remains visible while AppKit has
        // ordered the panel out for a secure authorization surface.
        panelVisibility.setVisible(false, for: displayID)
        store.markArtifactsSeen(
            for: "pickle-a",
            at: artifactDuringSuppression,
            isArtifactsTabSelected: true,
            isHUDPanelVisible: configuredDockIsVisible && panelVisibility.isVisible(for: displayID)
        )
        #expect(store.lastSeenArtifactsAt(for: "pickle-a") == firstArtifact)

        panelVisibility.setVisible(true, for: displayID)
        store.markArtifactsSeen(
            for: "pickle-a",
            at: artifactDuringSuppression,
            isArtifactsTabSelected: true,
            isHUDPanelVisible: configuredDockIsVisible && panelVisibility.isVisible(for: displayID)
        )
        #expect(store.lastSeenArtifactsAt(for: "pickle-a") == artifactDuringSuppression)

        panelVisibility.removePanel(for: displayID)
        store.markArtifactsSeen(
            for: "pickle-a",
            at: artifactDuringSuppression.addingTimeInterval(1),
            isArtifactsTabSelected: true,
            isHUDPanelVisible: configuredDockIsVisible && panelVisibility.isVisible(for: displayID)
        )
        #expect(store.lastSeenArtifactsAt(for: "pickle-a") == artifactDuringSuppression)

        store.remove(sessionID: "pickle-a")
        #expect(store.lastSeenArtifactsAt(for: "pickle-a") == nil)
    }

    @Test func artifactsPresentationFiltersSortsAndCountsUnseenFiles() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let artifacts = [
            PickyArtifact(id: "link", kind: "github", title: "PR", path: nil, url: URL(string: "https://github.com")!, updatedAt: newer),
            PickyArtifact(id: "old-file", kind: "file", title: "Old", path: "/tmp/old.md", url: nil, updatedAt: older),
            PickyArtifact(id: "new-file", kind: "file", title: "New", path: "/tmp/new.pdf", url: nil, updatedAt: newer),
        ]

        #expect(PickySessionArtifactsPresentation.fileArtifacts(from: artifacts).map(\.id) == ["new-file", "old-file"])
        #expect(PickySessionArtifactsPresentation.unseenCount(artifacts: artifacts, lastSeenArtifactsAt: nil) == 2)
        #expect(PickySessionArtifactsPresentation.unseenCount(artifacts: artifacts, lastSeenArtifactsAt: older) == 1)
        #expect(PickySessionArtifactsPresentation.unseenCount(artifacts: artifacts, lastSeenArtifactsAt: newer) == 0)
    }

    @Test func artifactRowMarksMissingPathsAndKeepsTheirCopyablePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("report.md")
        try "report".write(to: existing, atomically: true, encoding: .utf8)
        let present = PickySessionArtifactRowPresentation(
            artifact: PickyArtifact(id: "present", kind: "file", title: "Report", path: existing.path, url: nil, updatedAt: .now),
            homeURL: root
        )
        let missing = PickySessionArtifactRowPresentation(
            artifact: PickyArtifact(id: "missing", kind: "file", title: "Missing", path: root.appendingPathComponent("missing.md").path, url: nil, updatedAt: .now),
            homeURL: root
        )

        #expect(present.isMissing == false)
        #expect(missing.isMissing)
        #expect(missing.artifact.path?.hasSuffix("missing.md") == true)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PickySessionUtilityUIStateStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

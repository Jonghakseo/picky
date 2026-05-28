//
//  PickyFullscreenFileDiffProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenFileDiffProvider")
struct PickyFullscreenFileDiffProviderTests {
    @Test func parsesNumstatByPath() {
        let output = """
        12\t3\tPicky/Fullscreen/Views/PickyFullscreenWorkInfoPanelView.swift
        0\t8\tdocs/picky-fullscreen-mode-implementation-plan.md
        -\t-\tAssets/logo.png
        34\t0\tdocs/release-retro-2026-05.md
        """

        let parsed = PickyFullscreenFileDiffProvider.parseNumstat(output)

        #expect(parsed["Picky/Fullscreen/Views/PickyFullscreenWorkInfoPanelView.swift"] == .init(insertions: 12, deletions: 3))
        #expect(parsed["docs/picky-fullscreen-mode-implementation-plan.md"] == .init(insertions: 0, deletions: 8))
        #expect(parsed["docs/release-retro-2026-05.md"] == .init(insertions: 34, deletions: 0))
        #expect(parsed["Assets/logo.png"] == nil)
    }

    @MainActor
    @Test func nonGitCwdReturnsEmptyResultsGracefully() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyFullscreenFileDiffProviderTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = PickyFullscreenFileDiffProvider(cwd: directory.path)

        let stats = await provider.fetchNumstat()
        let diff = await provider.fetchDiff(path: "Picky/File.swift")

        #expect(stats.isEmpty)
        #expect(diff == nil)
    }
}

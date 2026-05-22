//
//  PickyDiffReviewRepoWatcherTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("Diff review repo watcher")
struct PickyDiffReviewRepoWatcherTests {
    @Test func isIgnoredWatchPathMatchesReferenceRules() {
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("") == false)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("node_modules/foo") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("src/.git/HEAD") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("src/main.swift") == false)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("dist/index.html") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("tmp/scratch") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath(".DS_Store") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("foo.swp") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("foo.tmp") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("foo~") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("coverage/") == true)
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath("Sources/App/main.swift") == false)
    }

    @Test func relativizingAbsolutePathsUnderRepoUnderIgnoredAncestorDoesNotIgnoreReviewableFile() {
        let result = PickyDiffReviewRepoWatcher.relativizeForIgnoreCheck(
            absolutePath: "/tmp/foo/src/Main.swift",
            repoRoot: "/tmp/foo"
        )
        #expect(result == "src/Main.swift")
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath(result) == false)
    }

    @Test func relativizingAbsolutePathsOutsideRepoReturnsOriginal() {
        let result = PickyDiffReviewRepoWatcher.relativizeForIgnoreCheck(
            absolutePath: "/var/log/system.log",
            repoRoot: "/tmp/foo"
        )
        #expect(result == "/var/log/system.log")
    }

    @Test func relativizingThenIgnoreCheckRespectsRepoLocalNodeModules() {
        let result = PickyDiffReviewRepoWatcher.relativizeForIgnoreCheck(
            absolutePath: "/tmp/foo/node_modules/foo/index.js",
            repoRoot: "/tmp/foo"
        )
        #expect(result == "node_modules/foo/index.js")
        #expect(PickyDiffReviewRepoWatcher.isIgnoredWatchPath(result) == true)
    }
}

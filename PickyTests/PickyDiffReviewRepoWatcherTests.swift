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
}

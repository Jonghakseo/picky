//
//  PickyDiffViewerTests.swift
//  PickyTests
//

import XCTest
@testable import Picky

final class PickyDiffViewerTests: XCTestCase {
    func testUnifiedDiffLineKindsClassifyGitHeadersBeforeAdditionsAndDeletions() {
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "diff --git a/old.txt b/new.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "--- a/old.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "+++ b/new.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "rename from old.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "rename to new.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "@@ -1,2 +1,2 @@"), .hunk)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "+added line"), .addition)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "-deleted line"), .deletion)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: " unchanged line"), .context)
    }

    func testUnifiedDiffLinesPreserveOrderAndStableOffsets() {
        let lines = PickyDiffUnifiedDiffLine.lines(from: "@@ -1 +1 @@\n-old\n+new")

        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(lines.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(lines.map(\.text), ["@@ -1 +1 @@", "-old", "+new"])
    }
}

//
//  PickyDiffReviewWebHostTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("Diff review web host")
struct PickyDiffReviewWebHostTests {
    @Test func renderHTML_replacesInlineDataPlaceholderWithEncodedData() throws {
        let rendered = try PickyDiffReviewWebHost.renderHTML(
            template: #"<script id="diff-review-data" type="application/json">"__INLINE_DATA__"</script>"#,
            appJs: "",
            initialData: reviewData(repoRoot: "/tmp/repo")
        )

        #expect(!rendered.contains(#""__INLINE_DATA__""#))
        #expect(rendered.contains(#""repoRoot":"\/tmp\/repo""#))
    }

    @Test func renderHTML_replacesInlineJsPlaceholderWithAppJs() throws {
        let appJs = "function bootReview() { return true; }"
        let rendered = try PickyDiffReviewWebHost.renderHTML(
            template: "<script>__INLINE_JS__</script>",
            appJs: appJs,
            initialData: reviewData()
        )

        #expect(!rendered.contains("__INLINE_JS__"))
        #expect(rendered.contains(appJs))
    }

    @Test func renderHTML_escapesScriptCloseTagInData() throws {
        let rendered = try PickyDiffReviewWebHost.renderHTML(
            template: #"<script id="diff-review-data" type="application/json">"__INLINE_DATA__"</script>"#,
            appJs: "",
            initialData: reviewData(repoRoot: "/tmp/repo</script><script>alert(1)</script>")
        )
        let jsonBlock = try #require(rendered.slice(between: #"<script id="diff-review-data" type="application/json">"#, and: "</script>"))

        #expect(!jsonBlock.contains("</script>"))
        #expect(jsonBlock.contains(#"\u003c\/script\u003e"#))
    }

    private func reviewData(repoRoot: String = "/tmp/repo") -> ReviewWindowData {
        ReviewWindowData(
            repoRoot: repoRoot,
            files: [],
            commits: [],
            branchBaseRef: nil,
            branchMergeBaseSha: nil,
            repositoryHasHead: true
        )
    }
}

private extension String {
    func slice(between start: String, and end: String) -> String? {
        guard let startRange = range(of: start) else { return nil }
        let remainder = self[startRange.upperBound...]
        guard let endRange = remainder.range(of: end) else { return nil }
        return String(remainder[..<endRange.lowerBound])
    }
}

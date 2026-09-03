//
//  PickyExtensionCustomMessagePresentationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private func customMessage(text: String?, customType: String?, kind: PickySessionMessageKind = .system) -> PickySessionMessage {
    PickySessionMessage(
        id: "message-1",
        kind: kind,
        createdAt: Date(timeIntervalSince1970: 0),
        originatedBy: .piExtension,
        text: text,
        question: nil,
        cancelledAt: nil,
        activitySnapshot: nil,
        errorContext: nil,
        errorMessage: nil,
        customType: customType
    )
}

/// `PickyConversationBubbleKind` is main-actor isolated, so the suite runs on
/// the main actor rather than reaching across isolation from a nonisolated test.
@MainActor
@Suite("Extension custom message collapse policy")
struct PickyExtensionCustomMessagePresentationTests {
    @Test("Collapses one job down to its status header")
    func collapsesSingleJobToItsHeader() throws {
        let text = """
        [bash_async job-1] build: completed (exit 0) in 42s
        npm warn deprecated
        build finished
        Log: /tmp/job-1.log
        """
        let presentation = try #require(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: text, customType: "bash-async-completion")
        ))

        #expect(presentation.customType == "bash-async-completion")
        #expect(presentation.previewLines == ["[bash_async job-1] build: completed (exit 0) in 42s"])
        #expect(presentation.isCollapsible)
        #expect(presentation.hiddenLineCount == 3)
        #expect(presentation.fullText == text)
    }

    /// Regression: a preview built from "the first N lines" would bury job 2's
    /// failure under job 1's output tail, so a batch could report success while
    /// hiding a failure.
    @Test("Keeps every job status visible in a mixed-result batch")
    func keepsFailingJobVisibleInBatch() throws {
        let text = """
        [bash_async job-1] build: completed (exit 0) in 42s
        npm warn deprecated
        build finished
        Log: /tmp/job-1.log

        [bash_async job-2] tests: failed (exit 1) in 12s
        3 failing
        Log: /tmp/job-2.log
        """
        let presentation = try #require(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: text, customType: "bash-async-completion")
        ))

        #expect(presentation.previewLines == [
            "[bash_async job-1] build: completed (exit 0) in 42s",
            "[bash_async job-2] tests: failed (exit 1) in 12s",
        ])
        #expect(presentation.isCollapsible)
        #expect(presentation.fullText.contains("3 failing"))
    }

    @Test("Applies to every customType, not just bash_async")
    func appliesToAnyCustomType() throws {
        let text = """
        # prompt-suggest-lite

        - enabled: true
        - status: idle
        - lastError: none
        """
        let presentation = try #require(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: text, customType: "prompt-suggest-lite-status")
        ))

        #expect(presentation.customType == "prompt-suggest-lite-status")
        #expect(presentation.previewLines == ["# prompt-suggest-lite", "- enabled: true"])
        #expect(presentation.hiddenLineCount == 3)
    }

    @Test("Preview stays inside Pi's collapsed line budget")
    func previewIsBounded() throws {
        let text = (1...40).map { "block \($0)\ndetail" }.joined(separator: "\n\n")
        let presentation = try #require(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: text, customType: "noisy-extension")
        ))

        #expect(presentation.previewLines.count == PickyExtensionCustomMessagePresentation.maxPreviewLines)
        #expect(presentation.previewLines.first == "block 1")
        #expect(presentation.isCollapsible)
    }

    @Test("Single-line extension output stays uncollapsible")
    func singleLineIsNotCollapsible() throws {
        let presentation = try #require(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: "\nContent fetched for 3/3 URLs [f1].\n\n", customType: "web-search-content-ready")
        ))

        #expect(presentation.previewLines == ["Content fetched for 3/3 URLs [f1]."])
        #expect(!presentation.isCollapsible)
        #expect(presentation.hiddenLineCount == 0)
    }

    @Test("Untagged system messages keep the plain agent bubble")
    func requiresCustomType() {
        #expect(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: "Session compacted", customType: nil)
        ) == nil)
        #expect(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: "Session compacted", customType: "   ")
        ) == nil)
        #expect(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: "hello", customType: "some-type", kind: .agentText)
        ) == nil)
        #expect(PickyExtensionCustomMessagePresentation.make(
            message: customMessage(text: "  \n \n", customType: "some-type")
        ) == nil)
    }

    @Test("Tagged extension messages route to the collapsible bubble kind")
    func routesToCollapsibleBubbleKind() {
        let tagged = PickyConversationBubbleKind(
            message: customMessage(text: "headline\ndetail", customType: "bash-async-completion")
        )
        guard case .extensionCustomMessage(let presentation) = tagged else {
            Issue.record("expected extensionCustomMessage, got \(tagged)")
            return
        }
        #expect(presentation.previewLines == ["headline"])
        #expect(presentation.fullText == "headline\ndetail")

        let untagged = PickyConversationBubbleKind(
            message: customMessage(text: "headline\ndetail", customType: nil)
        )
        #expect(untagged == .systemText)
    }

    @Test("Notify messages keep their dedicated bubble")
    func notifyWins() {
        var message = customMessage(text: "warning body", customType: "some-type")
        message.notifyType = .warning

        #expect(PickyConversationBubbleKind(message: message) == .notify)
    }
}

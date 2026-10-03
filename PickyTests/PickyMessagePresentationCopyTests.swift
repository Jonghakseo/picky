//
//  PickyMessagePresentationCopyTests.swift
//  PickyTests
//
//  agentd journals its own sentences in English for the CLI and tags them with
//  a semantic code. These cases pin the contract the HUD depends on: a known
//  code renders from Picky's catalog in the selected language, and anything
//  else keeps the daemon's text verbatim.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyMessagePresentationCopyTests {
    @Test func systemBubbleRendersPickyAuthoredLinesInTheSelectedLanguage() {
        let cancelled = systemMessage(
            text: "Cancelled by user",
            presentation: PickyMessagePresentation(code: .sessionCancelledByUser)
        )
        let pinned = systemMessage(
            text: "Pinned from idle Pi session",
            presentation: PickyMessagePresentation(code: .sessionPinnedFromIdlePi)
        )

        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyAgentBubbleView(message: cancelled).displayedMarkdown == "사용자가 작업을 중단했어요")
            #expect(PickyAgentBubbleView(message: pinned).displayedMarkdown == "대기 중인 Pi 세션에서 가져왔어요")
        }
        LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            #expect(PickyAgentBubbleView(message: cancelled).displayedMarkdown == "Cancelled by user")
            #expect(PickyAgentBubbleView(message: pinned).displayedMarkdown == "Pinned from idle Pi session")
        }
    }

    // Pi's own output, extension text, and journals written before the daemon sent codes all
    // arrive without a presentation, and must render exactly as the daemon stored them.
    @Test func messageWithoutAPresentationKeepsTheDaemonText() {
        let message = systemMessage(text: "Session restored from disk", presentation: nil)

        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyAgentBubbleView(message: message).displayedMarkdown == "Session restored from disk")
        }
    }

    // A newer daemon can introduce a code this build does not know; the English fallback it
    // journals alongside the code is what keeps that message readable.
    // A malformed presentation must cost only the localized copy, never the message itself:
    // one undecodable message would make the whole session snapshot undecodable.
    @Test func malformedPresentationKeepsTheMessageAndItsDaemonText() throws {
        let json = """
        {"id":"m-bad","kind":"agent_error","createdAt":"2026-05-05T00:00:00.000Z","errorMessage":"Bash failed: exit 1","presentation":{"code":42,"params":{"detail":7}}}
        """
        let message = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionMessage.self, from: Data(json.utf8))

        #expect(message.errorMessage == "Bash failed: exit 1")
        #expect(message.presentation?.code == nil)
        #expect(message.localizedPresentationText == nil)
    }

    @Test func unknownPresentationCodeFallsBackToTheDaemonText() throws {
        let json = """
        {"id":"m-future","kind":"system","createdAt":"2026-05-05T00:00:00.000Z","text":"Something new happened","presentation":{"code":"somethingPickyDoesNotKnowYet"}}
        """
        let message = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionMessage.self, from: Data(json.utf8))

        #expect(message.presentation?.code == nil)
        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyAgentBubbleView(message: message).displayedMarkdown == "Something new happened")
        }
    }

    // The shell's own message is external text: it is quoted verbatim inside Picky's sentence.
    @Test func errorBubbleLocalizesPickysWordingAroundTheVerbatimShellDetail() {
        let bashFailure = PickySessionMessage(
            id: "m-bash",
            kind: .agentError,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: nil,
            text: nil,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: "Bash failed: command not found: nope",
            presentation: PickyMessagePresentation(
                code: .userBashFailed,
                params: PickyMessagePresentationParams(detail: "command not found: nope")
            )
        )

        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyErrorBubbleView(message: bashFailure).displayedErrorMessage == "Bash 실행에 실패했어요: command not found: nope")
        }
        LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            #expect(PickyErrorBubbleView(message: bashFailure).displayedErrorMessage == "Bash failed: command not found: nope")
        }
    }

    // A runtime failure summary is the agent's wording and must not be translated away, while
    // the daemon's no-detail fallback is Picky's own sentence.
    @Test func errorBubbleKeepsRuntimeSummariesVerbatim() {
        let runtimeFailure = errorMessage("Agent is already processing a prompt.", presentation: nil)
        let pickyFallback = errorMessage("Agent failed", presentation: PickyMessagePresentation(code: .agentFailedWithoutDetail))

        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyErrorBubbleView(message: runtimeFailure).displayedErrorMessage == "Agent is already processing a prompt.")
            #expect(PickyErrorBubbleView(message: pickyFallback).displayedErrorMessage == "작업이 실패했어요")
        }
    }

    @Test func compactionCodesClassifyTheBubbleWithoutMatchingEnglishText() {
        let compacted = systemMessage(text: "Session compacted", presentation: PickyMessagePresentation(code: .sessionCompacted))
        let overflow = systemMessage(text: "Session compacted after context overflow", presentation: PickyMessagePresentation(code: .sessionCompactedAfterOverflow))
        let failed = systemMessage(
            text: "Auto-compaction failed\n\nSummarization failed.\n\nContext was not reduced.",
            presentation: PickyMessagePresentation(code: .sessionCompactionFailed, params: PickyMessagePresentationParams(detail: "Summarization failed."))
        )

        #expect(compacted.isCompactCompletionMessage)
        #expect(overflow.isCompactCompletionMessage)
        #expect(failed.isCompactFailureMessage)
        #expect(!failed.isCompactCompletionMessage)
        #expect(PickyConversationBubbleKind(message: compacted) == .compactCompletion)
        #expect(PickyConversationBubbleKind(message: failed) == .compactFailure)
    }

    @Test func compactionFailureDetailLocalizesTheOutcomeAroundTheSummarizerMessage() {
        let failure = systemMessage(
            text: "Auto-compaction failed\n\nSummarization request timed out.\n\nContext was not reduced. Current usage remains 190,000/200,000 tokens.",
            presentation: PickyMessagePresentation(
                code: .sessionCompactionFailed,
                params: PickyMessagePresentationParams(detail: "Summarization request timed out.", contextTokens: 190_000, contextWindowTokens: 200_000)
            )
        )

        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            let detail = failure.compactFailureDetailText
            #expect(detail?.hasPrefix("Summarization request timed out.") == true)
            #expect(detail?.contains("대화 내용은 줄어들지 않았어요.") == true)
            #expect(detail?.contains("190,000/200,000") == true)
            #expect(detail?.contains("Context was not reduced") == false)
        }
    }

    // Journals from before typed parameters existed carry only the English paragraph, so the
    // bubble still has to strip the title line it draws itself.
    @Test func legacyCompactionFailureTextStillSplitsTitleFromDetail() {
        let legacy = systemMessage(text: "Auto-compaction failed\n\nSummarization failed.", presentation: nil)

        #expect(legacy.isCompactFailureMessage)
        #expect(legacy.compactFailureDetailText == "Summarization failed.")
    }

    private func systemMessage(text: String, presentation: PickyMessagePresentation?) -> PickySessionMessage {
        PickySessionMessage(
            id: "m-system",
            kind: .system,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: nil,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: nil,
            presentation: presentation
        )
    }

    private func errorMessage(_ errorMessage: String, presentation: PickyMessagePresentation?) -> PickySessionMessage {
        PickySessionMessage(
            id: "m-error",
            kind: .agentError,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: nil,
            text: nil,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: errorMessage,
            presentation: presentation
        )
    }
}

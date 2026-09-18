import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyToolHistoryDetailModelTests {
    @Test func displaysStoredTextBeyondPreviewAndReplacesPages() async {
        let first = String(repeating: "x", count: 700) + "original tail"
        let model = PickyToolHistoryDetailModel(toolName: "read") { part, cursor in
            Self.response(part: part, text: cursor == nil ? first : "second page", nextCursor: cursor == nil ? "page-2" : nil)
        }
        await model.load(part: .result).value
        #expect(model.text == first)
        #expect(model.pageNumber == 1)
        #expect(model.canLoadNextPage)
        await model.loadNextPage()?.value
        #expect(model.text == "second page")
        #expect(model.pageNumber == 2)
        #expect(!model.canLoadNextPage)
    }

    @Test func inlineHistoryLoadsEveryPageWithoutReplacingEarlierContent() async throws {
        let tool = PickyToolActivity(toolCallId: "tool", name: "read", status: "succeeded")
        let snapshot = PickyToolHistorySnapshot(tools: [tool], sessionFilePath: "/tmp/session.jsonl")
        let history = PickyToolHistoryViewerModel(title: "History", snapshot: snapshot, scope: .session,
            refresh: { snapshot }) { id, file, part, cursor in
                #expect(id == "tool")
                #expect(file == "/tmp/session.jsonl")
                return Self.response(part: part, text: cursor == nil ? String(repeating: "x", count: 32_768) : "TAIL",
                                     nextCursor: cursor == nil ? "next" : nil)
            }
        let model = try #require(history.inlineDetail(toolCallID: "tool"))
        await model.load(part: .result).value
        #expect(model.state == .ready)
        #expect(model.text == String(repeating: "x", count: 32_768) + "TAIL")
        #expect(!model.canLoadNextPage)
        model.cancel()
        #expect(model.text.isEmpty)
    }

    @Test func inlineRetryDiscardsIncompleteContentAndRestartsFromFirstPage() async {
        var expired = true
        let model = PickyToolHistoryDetailModel(toolName: "read", loadsAllPages: true) { _, cursor in
            if cursor == nil { return Self.response(text: "first", nextCursor: "next") }
            return expired ? Self.response(status: .unavailable) : Self.response(text: "last")
        }
        await model.load(part: .result).value
        #expect(model.state == .unavailable)
        #expect(model.text.isEmpty)
        expired = false
        await model.retry().value
        #expect(model.text == "firstlast")
        #expect(model.state == .ready)
    }

    @Test func formattedWriteUsesFullInputWhileResultAndArgumentsRemainIndependent() async throws {
        let content = String(repeating: "saved line\n", count: 4_000) + "TAIL"
        let argsData = try JSONSerialization.data(withJSONObject: ["path": "docs/result.md", "content": content])
        let args = String(decoding: argsData, as: UTF8.self)
        let tool = PickyToolActivity(toolCallId: "write-1", name: "write", status: "succeeded", argsPreview: #"{"path":"docs/result.md","content":"cut"}"#)
        let snapshot = PickyToolHistorySnapshot(tools: [tool], sessionFilePath: "/tmp/history.jsonl")
        let history = PickyToolHistoryViewerModel(title: "History", snapshot: snapshot, scope: .session, refresh: { snapshot }) { _, _, part, cursor in
            if part == .result { return Self.response(text: "Saved") }
            return Self.response(part: .arguments,
                text: cursor == nil ? String(args.prefix(32_768)) : String(args.dropFirst(32_768)),
                nextCursor: cursor == nil ? "rest" : nil)
        }
        let result = try #require(history.inlineDetail(toolCallID: tool.id))
        let arguments = try #require(history.inlineArguments(toolCallID: tool.id))
        await result.load(part: .result).value
        await arguments.load(part: .arguments).value
        let entry = try #require(history.entries.first)
        let presentation = PickyToolHistoryPresentation.detail(for: entry, arguments: arguments.text, structuredResult: result.structuredResult)
        guard case let .write(path, savedContent) = presentation else {
            Issue.record("Expected full saved file content")
            return
        }
        #expect(path == "docs/result.md")
        #expect(savedContent == content)
        #expect(result.text == "Saved")
        history.update(title: "Changed", snapshot: .init(tools: [], sessionFilePath: "/tmp/other.jsonl"))
        #expect(result.state == .sourceChanged)
        #expect(arguments.state == .sourceChanged)
        #expect(result.text.isEmpty && arguments.text.isEmpty)
    }

    @Test func fullResultRetainsStructuredFirstPageUntilCancelled() async {
        let saved = #"{"value":{"q1":["one,two","three"]},"cancelled":false}"#
        let model = PickyToolHistoryDetailModel(toolName: "ask_user_question", loadsAllPages: true) { _, cursor in
            var response = Self.response(text: cursor == nil ? "first" : "last", nextCursor: cursor == nil ? "next" : nil)
            response.structuredResult = cursor == nil ? saved : nil
            return response
        }
        await model.load(part: .result).value
        #expect(model.text == "firstlast")
        #expect(model.structuredResult == saved)
        model.cancel()
        #expect(model.structuredResult == nil)
    }

    @Test func retriesPendingPersistenceAndThenShowsOriginal() async {
        var responses = [Self.response(status: .pending), Self.response(text: "persisted result")]
        let model = PickyToolHistoryDetailModel(toolName: "bash", retryDelay: {}) { _, _ in
            responses.removeFirst()
        }
        await model.load(part: .result).value
        #expect(model.text == "persisted result")
        #expect(model.state == .ready)
    }

    @Test func pendingRetriesAreBoundedAndRemainVisible() async {
        var requests = 0
        let model = PickyToolHistoryDetailModel(toolName: "bash", retryDelay: {}) { _, _ in
            requests += 1
            return Self.response(status: .pending)
        }
        await model.load(part: .result).value
        #expect(requests == 3)
        #expect(model.state == .pending)
        #expect(model.text.isEmpty)
    }

    @Test func closingDiscardsLateResultEvenWhenLoaderIgnoresCancellation() async {
        var continuation: CheckedContinuation<PickyToolHistoryDetailResult, Never>?
        let model = PickyToolHistoryDetailModel(toolName: "read") { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let task = model.load(part: .result)
        while continuation == nil { await Task.yield() }
        model.cancel()
        continuation?.resume(returning: Self.response(text: "stale result"))
        await task.value
        #expect(model.text.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func retryAfterAnExpiredCursorRestartsAtFirstPage() async {
        let model = PickyToolHistoryDetailModel(toolName: "read") { _, cursor in
            cursor == nil
                ? Self.response(text: "first page", nextCursor: "expired-cursor")
                : Self.response(status: .unavailable)
        }
        await model.load(part: .result).value
        await model.loadNextPage()?.value
        #expect(model.state == .unavailable)
        await model.retry().value
        #expect(model.state == .ready)
        #expect(model.pageNumber == 1)
        #expect(model.text == "first page")
    }

    @Test func sourceChangeClearsPreviouslyDisplayedPage() async {
        var responses = [Self.response(text: "old source", nextCursor: "next"), Self.response(status: .sourceChanged)]
        let model = PickyToolHistoryDetailModel(toolName: "read") { _, _ in responses.removeFirst() }
        await model.load(part: .result).value
        await model.loadNextPage()?.value
        #expect(model.state == .sourceChanged)
        #expect(model.text.isEmpty)
        #expect(!model.canLoadNextPage)
    }

    @Test func transportFailureAndUnsupportedSourceAreVisible() async {
        let failed = PickyToolHistoryDetailModel(toolName: "read") { _, _ in throw URLError(.notConnectedToInternet) }
        await failed.load(part: .result).value
        #expect(failed.state == .failed)
        let unsupported = PickyToolHistoryDetailModel(toolName: "bash") { _, _ in Self.response(status: .unsupported) }
        await unsupported.load(part: .result).value
        #expect(unsupported.state == .unsupported)
    }

    private static func response(
        part: PickyToolHistoryDetailPart = .result,
        status: PickyToolHistoryDetailStatus = .ready,
        text: String? = nil,
        nextCursor: String? = nil
    ) -> PickyToolHistoryDetailResult {
        PickyToolHistoryDetailResult(
            sessionId: "session", requestId: "request", toolCallId: "tool",
            expectedSessionFile: "/tmp/session.jsonl", part: part, status: status,
            text: text, nextCursor: nextCursor, reason: nil, attachmentsOmitted: nil
        )
    }
}

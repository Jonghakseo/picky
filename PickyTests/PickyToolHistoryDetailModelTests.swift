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

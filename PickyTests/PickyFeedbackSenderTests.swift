//
//  PickyFeedbackSenderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
private final class StubTransport: PickyFeedbackTransport {
    struct SentCall {
        var request: URLRequest
    }

    struct UploadCall {
        var data: Data
        var url: URL
    }

    var sentCalls: [SentCall] = []
    var uploadCalls: [UploadCall] = []

    /// Responses are popped in FIFO order so tests can script multi-step flows.
    var responses: [Result<(Data, HTTPURLResponse), Error>] = []
    var uploadResponses: [Result<(Data, HTTPURLResponse), Error>] = []

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sentCalls.append(SentCall(request: request))
        guard !responses.isEmpty else {
            return makeJSON(["ok": true])
        }
        return try responses.removeFirst().get()
    }

    func upload(data: Data, to url: URL) async throws -> (Data, HTTPURLResponse) {
        uploadCalls.append(UploadCall(data: data, url: url))
        guard !uploadResponses.isEmpty else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        return try uploadResponses.removeFirst().get()
    }

    func makeJSON(_ object: [String: Any], status: Int = 200) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let url = URL(string: "https://slack.com/api/test")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

@MainActor
@Suite
struct PickyFeedbackSenderTests {
    private func makePayload(
        category: PickyFeedbackCategory = .bug,
        message: String = "Pickle won't start."
    ) -> PickyFeedbackPayload {
        PickyFeedbackPayload(
            category: category,
            message: message,
            appVersion: "0.3.2",
            appBuild: "412",
            osVersion: "15.1.0",
            sentAt: Date(timeIntervalSince1970: 1_715_500_000)
        )
    }

    private func makeSender(transport: StubTransport) -> PickyFeedbackSender {
        PickyFeedbackSender(botToken: "xoxb-test", channelID: "C12345", transport: transport)
    }

    @Test func plainMessageGoesToChatPostMessage() async throws {
        let transport = StubTransport()
        let sender = makeSender(transport: transport)

        try await sender.send(makePayload(message: "It crashed."), attachment: nil)

        #expect(transport.sentCalls.count == 1)
        let call = transport.sentCalls[0]
        #expect(call.request.url?.absoluteString == "https://slack.com/api/chat.postMessage")
        #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer xoxb-test")

        let body = try #require(call.request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["channel"] as? String == "C12345")
        let text = try #require(json["text"] as? String)
        #expect(text.contains("🐞 *Bug*"))
        #expect(text.contains("It crashed."))
        #expect(text.contains("macOS:* 15.1.0"))
        #expect(!text.contains("Session"))
    }

    @Test func attachmentTriggersThreeStepFlow() async throws {
        let transport = StubTransport()
        transport.responses = [
            .success(transport.makeJSON([
                "ok": true,
                "upload_url": "https://files.slack.com/upload/abc",
                "file_id": "F0FILE"
            ])),
            .success(transport.makeJSON(["ok": true]))
        ]
        let sender = makeSender(transport: transport)
        let attachment = PickyFeedbackAttachment(filename: "diag.zip", data: Data(repeating: 0x42, count: 1024))

        try await sender.send(makePayload(), attachment: attachment)

        #expect(transport.sentCalls.count == 2)
        #expect(transport.sentCalls[0].request.url?.absoluteString == "https://slack.com/api/files.getUploadURLExternal")
        #expect(transport.sentCalls[1].request.url?.absoluteString == "https://slack.com/api/files.completeUploadExternal")

        // Form-encoded payload for getUploadURLExternal.
        let firstBody = try #require(transport.sentCalls[0].request.httpBody)
        let firstString = String(data: firstBody, encoding: .utf8) ?? ""
        #expect(firstString.contains("filename=diag.zip"))
        #expect(firstString.contains("length=1024"))

        // Upload step received the bytes at the right URL.
        #expect(transport.uploadCalls.count == 1)
        #expect(transport.uploadCalls[0].url.absoluteString == "https://files.slack.com/upload/abc")
        #expect(transport.uploadCalls[0].data.count == 1024)

        // Complete step references the uploaded file_id and includes the
        // formatted message as initial_comment.
        let completeBody = try #require(transport.sentCalls[1].request.httpBody)
        let completeJSON = try #require(JSONSerialization.jsonObject(with: completeBody) as? [String: Any])
        #expect(completeJSON["channel_id"] as? String == "C12345")
        let files = try #require(completeJSON["files"] as? [[String: String]])
        #expect(files.first?["id"] == "F0FILE")
        let initialComment = try #require(completeJSON["initial_comment"] as? String)
        #expect(initialComment.contains("Diagnostics:* diag.zip"))
    }

    @Test func multipleAttachmentsAreCompletedTogether() async throws {
        let transport = StubTransport()
        transport.responses = [
            .success(transport.makeJSON([
                "ok": true,
                "upload_url": "https://files.slack.com/upload/diag",
                "file_id": "F-DIAG"
            ])),
            .success(transport.makeJSON([
                "ok": true,
                "upload_url": "https://files.slack.com/upload/media",
                "file_id": "F-MEDIA"
            ])),
            .success(transport.makeJSON(["ok": true]))
        ]
        let sender = makeSender(transport: transport)
        let mediaData = Data([0x89, 0x50, 0x4E, 0x47])
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try mediaData.write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let diagnostics = PickyFeedbackAttachment(filename: "diag.zip", data: Data(repeating: 0x42, count: 1024), kind: .diagnostics)
        let media = PickyFeedbackAttachment(filename: "screen.png", fileURL: mediaURL, byteCount: mediaData.count, kind: .media)

        try await sender.send(makePayload(), attachments: [diagnostics, media])

        #expect(transport.sentCalls.count == 3)
        #expect(transport.sentCalls[0].request.url?.absoluteString == "https://slack.com/api/files.getUploadURLExternal")
        #expect(transport.sentCalls[1].request.url?.absoluteString == "https://slack.com/api/files.getUploadURLExternal")
        #expect(transport.sentCalls[2].request.url?.absoluteString == "https://slack.com/api/files.completeUploadExternal")

        #expect(transport.uploadCalls.count == 2)
        #expect(transport.uploadCalls[0].url.absoluteString == "https://files.slack.com/upload/diag")
        #expect(transport.uploadCalls[0].data.count == 1024)
        #expect(transport.uploadCalls[1].url.absoluteString == "https://files.slack.com/upload/media")
        #expect(transport.uploadCalls[1].data == mediaData)

        let completeBody = try #require(transport.sentCalls[2].request.httpBody)
        let completeJSON = try #require(JSONSerialization.jsonObject(with: completeBody) as? [String: Any])
        let files = try #require(completeJSON["files"] as? [[String: String]])
        #expect(files == [
            ["id": "F-DIAG", "title": "diag.zip"],
            ["id": "F-MEDIA", "title": "screen.png"]
        ])
        let initialComment = try #require(completeJSON["initial_comment"] as? String)
        #expect(initialComment.contains("Diagnostics:* diag.zip"))
        #expect(initialComment.contains("Files:* screen.png"))
    }

    @Test func emptyMessageThrowsEmptyMessage() async {
        let sender = makeSender(transport: StubTransport())
        await #expect(throws: PickyFeedbackSendError.emptyMessage) {
            try await sender.send(self.makePayload(message: "   \n   "), attachment: nil)
        }
    }

    @Test func missingTokenOrChannelThrowsNotConfigured() async {
        let sender = PickyFeedbackSender(botToken: "", channelID: "C12345", transport: StubTransport())
        await #expect(throws: PickyFeedbackSendError.notConfigured) {
            try await sender.send(self.makePayload(), attachment: nil)
        }
    }

    @Test func slackOkFalseSurfacesAsSlackError() async {
        let transport = StubTransport()
        transport.responses = [
            .success(transport.makeJSON(["ok": false, "error": "channel_not_found"]))
        ]
        let sender = makeSender(transport: transport)
        await #expect(throws: PickyFeedbackSendError.slackError("channel_not_found")) {
            try await sender.send(self.makePayload(), attachment: nil)
        }
    }

    @Test func non200StatusMapsToHTTPError() async {
        let transport = StubTransport()
        transport.responses = [
            .success(transport.makeJSON(["ok": true], status: 502))
        ]
        let sender = makeSender(transport: transport)
        await #expect(throws: PickyFeedbackSendError.httpStatus(502, "chat.postMessage")) {
            try await sender.send(self.makePayload(), attachment: nil)
        }
    }
}

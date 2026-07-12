//
//  PickyFeedbackSender.swift
//  Picky
//
//  Sends feedback to Slack using a Bot User OAuth token.
//
//  Two paths:
//    • No attachment → chat.postMessage with mrkdwn `text`.
//    • With attachment(s) → files.getUploadURLExternal → POST file bytes →
//      files.completeUploadExternal with `initial_comment` so the message and
//      files land together in the destination channel.
//
//  The transport is injectable so unit tests can replay each step without
//  hitting the network. Errors are mapped to PickyFeedbackSendError so the
//  UI can surface human-readable reasons.
//

import Foundation

enum PickyFeedbackCategory: String, CaseIterable, Identifiable, Sendable {
    case bug
    case idea
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bug: "Bug"
        case .idea: "Idea"
        case .other: "Other"
        }
    }

    var emoji: String {
        switch self {
        case .bug: "🐞"
        case .idea: "💡"
        case .other: "💬"
        }
    }
}

struct PickyFeedbackPayload: Equatable, Sendable {
    var category: PickyFeedbackCategory
    var message: String
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var sentAt: Date
}

enum PickyFeedbackAttachmentKind: Equatable, Sendable {
    case diagnostics
    case media
}

struct PickyFeedbackAttachment: Sendable {
    enum Storage: Sendable {
        case data(Data)
        case file(URL, byteCount: Int)
    }

    var filename: String
    var kind: PickyFeedbackAttachmentKind
    private let storage: Storage

    var byteCount: Int {
        switch storage {
        case .data(let data): data.count
        case .file(_, let byteCount): byteCount
        }
    }

    init(filename: String, data: Data, kind: PickyFeedbackAttachmentKind = .diagnostics) {
        self.filename = filename
        self.kind = kind
        self.storage = .data(data)
    }

    init(filename: String, fileURL: URL, byteCount: Int, kind: PickyFeedbackAttachmentKind = .media) {
        self.filename = filename
        self.kind = kind
        self.storage = .file(fileURL, byteCount: byteCount)
    }

    func loadData() throws -> Data {
        switch storage {
        case .data(let data):
            return data
        case .file(let url, _):
            return try Data(contentsOf: url)
        }
    }
}

enum PickyFeedbackSendError: Error, Equatable {
    case notConfigured
    case emptyMessage
    case transport(String)
    case httpStatus(Int, String)
    case slackError(String)
}

protocol PickyFeedbackTransport {
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(data: Data, to url: URL) async throws -> (Data, HTTPURLResponse)
}

struct PickyURLSessionFeedbackTransport: PickyFeedbackTransport {
    var session: URLSession = .shared

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PickyFeedbackSendError.transport("Non-HTTP response")
        }
        return (data, http)
    }

    func upload(data: Data, to url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw PickyFeedbackSendError.transport("Non-HTTP response")
        }
        return (responseData, http)
    }
}

struct PickyFeedbackSender {
    var botToken: String
    var channelID: String
    var transport: PickyFeedbackTransport

    init(
        botToken: String = PickyFeedbackConfiguration.botToken,
        channelID: String = PickyFeedbackConfiguration.channelID,
        transport: PickyFeedbackTransport = PickyURLSessionFeedbackTransport()
    ) {
        self.botToken = botToken
        self.channelID = channelID
        self.transport = transport
    }

    func send(_ payload: PickyFeedbackPayload, attachment: PickyFeedbackAttachment? = nil) async throws {
        try await send(payload, attachments: attachment.map { [$0] } ?? [])
    }

    func send(_ payload: PickyFeedbackPayload, attachments: [PickyFeedbackAttachment]) async throws {
        let trimmedMessage = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw PickyFeedbackSendError.emptyMessage }
        guard !botToken.isEmpty, !channelID.isEmpty else {
            throw PickyFeedbackSendError.notConfigured
        }

        let messageText = Self.renderSlackText(
            payload: payload,
            message: trimmedMessage,
            attachments: attachments
        )

        if attachments.isEmpty {
            try await postPlainMessage(messageText: messageText)
        } else {
            try await sendWithAttachments(messageText: messageText, attachments: attachments)
        }
    }

    private func postPlainMessage(messageText: String) async throws {
        var request = slackJSONRequest(path: "chat.postMessage")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "channel": channelID,
            "text": messageText,
            "mrkdwn": true
        ])
        _ = try await runSlackJSON(request: request)
    }

    private func sendWithAttachments(messageText: String, attachments: [PickyFeedbackAttachment]) async throws {
        var files: [[String: String]] = []

        for attachment in attachments {
            let data: Data
            do {
                data = try attachment.loadData()
            } catch {
                throw PickyFeedbackSendError.transport("Couldn't read \(attachment.filename): \(error.localizedDescription)")
            }

            // 1. Request an upload URL for each file.
            var getURLRequest = slackFormRequest(path: "files.getUploadURLExternal")
            getURLRequest.httpBody = Self.formURLEncoded([
                "filename": attachment.filename,
                "length": String(data.count)
            ])
            let getURLResponse = try await runSlackJSON(request: getURLRequest)
            guard let uploadURLString = getURLResponse["upload_url"] as? String,
                  let uploadURL = URL(string: uploadURLString),
                  let fileID = getURLResponse["file_id"] as? String else {
                throw PickyFeedbackSendError.slackError("Missing upload_url/file_id in Slack response")
            }

            // 2. POST the bytes to the returned upload URL. Slack returns 200 with a small body.
            let (_, uploadResponse) = try await transport.upload(data: data, to: uploadURL)
            guard (200..<300).contains(uploadResponse.statusCode) else {
                throw PickyFeedbackSendError.httpStatus(uploadResponse.statusCode, "upload")
            }

            files.append(["id": fileID, "title": attachment.filename])
        }

        // 3. Finalize the uploads, publish to the channel with the message as initial_comment.
        var completeRequest = slackJSONRequest(path: "files.completeUploadExternal")
        completeRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "files": files,
            "channel_id": channelID,
            "initial_comment": messageText
        ])
        _ = try await runSlackJSON(request: completeRequest)
    }

    private func slackJSONRequest(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func slackFormRequest(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://slack.com/api/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Runs a Slack Web API call and returns the decoded JSON object. Throws
    /// when HTTP status is non-2xx, when JSON parsing fails, or when Slack's
    /// own envelope returns `ok: false`.
    private func runSlackJSON(request: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request: request)
        } catch let error as PickyFeedbackSendError {
            throw error
        } catch {
            throw PickyFeedbackSendError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw PickyFeedbackSendError.httpStatus(response.statusCode, request.url?.lastPathComponent ?? "?")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PickyFeedbackSendError.slackError("Malformed Slack response")
        }
        if let ok = object["ok"] as? Bool, !ok {
            let errorCode = object["error"] as? String ?? "unknown_error"
            throw PickyFeedbackSendError.slackError(errorCode)
        }
        return object
    }

    static func formURLEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed
        let pairs = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    static func renderSlackText(
        payload: PickyFeedbackPayload,
        message: String,
        attachmentFilename: String?
    ) -> String {
        let attachments = attachmentFilename.map {
            [PickyFeedbackAttachment(filename: $0, data: Data(), kind: .diagnostics)]
        } ?? []
        return renderSlackText(payload: payload, message: message, attachments: attachments)
    }

    static func renderSlackText(
        payload: PickyFeedbackPayload,
        message: String,
        attachments: [PickyFeedbackAttachment]
    ) -> String {
        var lines: [String] = []
        lines.append("\(payload.category.emoji) *\(payload.category.displayName)* · Picky \(payload.appVersion) (build \(payload.appBuild))")
        lines.append("")
        lines.append(message)
        lines.append("")
        lines.append("────────────────────────")
        lines.append("• *macOS:* \(payload.osVersion)")
        lines.append("• *Sent:* \(timestampFormatter.string(from: payload.sentAt))")

        let diagnostics = attachmentFilenames(for: attachments, kind: .diagnostics)
        if !diagnostics.isEmpty {
            lines.append("• *Diagnostics:* \(diagnostics)")
        }
        let files = attachmentFilenames(for: attachments, kind: .media)
        if !files.isEmpty {
            lines.append("• *Files:* \(files)")
        }
        return lines.joined(separator: "\n")
    }

    private static func attachmentFilenames(for attachments: [PickyFeedbackAttachment], kind: PickyFeedbackAttachmentKind) -> String {
        attachments
            .filter { $0.kind == kind }
            .map(\.filename)
            .joined(separator: ", ")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter
    }()
}

//
//  PickyDiffReviewWebHost.swift
//  Picky
//

import Foundation
import WebKit

@MainActor
final class PickyDiffReviewWebHost: NSObject, WKScriptMessageHandler {
    typealias MessageHandler = (PickyDiffReviewWebHostMessage) -> Void

    let webView: WKWebView

    private let onMessage: MessageHandler
    private let onClose: () -> Void

    init(onMessage: @escaping MessageHandler, onClose: @escaping () -> Void) {
        self.onMessage = onMessage
        self.onClose = onClose

        let userContentController = WKUserContentController()
        let bridgeScript = """
        window.glimpse = {
          send(payload) { window.webkit.messageHandlers.glimpse.postMessage(payload); },
          close() { window.webkit.messageHandlers.glimpse.postMessage({ type: "__close__" }); }
        };
        """
        userContentController.addUserScript(WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        userContentController.add(self, name: "glimpse")
    }

    func loadInitialPage() {
        guard let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "DiffReview"),
              let resourceURL = Bundle.main.resourceURL else { return }
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceURL)
    }

    func send(_ message: ReviewHostMessage) {
        guard let data = try? JSONEncoder.diffReview.encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        let escaped = json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        webView.evaluateJavaScript("window.__reviewReceive(\(escaped));")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "glimpse",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "__close__" {
            onClose()
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let decoder = JSONDecoder.diffReview

        switch type {
        case "request-review-data":
            guard let payload = try? decoder.decode(RequestReviewDataPayload.self, from: data) else { return }
            onMessage(.requestReviewData(requestId: payload.requestId))
        case "request-commit":
            guard let payload = try? decoder.decode(RequestCommitPayload.self, from: data) else { return }
            onMessage(.requestCommit(requestId: payload.requestId, sha: payload.sha))
        case "request-file":
            guard let payload = try? decoder.decode(RequestFilePayload.self, from: data) else { return }
            onMessage(.requestFile(requestId: payload.requestId, fileId: payload.fileId, scope: payload.scope, commitSha: payload.commitSha))
        case "clipboard-read":
            guard let payload = try? decoder.decode(ClipboardReadPayload.self, from: data) else { return }
            onMessage(.clipboardRead(requestId: payload.requestId))
        case "clipboard-write":
            guard let payload = try? decoder.decode(ClipboardWritePayload.self, from: data) else { return }
            onMessage(.clipboardWrite(text: payload.text))
        case "submit":
            guard let payload = try? decoder.decode(PickyDiffReviewPrompt.SubmitPayload.self, from: data) else { return }
            onMessage(.submit(payload: payload))
        case "cancel":
            onMessage(.cancel)
        default:
            return
        }
    }
}

enum PickyDiffReviewWebHostMessage {
    case requestReviewData(requestId: String)
    case requestCommit(requestId: String, sha: String)
    case requestFile(requestId: String, fileId: String, scope: ReviewScope, commitSha: String?)
    case clipboardRead(requestId: String)
    case clipboardWrite(text: String)
    case submit(payload: PickyDiffReviewPrompt.SubmitPayload)
    case cancel
    case close
}

enum ReviewHostMessage: Encodable {
    case reviewData(requestId: String, files: [ReviewFile], commits: [ReviewCommitInfo], branchBaseRef: String?, branchMergeBaseSha: String?, repositoryHasHead: Bool)
    case reviewDataError(requestId: String, message: String)
    case commitData(requestId: String, sha: String, files: [ReviewFile])
    case commitError(requestId: String, sha: String, message: String)
    case fileData(requestId: String, fileId: String, scope: ReviewScope, commitSha: String?, contents: ReviewFileContents)
    case fileError(requestId: String, fileId: String, scope: ReviewScope, commitSha: String?, message: String)
    case clipboardData(requestId: String, text: String, message: String?)
    case workingTreeChanged(changedAt: Int64)

    private enum CodingKeys: String, CodingKey {
        case type
        case requestId
        case files
        case commits
        case branchBaseRef
        case branchMergeBaseSha
        case repositoryHasHead
        case message
        case sha
        case fileId
        case scope
        case commitSha
        case originalContent
        case modifiedContent
        case kind
        case mimeType
        case originalExists
        case modifiedExists
        case originalPreviewUrl
        case modifiedPreviewUrl
        case text
        case changedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reviewData(let requestId, let files, let commits, let branchBaseRef, let branchMergeBaseSha, let repositoryHasHead):
            try container.encode("review-data", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(files, forKey: .files)
            try container.encode(commits, forKey: .commits)
            try container.encode(branchBaseRef, forKey: .branchBaseRef)
            try container.encode(branchMergeBaseSha, forKey: .branchMergeBaseSha)
            try container.encode(repositoryHasHead, forKey: .repositoryHasHead)
        case .reviewDataError(let requestId, let message):
            try container.encode("review-data-error", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(message, forKey: .message)
        case .commitData(let requestId, let sha, let files):
            try container.encode("commit-data", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(sha, forKey: .sha)
            try container.encode(files, forKey: .files)
        case .commitError(let requestId, let sha, let message):
            try container.encode("commit-error", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(sha, forKey: .sha)
            try container.encode(message, forKey: .message)
        case .fileData(let requestId, let fileId, let scope, let commitSha, let contents):
            try container.encode("file-data", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(fileId, forKey: .fileId)
            try container.encode(scope, forKey: .scope)
            try container.encode(commitSha, forKey: .commitSha)
            try container.encode(contents.originalContent, forKey: .originalContent)
            try container.encode(contents.modifiedContent, forKey: .modifiedContent)
            try container.encode(contents.kind, forKey: .kind)
            try container.encode(contents.mimeType, forKey: .mimeType)
            try container.encode(contents.originalExists, forKey: .originalExists)
            try container.encode(contents.modifiedExists, forKey: .modifiedExists)
            try container.encode(contents.originalPreviewUrl, forKey: .originalPreviewUrl)
            try container.encode(contents.modifiedPreviewUrl, forKey: .modifiedPreviewUrl)
        case .fileError(let requestId, let fileId, let scope, let commitSha, let message):
            try container.encode("file-error", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(fileId, forKey: .fileId)
            try container.encode(scope, forKey: .scope)
            try container.encode(commitSha, forKey: .commitSha)
            try container.encode(message, forKey: .message)
        case .clipboardData(let requestId, let text, let message):
            try container.encode("clipboard-data", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(text, forKey: .text)
            if let message {
                try container.encode(message, forKey: .message)
            }
        case .workingTreeChanged(let changedAt):
            try container.encode("working-tree-changed", forKey: .type)
            try container.encode(changedAt, forKey: .changedAt)
        }
    }
}

private struct RequestReviewDataPayload: Decodable {
    let requestId: String
}

private struct RequestCommitPayload: Decodable {
    let requestId: String
    let sha: String
}

private struct RequestFilePayload: Decodable {
    let requestId: String
    let fileId: String
    let scope: ReviewScope
    let commitSha: String?
}

private struct ClipboardReadPayload: Decodable {
    let requestId: String
}

private struct ClipboardWritePayload: Decodable {
    let text: String
}

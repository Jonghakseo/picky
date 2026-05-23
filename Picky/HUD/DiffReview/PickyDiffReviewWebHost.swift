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

    private let schemeHandler = PickyDiffReviewURLSchemeHandler()
    private var onMessage: MessageHandler
    private var onClose: () -> Void

    // Warmup support: when true, messages received from the JS side (including
    // close) are queued instead of being delivered to onMessage/onClose. The
    // presenter calls `attachLiveHandlers` once it adopts a warmed-up host,
    // which swaps in the real handlers and flushes the queue.
    private var queueIncomingMessages: Bool
    private var pendingMessages: [PickyDiffReviewWebHostMessage] = []
    private var pendingClose = false

    init(
        queueIncomingMessages: Bool = false,
        onMessage: @escaping MessageHandler,
        onClose: @escaping () -> Void
    ) {
        self.onMessage = onMessage
        self.onClose = onClose
        self.queueIncomingMessages = queueIncomingMessages

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
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PickyDiffReviewURLSchemeHandler.scheme)

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }
        #endif

        super.init()

        userContentController.add(self, name: "glimpse")
    }

    /// Swap in the live message/close handlers for a host that was created in
    /// warmup mode, then drain any queued messages so the presenter can react
    /// to whatever JS sent during preload (typically the initial
    /// `request-review-data`).
    func attachLiveHandlers(onMessage: @escaping MessageHandler, onClose: @escaping () -> Void) {
        self.onMessage = onMessage
        self.onClose = onClose
        queueIncomingMessages = false
        let queued = pendingMessages
        pendingMessages.removeAll()
        for message in queued {
            onMessage(message)
        }
        if pendingClose {
            pendingClose = false
            onClose()
        }
    }

    private func dispatch(_ message: PickyDiffReviewWebHostMessage) {
        if queueIncomingMessages {
            pendingMessages.append(message)
        } else {
            onMessage(message)
        }
    }

    private func dispatchClose() {
        if queueIncomingMessages {
            pendingClose = true
        } else {
            onClose()
        }
    }

    /// Loads the review page. Pass `nil` for `initialData` to render the page
    /// before git data is ready; the JS layer will pull data via
    /// `request-review-data` once it observes the `{"loading":true}` sentinel.
    func loadInitialPage(initialData: ReviewWindowData?) throws {
        guard let resourceURL = Bundle.main.url(forResource: "DiffReview", withExtension: nil) else {
            throw PickyDiffReviewWebHostError.missingResourceDirectory
        }
        let template = try String(contentsOf: resourceURL.appendingPathComponent("index.html"), encoding: .utf8)
        let appJs = try String(contentsOf: resourceURL.appendingPathComponent("app.js"), encoding: .utf8)
        schemeHandler.configure(resourceRoot: resourceURL, renderedHTML: try Self.renderHTML(template: template, appJs: appJs, initialData: initialData))
        webView.load(URLRequest(url: PickyDiffReviewURLSchemeHandler.indexURL))
    }

    nonisolated static func renderHTML(template: String, appJs: String, initialData: ReviewWindowData?) throws -> String {
        let inlineJSON: String
        if let initialData {
            let raw = try JSONEncoder.diffReview.encode(initialData)
            inlineJSON = String(data: raw, encoding: .utf8) ?? "{}"
        } else {
            // Sentinel: JS treats this as "data not yet loaded; show loading state
            // and immediately request fresh data".
            inlineJSON = "{\"loading\":true}"
        }
        let escaped = inlineJSON
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return template
            .replacingOccurrences(of: "\"__INLINE_DATA__\"", with: escaped)
            .replacingOccurrences(of: "__INLINE_JS__", with: appJs)
    }

    func dispose() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "glimpse")
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
            dispatchClose()
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let decoder = JSONDecoder.diffReview

        switch type {
        case "request-review-data":
            guard let payload = try? decoder.decode(RequestReviewDataPayload.self, from: data) else { return }
            dispatch(.requestReviewData(requestId: payload.requestId))
        case "request-commit":
            guard let payload = try? decoder.decode(RequestCommitPayload.self, from: data) else { return }
            dispatch(.requestCommit(requestId: payload.requestId, sha: payload.sha))
        case "request-file":
            guard let payload = try? decoder.decode(RequestFilePayload.self, from: data) else { return }
            dispatch(.requestFile(requestId: payload.requestId, fileId: payload.fileId, scope: payload.scope, commitSha: payload.commitSha))
        case "clipboard-read":
            guard let payload = try? decoder.decode(ClipboardReadPayload.self, from: data) else { return }
            dispatch(.clipboardRead(requestId: payload.requestId))
        case "clipboard-write":
            guard let payload = try? decoder.decode(ClipboardWritePayload.self, from: data) else { return }
            dispatch(.clipboardWrite(text: payload.text))
        case "submit":
            guard let payload = try? decoder.decode(PickyDiffReviewPrompt.SubmitPayload.self, from: data) else { return }
            dispatch(.submit(payload: payload))
        case "cancel":
            dispatch(.cancel)
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

enum PickyDiffReviewWebHostError: LocalizedError {
    case missingResourceDirectory

    var errorDescription: String? {
        switch self {
        case .missingResourceDirectory:
            "DiffReview resources are missing from the app bundle."
        }
    }
}

private final class PickyDiffReviewURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pickydiff"
    static let indexURL = URL(string: "pickydiff://review/index.html")!

    private var resourceRoot: URL?
    private var renderedHTML: String?

    func configure(resourceRoot: URL, renderedHTML: String) {
        self.resourceRoot = resourceRoot.standardizedFileURL
        self.renderedHTML = renderedHTML
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, message: "Missing request URL.")
            return
        }

        if url.host == "review", url.path == "/index.html" {
            guard let renderedHTML, let data = renderedHTML.data(using: .utf8) else {
                fail(urlSchemeTask, message: "Rendered review HTML is unavailable.")
                return
            }
            send(data: data, mimeType: "text/html", url: url, task: urlSchemeTask)
            return
        }

        guard let resourceRoot, let fileURL = resolveResourceURL(for: url, resourceRoot: resourceRoot) else {
            fail(urlSchemeTask, message: "Requested resource is outside DiffReview resources.")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            send(data: data, mimeType: mimeType(for: fileURL), url: url, task: urlSchemeTask)
        } catch {
            fail(urlSchemeTask, message: error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func resolveResourceURL(for url: URL, resourceRoot: URL) -> URL? {
        guard url.host == "review" else { return nil }
        let relativePath = String(url.path.dropFirst())
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath.split(separator: "/").allSatisfy({ $0 != ".." }) else { return nil }

        let fileURL = resourceRoot.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = resourceRoot.path.hasSuffix("/") ? resourceRoot.path : resourceRoot.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else { return nil }
        return fileURL
    }

    private func send(data: Data, mimeType: String, url: URL, task: WKURLSchemeTask) {
        let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, message: String) {
        task.didFailWithError(NSError(domain: "PickyDiffReviewURLSchemeHandler", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js": "application/javascript"
        case "css": "text/css"
        case "ttf": "font/ttf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "json": "application/json"
        case "html": "text/html"
        default: "application/octet-stream"
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

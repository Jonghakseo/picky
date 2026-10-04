import AppKit
import SwiftUI

/// Resolve local links at click time, so cached markdown can be shared by
/// sessions without capturing another session's working directory.
struct PickyMarkdownLinkContext {
    var workingDirectory: String?
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var onFailure: (PickyMarkdownLinkFailure) -> Void = { failure in
        let alert = NSAlert()
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.addButton(withTitle: L10n.t("common.close"))
        alert.runModal()
    }

    @MainActor
    func handle(
        _ url: URL,
        openFile: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        if PickyDeepLinkDispatcher.shared.handle(url) { return true }
        guard url.scheme == nil || url.isFileURL else { return false }

        guard let fileURL = resolvedFileURL(url) else {
            onFailure(.unresolvedPath(url.relativeString))
            return true
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            onFailure(.missingFile(fileURL.path))
            return true
        }
        if !openFile(fileURL) {
            onFailure(.cannotOpen(fileURL.path))
        }
        // Never let AppKit retry a failed local link with the original URL.
        return true
    }

    private func expandingHome(_ path: String) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private func resolvedFileURL(_ url: URL) -> URL? {
        guard let source = URLComponents(url: url, resolvingAgainstBaseURL: true),
              source.host == nil || source.host == "" || source.host == "localhost",
              !source.path.isEmpty else { return nil }
        var path = source.path
        if path == "~" || path.hasPrefix("~/") {
            path = expandingHome(path)
        }
        if !path.hasPrefix("/") {
            guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
            let directory = expandingHome(workingDirectory)
            guard directory.hasPrefix("/") else { return nil }
            path = (directory as NSString).appendingPathComponent(path)
        }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard var result = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return nil }
        result.percentEncodedQuery = source.percentEncodedQuery
        result.percentEncodedFragment = source.percentEncodedFragment
        return result.url
    }
}

enum PickyMarkdownLinkFailure: Equatable {
    case missingFile(String)
    case unresolvedPath(String)
    case cannotOpen(String)

    var title: String {
        switch self {
        case .missingFile: L10n.t("hud.markdownLink.fileNotFound")
        case .unresolvedPath, .cannotOpen: L10n.t("hud.markdownLink.cannotOpen")
        }
    }

    var message: String {
        let key: String
        let path: String
        switch self {
        case .missingFile(let value):
            key = "hud.markdownLink.fileNotFound.help"
            path = value
        case .unresolvedPath(let value):
            key = "hud.markdownLink.unresolvedPath.help"
            path = value
        case .cannotOpen(let value):
            key = "hud.markdownLink.cannotOpen.help"
            path = value
        }
        return L10n.t(key) + "\n\n" + path
    }
}

private struct PickyMarkdownLinkContextKey: EnvironmentKey {
    static let defaultValue = PickyMarkdownLinkContext()
}

extension EnvironmentValues {
    var pickyMarkdownLinkContext: PickyMarkdownLinkContext {
        get { self[PickyMarkdownLinkContextKey.self] }
        set { self[PickyMarkdownLinkContextKey.self] = newValue }
    }
}

class PickyMarkdownLinkTextViewDelegate: NSObject, NSTextViewDelegate {
    var linkContext = PickyMarkdownLinkContext()
    // The only external effect is injectable for click-path regression tests.
    var openFile: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url else { return false }
        return linkContext.handle(url, openFile: openFile)
    }
}

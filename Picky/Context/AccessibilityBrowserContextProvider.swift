//
//  AccessibilityBrowserContextProvider.swift
//  Picky
//
//  Fallback browser context provider that reads the frontmost window's title
//  (and, in later commits, URL) directly from the Accessibility API. Unlike
//  AppleScript, AX targets a specific PID and can see incognito windows, so
//  this is the natural fallback when AppleScriptBrowserContextProvider gives
//  up because of a multi-instance or incognito gate.
//

import AppKit
import ApplicationServices
import Foundation

struct AccessibilityBrowserContextProvider: PickyAdvancedBrowserContextProviding {
    typealias TitleExtractor = (pid_t) -> String?
    typealias URLExtractor = (pid_t, String) -> String?

    static let defaultSupportedBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac"
    ]

    var frontmostApplicationProvider: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var axTrustChecker: () -> Bool = { AXIsProcessTrusted() }
    var supportedBundleIds: Set<String> = AccessibilityBrowserContextProvider.defaultSupportedBundleIds
    var titleExtractor: TitleExtractor = AccessibilityBrowserContextProvider.defaultTitleExtractor
    var urlExtractor: URLExtractor = { _, _ in nil }

    func browserContextResult() -> PickyContextCaptureResult<PickyBrowserContext> {
        guard let app = frontmostApplicationProvider(),
              let bundleId = app.bundleIdentifier,
              supportedBundleIds.contains(bundleId) else {
            return .unavailable()
        }
        guard axTrustChecker() else {
            return .unavailable(warnings: [
                "Browser context fallback unavailable: Accessibility permission required to read frontmost browser window."
            ])
        }
        let pid = app.processIdentifier
        let title = titleExtractor(pid)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false) ? title : nil
        let urlString = urlExtractor(pid, bundleId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL: URL? = {
            guard let urlString, !urlString.isEmpty else { return nil }
            if let url = URL(string: urlString), url.scheme != nil { return url }
            return URL(string: "https://" + urlString)
        }()
        if resolvedTitle == nil && resolvedURL == nil {
            return .unavailable(warnings: [
                "Browser context fallback unavailable: no AX title/URL for frontmost browser pid=\(pid)."
            ])
        }
        return .value(PickyBrowserContext(url: resolvedURL, title: resolvedTitle, selectedText: nil))
    }

    private static func defaultTitleExtractor(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let value = focused else { return nil }
        let window = value as! AXUIElement
        var titleAny: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleAny) == .success,
              let title = titleAny as? String,
              !title.isEmpty else { return nil }
        return title
    }
}

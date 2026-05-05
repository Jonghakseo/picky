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
    var urlExtractor: URLExtractor = AccessibilityBrowserContextProvider.defaultURLExtractor

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
        guard let window = focusedWindow(forPID: pid) else { return nil }
        var titleAny: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleAny) == .success,
              let title = titleAny as? String,
              !title.isEmpty else { return nil }
        return title
    }

    /// Best-effort URL extraction from the frontmost browser window's omnibox.
    /// Chrome/Brave/Edge expose the address bar with a stable AXIdentifier of
    /// "AddressAndSearchBar". Safari and Arc are not yet covered; they fall
    /// through to nil and the chained AppleScript provider remains the source
    /// of truth for the URL when its gates pass.
    static func defaultURLExtractor(pid: pid_t, bundleId: String) -> String? {
        let identifier: String
        switch bundleId {
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            identifier = "AddressAndSearchBar"
        default:
            return nil
        }
        guard let window = focusedWindow(forPID: pid) else { return nil }
        return findOmniboxValue(in: window, identifier: identifier)
    }

    private static func focusedWindow(forPID pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let value = focused else { return nil }
        return (value as! AXUIElement)
    }

    /// BFS the AX subtree under `root` looking for the first descendant whose
    /// AXIdentifier matches `identifier`, then return its AXValue. Bounded by
    /// `maxNodes` so we never wander into a runaway WebKit subtree.
    private static func findOmniboxValue(in root: AXUIElement, identifier: String) -> String? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let maxNodes = 2000
        while !queue.isEmpty && visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            var idAny: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idAny) == .success,
               let idString = idAny as? String,
               idString == identifier {
                var valueAny: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueAny) == .success,
                   let value = valueAny as? String,
                   !value.isEmpty {
                    return value
                }
            }
            var childrenAny: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenAny) == .success,
               let children = childrenAny as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }
}

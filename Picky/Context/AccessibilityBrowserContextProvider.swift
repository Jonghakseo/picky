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

    struct ElementSnapshot: Equatable {
        let role: String?
        let identifier: String?
        let title: String?
        let description: String?
        let placeholder: String?
        let value: String?
    }

    struct OmniboxTarget {
        let identifiers: Set<String>
        let labelFragments: [String]
    }

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

    func browserContextResult() async -> PickyContextCaptureResult<PickyBrowserContext> {
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
    /// Chrome-family browsers usually expose a stable AXIdentifier, but recent
    /// versions/locales may only expose role/description/placeholder metadata.
    /// This provider targets the frontmost PID's focused window, so headless or
    /// background browser instances cannot be mistaken for the user's window.
    static func defaultURLExtractor(pid: pid_t, bundleId: String) -> String? {
        guard let target = omniboxTarget(for: bundleId),
              let window = focusedWindow(forPID: pid) else { return nil }
        return findOmniboxValue(in: window, target: target)
    }

    static func omniboxTarget(for bundleId: String) -> OmniboxTarget? {
        switch bundleId {
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            return OmniboxTarget(
                identifiers: ["AddressAndSearchBar"],
                labelFragments: [
                    "address and search",
                    "address bar",
                    "search or type",
                    "search google or type",
                    "주소"
                ]
            )
        default:
            return nil
        }
    }

    private static func focusedWindow(forPID pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let value = focused else { return nil }
        return (value as! AXUIElement)
    }

    /// BFS the AX subtree under `root` looking for an address/search field.
    /// Prefer explicit omnibox metadata, then fall back to the first URL-like
    /// text field value. Bounded by `maxNodes` so we never wander into a runaway
    /// WebKit subtree.
    private static func findOmniboxValue(in root: AXUIElement, target: OmniboxTarget) -> String? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let maxNodes = 2000
        var firstURLLikeTextFieldValue: String?

        while !queue.isEmpty && visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            let snapshot = elementSnapshot(element)

            if isExplicitOmnibox(snapshot, target: target),
               let value = normalizedOmniboxValue(snapshot.value) {
                return value
            }

            if firstURLLikeTextFieldValue == nil,
               isTextEntry(snapshot),
               let value = normalizedOmniboxValue(snapshot.value),
               looksLikeBrowserURL(value) {
                firstURLLikeTextFieldValue = value
            }

            var childrenAny: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenAny) == .success,
               let children = childrenAny as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return firstURLLikeTextFieldValue
    }

    private static func elementSnapshot(_ element: AXUIElement) -> ElementSnapshot {
        ElementSnapshot(
            role: stringAttribute(kAXRoleAttribute as CFString, from: element),
            identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element),
            title: stringAttribute(kAXTitleAttribute as CFString, from: element),
            description: stringAttribute(kAXDescriptionAttribute as CFString, from: element),
            placeholder: stringAttribute(kAXPlaceholderValueAttribute as CFString, from: element),
            value: stringAttribute(kAXValueAttribute as CFString, from: element)
        )
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var anyValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &anyValue) == .success else { return nil }
        return anyValue as? String
    }

    static func isExplicitOmnibox(_ snapshot: ElementSnapshot, target: OmniboxTarget) -> Bool {
        if let identifier = snapshot.identifier, target.identifiers.contains(identifier) {
            return true
        }
        let labels = [snapshot.title, snapshot.description, snapshot.placeholder]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return labels.contains { label in
            target.labelFragments.contains { label.contains($0) }
        }
    }

    static func isTextEntry(_ snapshot: ElementSnapshot) -> Bool {
        switch snapshot.role {
        case kAXTextFieldRole, kAXComboBoxRole:
            return true
        default:
            return false
        }
    }

    static func normalizedOmniboxValue(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return value
    }

    static func looksLikeBrowserURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 4096,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") || lowercased.hasPrefix("file://") || lowercased.hasPrefix("chrome://") || lowercased.hasPrefix("edge://") || lowercased.hasPrefix("brave://") || lowercased.hasPrefix("about:") {
            return true
        }
        if lowercased.hasPrefix("localhost:") || lowercased == "localhost" || lowercased.hasPrefix("127.0.0.1") || lowercased.hasPrefix("[::1]") {
            return true
        }
        guard trimmed.contains("."), !trimmed.contains("@") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

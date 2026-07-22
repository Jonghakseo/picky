//
//  PickyAdvancedContext.swift
//  Picky
//
//  Advanced neutral context capture helpers. Providers expose browser, selected
//  text, active window, and region screenshot metadata without interpreting the
//  user's intent.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum PickyContextCaptureResult<Value> {
    case value(Value, warnings: [String] = [])
    case unavailable(warnings: [String] = [])

    var value: Value? {
        switch self {
        case .value(let value, _): value
        case .unavailable: nil
        }
    }

    var warnings: [String] {
        switch self {
        case .value(_, let warnings), .unavailable(let warnings): warnings
        }
    }
}

protocol PickyAdvancedBrowserContextProviding {
    /// Async because some providers (AppleScript) must dispatch off the main
    /// actor to avoid blocking the UI runloop on `NSAppleScript.executeAndReturnError`,
    /// which itself spins `CFRunLoopRun` waiting for `AESendMessage` to return.
    func browserContextResult() async -> PickyContextCaptureResult<PickyBrowserContext>
}

protocol PickySelectedTextProviding {
    func selectedTextResult() -> PickyContextCaptureResult<PickySelectedTextCapture>
}

struct PickySelectedTextCapture: Codable, Equatable {
    let text: String
    let isTruncated: Bool
    let originalLength: Int
}

struct PickySelectedTextTruncator {
    let maxCharacters: Int

    init(maxCharacters: Int = 8_000) {
        self.maxCharacters = max(1, maxCharacters)
    }

    func truncate(_ text: String) -> PickySelectedTextCapture? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let originalLength = trimmed.count
        if originalLength <= maxCharacters {
            return PickySelectedTextCapture(text: trimmed, isTruncated: false, originalLength: originalLength)
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return PickySelectedTextCapture(
            text: String(trimmed[..<end]) + "\n[truncated by Picky]",
            isTruncated: true,
            originalLength: originalLength
        )
    }
}

struct NullPickySelectedTextProvider: PickySelectedTextProviding {
    func selectedTextResult() -> PickyContextCaptureResult<PickySelectedTextCapture> { .unavailable() }
}

struct ChainedSelectedTextProvider: PickySelectedTextProviding {
    let providers: [PickySelectedTextProviding]

    func selectedTextResult() -> PickyContextCaptureResult<PickySelectedTextCapture> {
        var accumulated: [String] = []
        for provider in providers {
            let providerName = String(describing: type(of: provider))
            let result = provider.selectedTextResult()
            switch result {
            case .value(let value, let warnings):
                PickyLog.notice(
                    .contextCapture,
                    prefix: "🧭 Picky context —",
                    message: "event=selectedTextProviderResult provider=\(providerName) result=value chars=\(value.text.count) warnings=\(warnings.count)"
                )
                return .value(value, warnings: accumulated + warnings)
            case .unavailable(let warnings):
                PickyLog.notice(
                    .contextCapture,
                    prefix: "🧭 Picky context —",
                    message: "event=selectedTextProviderResult provider=\(providerName) result=unavailable warnings=\(warnings.count)"
                )
                accumulated.append(contentsOf: warnings)
            }
        }
        return .unavailable(warnings: accumulated)
    }
}

struct AccessibilitySelectedTextProvider: PickySelectedTextProviding {
    var frontmostApplicationProvider: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var axTrustChecker: () -> Bool = { AXIsProcessTrusted() }
    var ignoredBundleIds: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    var candidateElementsProvider: (pid_t) -> [AXUIElement] = AccessibilitySelectedTextProvider.defaultCandidateElements
    var selectedTextFinder: ([AXUIElement]) -> String? = AccessibilitySelectedTextProvider.firstSelectedText
    var truncator = PickySelectedTextTruncator()

    func selectedTextResult() -> PickyContextCaptureResult<PickySelectedTextCapture> {
        guard let app = frontmostApplicationProvider() else { return .unavailable() }
        if let bundleId = app.bundleIdentifier, ignoredBundleIds.contains(bundleId) {
            return .unavailable()
        }
        guard axTrustChecker() else {
            return .unavailable(warnings: ["Selected text unavailable: Accessibility permission is required to read the focused element."])
        }
        guard let capture = selectedTextFinder(candidateElementsProvider(app.processIdentifier)).flatMap(truncator.truncate) else {
            return .unavailable()
        }
        var warnings: [String] = []
        if capture.isTruncated { warnings.append("Selected text truncated from \(capture.originalLength) characters.") }
        return .value(capture, warnings: warnings)
    }

    static func defaultCandidateElements(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var candidates: [AXUIElement] = []
        for attribute in [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute] {
            var anyValue: AnyObject?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &anyValue) == .success,
               let value = anyValue {
                candidates.append(value as! AXUIElement)
            }
        }
        candidates.append(app)
        return candidates
    }

    static func firstSelectedText(in roots: [AXUIElement]) -> String? {
        var queue = roots
        var visited = 0
        let maxNodes = 2_000
        while !queue.isEmpty && visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            if let text = selectedText(in: element) { return text }
            var childrenAny: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenAny) == .success,
               let children = childrenAny as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private static func selectedText(in element: AXUIElement) -> String? {
        let selected = stringAttribute(kAXSelectedTextAttribute as CFString, from: element)
        let value = stringAttribute(kAXValueAttribute as CFString, from: element)
        var rangeAny: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeAny) == .success,
              let rangeObject = rangeAny else { return nil }
        let rangeValue = rangeObject as! AXValue
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range),
              let resolved = resolvedSelectedText(selected: selected, value: value, range: range) else { return nil }
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? "none"
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element) ?? "none"
        let isFocused = boolAttribute(kAXFocusedAttribute as CFString, from: element)
        PickyLog.notice(
            .contextCapture,
            prefix: "🧭 Picky context —",
            message: "event=accessibilitySelectedTextMatch role=\(role) subrole=\(subrole) focused=\(isFocused.map(String.init) ?? "unknown") rangeLocation=\(range.location) rangeLength=\(range.length) selectedChars=\(selected?.count ?? 0) valueChars=\(value?.count ?? 0)"
        )
        return resolved
    }

    /// Some apps expose their focused field value as `AXSelectedText` even when
    /// the selected-text range is empty. The range is the authoritative signal
    /// that a user actually selected text.
    static func resolvedSelectedText(selected: String?, value: String?, range: CFRange) -> String? {
        guard range.location >= 0, range.length > 0 else { return nil }
        if let selected = selected?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            return selected
        }
        guard let value else { return nil }
        let nsValue = value as NSString
        let nsRange = NSRange(location: range.location, length: range.length)
        guard NSMaxRange(nsRange) <= nsValue.length else { return nil }
        return nsValue.substring(with: nsRange)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var anyValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &anyValue) == .success else { return nil }
        return anyValue as? String
    }

    private static func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var anyValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &anyValue) == .success else { return nil }
        return anyValue as? Bool
    }
}

struct AppleScriptBrowserContextProvider: PickyAdvancedBrowserContextProviding {
    struct BrowserScriptTarget {
        let bundleIdentifier: String
        let applicationName: String
        let scriptBody: String
    }

    var frontmostBundleIdProvider: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var instanceCountProvider: (String) -> Int = AppleScriptBrowserContextProvider.visibleBrowserInstanceCount
    var frontmostWindowTitleProvider: () -> String? = {
        CGWindowPickyWindowContextProvider().activeWindowContext()?.title
    }
    /// Synchronous, blocking runner. The provider *never* calls this from the
    /// main actor — `browserContextResult()` jumps to a detached thread and uses
    /// `scriptExecutionTimeout` as a wall-clock guard so a hung browser cannot
    /// freeze the UI runloop.
    var scriptRunner: (String) throws -> String = { source in
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "" }
        let descriptor = script.executeAndReturnError(&error)
        if let error { throw NSError(domain: "PickyAppleScript", code: 1, userInfo: error as? [String: Any]) }
        return descriptor.stringValue ?? ""
    }

    /// Wall-clock cap for a single AppleScript execution. When this elapses,
    /// `browserContextResult()` returns `.unavailable(warnings: ["timed out"])`.
    /// The background thread that ran the script is left to finish on its own
    /// (we cannot safely interrupt NSAppleScript mid-flight); the script body
    /// also carries `with timeout of 2 seconds`, so the second invocation will
    /// usually fail fast at the AppleEvent layer.
    var scriptExecutionTimeout: TimeInterval = 2.5

    static func visibleBrowserInstanceCount(bundleId: String) -> Int {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleId }
            .filter { shouldCountBrowserInstance(arguments: processArguments(forPID: $0.processIdentifier)) }
            .count
    }

    static func shouldCountBrowserInstance(arguments: [String]?) -> Bool {
        guard let arguments else { return true }
        let lowercased = arguments.map { $0.lowercased() }
        if lowercased.contains("--headless") || lowercased.contains(where: { $0.hasPrefix("--headless=") }) {
            return false
        }
        if lowercased.contains("--no-startup-window") {
            return false
        }
        if lowercased.contains(where: { $0.contains("playwright_chromiumdev_profile-") }) {
            return false
        }
        if lowercased.contains(where: { $0.contains("/playwright/") || $0.contains("@playwright") }) {
            return false
        }
        return true
    }

    private static func processArguments(forPID pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArgumentsBuffer(Array(buffer.prefix(size)))
    }

    static func parseProcessArgumentsBuffer(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.prefix(MemoryLayout<Int32>.size).enumerated().reduce(Int32(0)) { result, pair in
            result | (Int32(pair.element) << (pair.offset * 8))
        }
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < buffer.count, arguments.count < Int(argc) {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            if start < index,
               let argument = String(bytes: buffer[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            while index < buffer.count, buffer[index] == 0 { index += 1 }
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// Each target's script returns five newline-separated fields:
    ///   1) URL of the front window's active tab
    ///   2) Title of that active tab
    ///   3) Total count of windows visible to AppleScript
    ///   4) Active-tab titles of every window joined by character id 31 (US).
    ///   5) Text selected in the active tab, when the browser allows JavaScript from Apple Events.
    /// We need (3)/(4) so the caller can detect when the OS frontmost window is
    /// not visible to AppleScript at all (e.g. Chrome incognito or Playwright
    /// background instance), in which case (1)/(2) describe a different window.
    var selectedTextTruncator = PickySelectedTextTruncator()

    private let targets: [BrowserScriptTarget] = [
        BrowserScriptTarget(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            scriptBody: """
            tell application "Safari"
              with timeout of 2 seconds
                set wc to count of windows
                if wc is 0 then return linefeed & linefeed & "0" & linefeed
                set sep to character id 31
                set u to URL of current tab of front window
                set t to name of current tab of front window
                set ns to ""
                repeat with w in windows
                  set ns to ns & (name of current tab of w) & sep
                end repeat
                set s to ""
                try
                  set s to do JavaScript "(function(){var s=window.getSelection&&window.getSelection();return s?s.toString():'';})()" in current tab of front window
                end try
                return u & linefeed & t & linefeed & wc & linefeed & ns & linefeed & s
              end timeout
            end tell
            """
        ),
        BrowserScriptTarget(
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            scriptBody: """
            tell application "Google Chrome"
              with timeout of 2 seconds
                set wc to count of windows
                if wc is 0 then return linefeed & linefeed & "0" & linefeed
                set sep to character id 31
                set u to URL of active tab of front window
                set t to title of active tab of front window
                set ns to ""
                repeat with w in windows
                  set ns to ns & (title of active tab of w) & sep
                end repeat
                set s to ""
                try
                  set s to execute active tab of front window javascript "(function(){var s=window.getSelection&&window.getSelection();return s?s.toString():'';})()"
                end try
                return u & linefeed & t & linefeed & wc & linefeed & ns & linefeed & s
              end timeout
            end tell
            """
        ),
        BrowserScriptTarget(
            bundleIdentifier: "company.thebrowser.Browser",
            applicationName: "Arc",
            scriptBody: """
            tell application "Arc"
              with timeout of 2 seconds
                set wc to count of windows
                if wc is 0 then return linefeed & linefeed & "0" & linefeed
                set sep to character id 31
                set u to URL of active tab of front window
                set t to title of active tab of front window
                set ns to ""
                repeat with w in windows
                  set ns to ns & (title of active tab of w) & sep
                end repeat
                set s to ""
                try
                  set s to execute active tab of front window javascript "(function(){var s=window.getSelection&&window.getSelection();return s?s.toString():'';})()"
                end try
                return u & linefeed & t & linefeed & wc & linefeed & ns & linefeed & s
              end timeout
            end tell
            """
        )
    ]

    func browserContextResult() async -> PickyContextCaptureResult<PickyBrowserContext> {
        guard let bundleIdentifier = frontmostBundleIdProvider(),
              let target = targets.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return .unavailable()
        }
        if instanceCountProvider(bundleIdentifier) >= 2 {
            return .unavailable(warnings: [
                "Browser context unavailable: multiple \(target.applicationName) instances detected; AppleScript dispatch may target the wrong instance (e.g. Playwright/headless)."
            ])
        }
        let raw: String
        do {
            raw = try await runScriptOffMainActor(target.scriptBody)
        } catch let error as AppleScriptTimeoutError {
            return .unavailable(warnings: ["Browser context unavailable: AppleScript for \(target.applicationName) timed out after \(error.timeoutSeconds)s."])
        } catch {
            return .unavailable(warnings: ["Browser context permission or automation failure for \(target.applicationName): \(error.localizedDescription)"])
        }
        let parts = raw.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else {
            return .unavailable(warnings: ["Browser context unavailable: unexpected response format from \(target.applicationName)."])
        }
        let urlString = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let windowCount = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard windowCount > 0, !urlString.isEmpty, let url = URL(string: urlString) else {
            return .unavailable(warnings: ["Browser context unavailable: no active tab URL returned from \(target.applicationName)."])
        }
        let separator: Character = "\u{1F}"
        let names = parts[3]
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let frontTitle = frontmostWindowTitleProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !frontTitle.isEmpty,
           !names.contains(frontTitle) {
            return .unavailable(warnings: [
                "Browser context unavailable: frontmost \(target.applicationName) window \"\(frontTitle)\" not visible to AppleScript (likely incognito or background instance)."
            ])
        }
        let resolvedTitle = title.isEmpty ? nil : title
        var warnings: [String] = []
        let selectedText = parts.count >= 5 ? selectedTextTruncator.truncate(parts[4]) : nil
        if let selectedText = selectedText, selectedText.isTruncated {
            warnings.append("Selected text truncated from \(selectedText.originalLength) characters.")
        }
        return .value(PickyBrowserContext(url: url, title: resolvedTitle, selectedText: selectedText?.text), warnings: warnings)
    }

    /// Runs `scriptRunner` on a one-shot background thread, with a wall-clock
    /// timeout. The main actor only awaits the continuation, so a hung browser
    /// can no longer block the UI runloop on `AESendMessage` (which was the
    /// root cause of the "picky CLI freezes the app" beachballs).
    ///
    /// NSAppleScript itself spins a CFRunLoop while waiting for the Apple
    /// Event reply, so it needs to be on a real Thread (not an arbitrary
    /// DispatchQueue worker) — `Thread.start` gives us a fresh runloop owner
    /// that is safe to leave running if the timeout fires.
    private func runScriptOffMainActor(_ source: String) async throws -> String {
        let runner = scriptRunner
        let timeout = scriptExecutionTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let resolver = AppleScriptResolveOnce()
            let thread = Thread {
                autoreleasepool {
                    do {
                        let value = try runner(source)
                        if resolver.claim() { continuation.resume(returning: value) }
                    } catch {
                        if resolver.claim() { continuation.resume(throwing: error) }
                    }
                }
            }
            thread.qualityOfService = .userInitiated
            thread.name = "Picky.AppleScript"
            thread.start()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if resolver.claim() {
                    continuation.resume(throwing: AppleScriptTimeoutError(timeoutSeconds: timeout))
                }
            }
        }
    }
}

struct AppleScriptTimeoutError: LocalizedError {
    let timeoutSeconds: TimeInterval
    var errorDescription: String? { "AppleScript execution exceeded \(timeoutSeconds)s." }
}

final class AppleScriptResolveOnce {
    private var resolved = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}

struct ClipboardSelectedTextProvider: PickySelectedTextProviding {
    var pasteboard: NSPasteboard = .general
    var keyboardCopier: () -> Bool = ClipboardSelectedTextProvider.copySelectionWithKeyboardShortcut
    var truncator = PickySelectedTextTruncator()

    func selectedTextResult() -> PickyContextCaptureResult<PickySelectedTextCapture> {
        let previousItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        let previousChangeCount = pasteboard.changeCount

        defer {
            pasteboard.clearContents()
            if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
        }

        pasteboard.clearContents()
        guard keyboardCopier() else {
            return .unavailable(warnings: ["Selected text unavailable: Accessibility permission is required to copy the current selection."])
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard pasteboard.changeCount != previousChangeCount || pasteboard.string(forType: .string) != nil,
              let text = pasteboard.string(forType: .string),
              let capture = truncator.truncate(text) else {
            return .unavailable()
        }
        var warnings: [String] = []
        if capture.isTruncated { warnings.append("Selected text truncated from \(capture.originalLength) characters.") }
        return .value(capture, warnings: warnings)
    }

    static func copySelectionWithKeyboardShortcut() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

struct CGWindowPickyWindowContextProvider: PickyWindowContextProviding {
    var frontmostApplicationProvider: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }

    func activeWindowContext() -> PickyWindowContext? {
        guard let pid = frontmostApplicationProvider()?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let window = windows.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
        }
        guard let window else { return nil }
        let title = window[kCGWindowName as String] as? String
        let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat]
        let rect = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        return PickyWindowContext(title: title?.isEmpty == true ? nil : title, frame: rect.map(PickyCGRect.init))
    }
}

struct PickyRegionScreenshotContext: Codable, Equatable {
    let label: String
    let screenId: String
    let bounds: PickyCGRect

    func validate(within screen: PickyScreenContext) -> Bool {
        let screenRect = CGRect(x: screen.frame.x, y: screen.frame.y, width: screen.frame.width, height: screen.frame.height)
        let region = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        return region.width > 0 && region.height > 0 && screenRect.contains(region)
    }
}

/// Tries each provider in order, returning the first .value. Warnings from
/// every step are accumulated so callers can see why earlier providers gave
/// up (e.g. "multiple Chrome instances" + "AX returned title only").
struct ChainedBrowserContextProvider: PickyAdvancedBrowserContextProviding {
    let providers: [PickyAdvancedBrowserContextProviding]

    init(providers: [PickyAdvancedBrowserContextProviding]) {
        self.providers = providers
    }

    func browserContextResult() async -> PickyContextCaptureResult<PickyBrowserContext> {
        var accumulated: [String] = []
        for provider in providers {
            let providerName = String(describing: type(of: provider))
            let result = await provider.browserContextResult()
            switch result {
            case .value(let value, let warnings):
                PickyLog.notice(
                    .contextCapture,
                    prefix: "🧭 Picky context —",
                    message: "event=browserContextProviderResult provider=\(providerName) result=value selectedChars=\(value.selectedText?.count ?? 0) warnings=\(warnings.count)"
                )
                return .value(value, warnings: accumulated + warnings)
            case .unavailable(let warnings):
                PickyLog.notice(
                    .contextCapture,
                    prefix: "🧭 Picky context —",
                    message: "event=browserContextProviderResult provider=\(providerName) result=unavailable warnings=\(warnings.count)"
                )
                accumulated.append(contentsOf: warnings)
            }
        }
        return .unavailable(warnings: accumulated)
    }
}

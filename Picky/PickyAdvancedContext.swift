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
    func browserContextResult() -> PickyContextCaptureResult<PickyBrowserContext>
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

struct AppleScriptBrowserContextProvider: PickyAdvancedBrowserContextProviding {
    struct BrowserScriptTarget {
        let bundleIdentifier: String
        let applicationName: String
        let scriptBody: String
    }

    var frontmostBundleIdProvider: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var instanceCountProvider: (String) -> Int = { bundleId in
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleId }.count
    }
    var frontmostWindowTitleProvider: () -> String? = {
        CGWindowPickyWindowContextProvider().activeWindowContext()?.title
    }
    var scriptRunner: (String) throws -> String = { source in
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "" }
        let descriptor = script.executeAndReturnError(&error)
        if let error { throw NSError(domain: "PickyAppleScript", code: 1, userInfo: error as? [String: Any]) }
        return descriptor.stringValue ?? ""
    }

    /// Each target's script returns four newline-separated fields:
    ///   1) URL of the front window's active tab
    ///   2) Title of that active tab
    ///   3) Total count of windows visible to AppleScript
    ///   4) Active-tab titles of every window joined by character id 31 (US).
    /// We need (3)/(4) so the caller can detect when the OS frontmost window is
    /// not visible to AppleScript at all (e.g. Chrome incognito or Playwright
    /// background instance), in which case (1)/(2) describe a different window.
    private let targets: [BrowserScriptTarget] = [
        BrowserScriptTarget(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            scriptBody: """
            tell application "Safari"
              set wc to count of windows
              if wc is 0 then return linefeed & linefeed & "0" & linefeed
              set sep to character id 31
              set u to URL of current tab of front window
              set t to name of current tab of front window
              set ns to ""
              repeat with w in windows
                set ns to ns & (name of current tab of w) & sep
              end repeat
              return u & linefeed & t & linefeed & wc & linefeed & ns
            end tell
            """
        ),
        BrowserScriptTarget(
            bundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            scriptBody: """
            tell application "Google Chrome"
              set wc to count of windows
              if wc is 0 then return linefeed & linefeed & "0" & linefeed
              set sep to character id 31
              set u to URL of active tab of front window
              set t to title of active tab of front window
              set ns to ""
              repeat with w in windows
                set ns to ns & (title of active tab of w) & sep
              end repeat
              return u & linefeed & t & linefeed & wc & linefeed & ns
            end tell
            """
        ),
        BrowserScriptTarget(
            bundleIdentifier: "company.thebrowser.Browser",
            applicationName: "Arc",
            scriptBody: """
            tell application "Arc"
              set wc to count of windows
              if wc is 0 then return linefeed & linefeed & "0" & linefeed
              set sep to character id 31
              set u to URL of active tab of front window
              set t to title of active tab of front window
              set ns to ""
              repeat with w in windows
                set ns to ns & (title of active tab of w) & sep
              end repeat
              return u & linefeed & t & linefeed & wc & linefeed & ns
            end tell
            """
        )
    ]

    func browserContextResult() -> PickyContextCaptureResult<PickyBrowserContext> {
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
            raw = try scriptRunner(target.scriptBody)
        } catch {
            return .unavailable(warnings: ["Browser context permission or automation failure for \(target.applicationName): \(error.localizedDescription)"])
        }
        let parts = raw.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
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
        return .value(PickyBrowserContext(url: url, title: resolvedTitle, selectedText: nil))
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

extension PickyScreenContext {
    var pointConventionLabel: String {
        "picky_show_pointer(x, y, label: \(label), coordinateSpace: screenshotPixel)"
    }
}

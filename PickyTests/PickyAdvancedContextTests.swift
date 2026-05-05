//
//  PickyAdvancedContextTests.swift
//  PickyTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Picky

private struct FakeAdvancedBrowserProvider: PickyAdvancedBrowserContextProviding {
    let result: PickyContextCaptureResult<PickyBrowserContext>
    func browserContextResult() -> PickyContextCaptureResult<PickyBrowserContext> { result }
}

private struct FakeSelectedTextProvider: PickySelectedTextProviding {
    let result: PickyContextCaptureResult<PickySelectedTextCapture>
    func selectedTextResult() -> PickyContextCaptureResult<PickySelectedTextCapture> { result }
}

private struct AdvancedFakeAppProvider: PickyApplicationContextProviding {
    func activeApplicationContext() -> PickyApplicationContext? {
        PickyApplicationContext(bundleId: "com.example.Browser", name: "Browser", pid: 7)
    }
}

private struct AdvancedFakeWindowProvider: PickyWindowContextProviding {
    func activeWindowContext() -> PickyWindowContext? {
        PickyWindowContext(title: "Front Window", frame: PickyCGRect(x: 100, y: 50, width: 900, height: 700))
    }
}

private struct MultiDisplayScreenProvider: PickyScreenContextProviding {
    func screenContexts() -> [PickyScreenContext] {
        [
            PickyScreenContext(label: "left display", frame: PickyCGRect(x: -1440, y: 0, width: 1440, height: 900), screenshotWidthInPixels: 2880, screenshotHeightInPixels: 1800, isCursorScreen: false, cursor: nil, imageData: Data()),
            PickyScreenContext(label: "main display", frame: PickyCGRect(x: 0, y: 0, width: 1512, height: 982), screenshotWidthInPixels: 3024, screenshotHeightInPixels: 1964, isCursorScreen: true, cursor: PickyCursorContext(globalPoint: PickyCGPoint(x: 100, y: 200), displayPoint: PickyCGPoint(x: 100, y: 782), screenshotPixel: PickyCGPoint(x: 200, y: 1564)), imageData: Data())
        ]
    }
}

struct PickyAdvancedContextTests {
    @Test func fakeBrowserAndSelectedTextProvidersAreIncludedWithWarnings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-advanced-\(UUID().uuidString)", isDirectory: true)
        let assembler = PickyContextPacketAssembler(
            appProvider: AdvancedFakeAppProvider(),
            windowProvider: AdvancedFakeWindowProvider(),
            advancedBrowserProvider: FakeAdvancedBrowserProvider(result: .value(PickyBrowserContext(url: URL(string: "https://example.com/path")!, title: "Example", selectedText: nil))),
            selectedTextProvider: FakeSelectedTextProvider(result: .value(PickySelectedTextCapture(text: "selected neutral text", isTruncated: false, originalLength: 21), warnings: ["selection warning"])),
            screenProvider: MultiDisplayScreenProvider(),
            screenshotStore: PickyAppSupportScreenshotStore(appSupportRoot: root),
            defaultCwd: "/tmp"
        )

        let packet = try assembler.assemble(source: "voice", transcript: "help")

        #expect(packet.browser?.url?.absoluteString == "https://example.com/path")
        #expect(packet.browser?.title == "Example")
        #expect(packet.selectedText == "selected neutral text")
        #expect(packet.activeWindow?.frame == PickyCGRect(x: 100, y: 50, width: 900, height: 700))
        #expect(packet.screenshots.map(\.screenId) == ["screen1", "screen2"])
        #expect(packet.screenshots[1].bounds == PickyCGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(packet.warnings.contains("selection warning"))
    }

    @Test func browserPermissionFailureIsNonFatalWarning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-browser-fail-\(UUID().uuidString)", isDirectory: true)
        let assembler = PickyContextPacketAssembler(
            appProvider: AdvancedFakeAppProvider(),
            advancedBrowserProvider: FakeAdvancedBrowserProvider(result: .unavailable(warnings: ["Browser context permission failure"])),
            screenProvider: MultiDisplayScreenProvider(),
            screenshotStore: PickyAppSupportScreenshotStore(appSupportRoot: root),
            defaultCwd: nil
        )

        let packet = try assembler.assemble(source: "voice", transcript: "help")

        #expect(packet.browser == nil)
        #expect(packet.warnings == ["Browser context permission failure"])
    }

    @Test func selectedTextTruncatesAndClipboardProviderRestoresPasteboard() throws {
        let capture = PickySelectedTextTruncator(maxCharacters: 5).truncate("abcdefg")
        #expect(capture?.isTruncated == true)
        #expect(capture?.text.contains("[truncated by Picky]") == true)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("picky-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)
        let provider = ClipboardSelectedTextProvider(pasteboard: pasteboard, keyboardCopier: {
            pasteboard.clearContents()
            pasteboard.setString("copied selection", forType: .string)
            return true
        }, truncator: PickySelectedTextTruncator(maxCharacters: 100))

        let result = provider.selectedTextResult()

        #expect(result.value?.text == "copied selection")
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }

    @Test func selectedTextPermissionFailureReturnsWarning() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("picky-test-denied-\(UUID().uuidString)"))
        let provider = ClipboardSelectedTextProvider(pasteboard: pasteboard, keyboardCopier: { false })

        let result = provider.selectedTextResult()

        #expect(result.value == nil)
        #expect(result.warnings.first?.contains("Accessibility permission") == true)
    }

    @Test func regionMetadataValidatesBoundsAgainstScreen() {
        let screen = MultiDisplayScreenProvider().screenContexts()[1]
        let valid = PickyRegionScreenshotContext(label: "button", screenId: "screen2", bounds: PickyCGRect(x: 10, y: 10, width: 100, height: 80))
        let invalid = PickyRegionScreenshotContext(label: "outside", screenId: "screen2", bounds: PickyCGRect(x: 1500, y: 900, width: 100, height: 100))

        #expect(valid.validate(within: screen))
        #expect(!invalid.validate(within: screen))
    }

    // MARK: - AppleScriptBrowserContextProvider gating

    @Test func appleScriptProviderSkipsScriptWhenMultipleBrowserInstancesDetected() {
        let scriptCalls = ScriptCallCounter()
        var provider = AppleScriptBrowserContextProvider()
        provider.frontmostBundleIdProvider = { "com.google.Chrome" }
        provider.instanceCountProvider = { _ in 2 }
        provider.frontmostWindowTitleProvider = { "Anything" }
        provider.scriptRunner = { _ in
            scriptCalls.increment()
            return ""
        }

        let result = provider.browserContextResult()

        #expect(result.value == nil)
        #expect(scriptCalls.count == 0)
        #expect(result.warnings.contains(where: { $0.contains("multiple Google Chrome instances") }))
    }

    @Test func appleScriptProviderReturnsUnavailableWhenFrontmostWindowMissingFromAppleScriptList() {
        var provider = AppleScriptBrowserContextProvider()
        provider.frontmostBundleIdProvider = { "com.google.Chrome" }
        provider.instanceCountProvider = { _ in 1 }
        provider.frontmostWindowTitleProvider = { "Personal Access Tokens (Classic)" }
        provider.scriptRunner = { _ in
            "http://localhost:5173/\nAdmin | Creatrip\n1\nAdmin | Creatrip\u{1F}"
        }

        let result = provider.browserContextResult()

        #expect(result.value == nil)
        #expect(result.warnings.contains(where: { $0.contains("not visible to AppleScript") }))
    }

    @Test func appleScriptProviderReturnsValueWhenFrontmostTitleMatchesAppleScriptList() throws {
        var provider = AppleScriptBrowserContextProvider()
        provider.frontmostBundleIdProvider = { "com.google.Chrome" }
        provider.instanceCountProvider = { _ in 1 }
        provider.frontmostWindowTitleProvider = { "Picky Docs" }
        provider.scriptRunner = { _ in
            "https://example.com/picky\nPicky Docs\n2\nPicky Docs\u{1F}Other Tab\u{1F}"
        }

        let result = provider.browserContextResult()
        let context = try #require(result.value)

        #expect(context.url?.absoluteString == "https://example.com/picky")
        #expect(context.title == "Picky Docs")
        #expect(result.warnings.isEmpty)
    }

    @Test func appleScriptProviderSkipsCrossCheckWhenFrontmostWindowTitleUnavailable() throws {
        var provider = AppleScriptBrowserContextProvider()
        provider.frontmostBundleIdProvider = { "com.google.Chrome" }
        provider.instanceCountProvider = { _ in 1 }
        provider.frontmostWindowTitleProvider = { nil }
        provider.scriptRunner = { _ in
            "https://example.com/path\nSome Title\n1\nSome Title\u{1F}"
        }

        let result = provider.browserContextResult()
        let context = try #require(result.value)

        #expect(context.url?.absoluteString == "https://example.com/path")
        #expect(context.title == "Some Title")
    }

    @Test func appleScriptProviderTreatsZeroWindowCountAsUnavailable() {
        var provider = AppleScriptBrowserContextProvider()
        provider.frontmostBundleIdProvider = { "com.google.Chrome" }
        provider.instanceCountProvider = { _ in 1 }
        provider.frontmostWindowTitleProvider = { nil }
        provider.scriptRunner = { _ in "\n\n0\n" }

        let result = provider.browserContextResult()

        #expect(result.value == nil)
        #expect(result.warnings.contains(where: { $0.contains("no active tab URL") }))
    }

    @Test func appleScriptProviderReturnsUnavailableForUnsupportedFrontmostBundle() {
        var provider = AppleScriptBrowserContextProvider()
        provider.frontmostBundleIdProvider = { "com.example.NotABrowser" }
        provider.instanceCountProvider = { _ in 1 }
        provider.frontmostWindowTitleProvider = { "x" }
        provider.scriptRunner = { _ in "unused" }

        let result = provider.browserContextResult()

        #expect(result.value == nil)
        #expect(result.warnings.isEmpty)
    }
}

private final class ScriptCallCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

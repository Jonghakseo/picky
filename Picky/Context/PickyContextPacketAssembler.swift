//
//  PickyContextPacketAssembler.swift
//  Picky
//

import AppKit
import Foundation

struct WorkspacePickyApplicationContextProvider: PickyApplicationContextProviding {
    func activeApplicationContext() -> PickyApplicationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PickyApplicationContext(
            bundleId: app.bundleIdentifier,
            name: app.localizedName,
            pid: Int(app.processIdentifier)
        )
    }
}

struct NullPickyWindowContextProvider: PickyWindowContextProviding {
    func activeWindowContext() -> PickyWindowContext? { nil }
}

struct NullPickyBrowserContextProvider: PickyBrowserContextProviding {
    func browserContext() -> PickyBrowserContext? { nil }
}

struct AdvancedBrowserContextProviderAdapter: PickyBrowserContextProviding {
    let provider: PickyAdvancedBrowserContextProviding
    func browserContext() -> PickyBrowserContext? { provider.browserContextResult().value }
}

struct StaticPickyScreenContextProvider: PickyScreenContextProviding {
    let captures: [CompanionScreenCapture]

    func screenContexts() -> [PickyScreenContext] {
        captures.map { capture in
            PickyScreenContext(
                label: capture.label,
                frame: PickyCGRect(capture.displayFrame),
                screenshotWidthInPixels: capture.screenshotWidthInPixels,
                screenshotHeightInPixels: capture.screenshotHeightInPixels,
                isCursorScreen: capture.isCursorScreen,
                cursor: capture.cursor,
                imageData: capture.imageData
            )
        }
    }
}

struct PickyContextPacketAssembler {
    let appProvider: PickyApplicationContextProviding
    var windowProvider: PickyWindowContextProviding = NullPickyWindowContextProvider()
    var browserProvider: PickyBrowserContextProviding = NullPickyBrowserContextProvider()
    var advancedBrowserProvider: PickyAdvancedBrowserContextProviding?
    var selectedTextProvider: PickySelectedTextProviding = NullPickySelectedTextProvider()
    let screenProvider: PickyScreenContextProviding
    var screenshotStore: PickyScreenshotStoring = PickyAppSupportScreenshotStore()
    let defaultCwd: String?
    var now: () -> Date = Date.init
    var idGenerator: () -> String = { "context-\(UUID().uuidString)" }

    func assemble(source: String, transcript: String, selectedSessionId: String? = nil) throws -> PickyContextPacket {
        let contextID = idGenerator()
        let screens = screenProvider.screenContexts()
        let screenshots = try screens.enumerated().map { index, screen in
            try screenshotStore.store(screen, contextID: contextID, index: index)
        }
        var warnings = selectedSessionId.map { ["selectedSessionId=\($0)"] } ?? []
        let browser: PickyBrowserContext?
        if let advancedBrowserProvider {
            let result = advancedBrowserProvider.browserContextResult()
            browser = result.value
            warnings.append(contentsOf: result.warnings)
        } else {
            browser = browserProvider.browserContext()
        }
        let selectedTextResult = selectedTextProvider.selectedTextResult()
        warnings.append(contentsOf: selectedTextResult.warnings)
        let selectedText = selectedTextResult.value?.text ?? browser?.selectedText

        return PickyContextPacket(
            id: contextID,
            source: source,
            capturedAt: now(),
            transcript: transcript,
            selectedText: selectedText,
            cwd: defaultCwd,
            activeApp: appProvider.activeApplicationContext(),
            activeWindow: windowProvider.activeWindowContext(),
            browser: browser,
            screenshots: screenshots,
            warnings: warnings
        )
    }
}

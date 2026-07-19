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



struct StaticPickyScreenContextProvider: PickyScreenContextProviding {
    let captures: [CompanionScreenCapture]
    var inkCapture: PickyInkCapture?

    func screenContexts() -> [PickyScreenContext] {
        captures.enumerated().map { index, capture in
            let screenId = "screen\(index + 1)"
            return PickyScreenContext(
                label: capture.label,
                frame: PickyCGRect(capture.displayFrame),
                screenshotWidthInPixels: capture.screenshotWidthInPixels,
                screenshotHeightInPixels: capture.screenshotHeightInPixels,
                isCursorScreen: capture.isCursorScreen,
                cursor: capture.cursor,
                inkMarks: PickyInkMarkMapper.map(capture: inkCapture, to: capture, screenId: screenId),
                imageData: capture.imageData,
                annotationColorSampleGrid: capture.annotationColorSampleGrid,
                annotationSceneFingerprint: capture.annotationSceneFingerprint
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

    func assemble(source: String, transcript: String) async throws -> PickyContextPacket {
        // Browser/AX and selected-text collection do not depend on screenshot
        // persistence. Start them together so the latter does not sit behind
        // screenshot file I/O on the voice critical path.
        async let advancedBrowserResult: PickyContextCaptureResult<PickyBrowserContext>? = {
            guard let advancedBrowserProvider else { return nil }
            return await advancedBrowserProvider.browserContextResult()
        }()
        async let selectedTextResult = selectedTextProvider.selectedTextResult()

        let contextID = idGenerator()
        let screens = screenProvider.screenContexts()
        let screenshots = try screens.enumerated().map { index, screen in
            try screenshotStore.store(screen, contextID: contextID, index: index)
        }
        let inkMarks = screens.flatMap(\.inkMarks)
        var warnings: [String] = []
        let browser: PickyBrowserContext?
        if let advancedResult = await advancedBrowserResult {
            browser = advancedResult.value
            warnings.append(contentsOf: advancedResult.warnings)
        } else {
            browser = browserProvider.browserContext()
        }
        let resolvedSelectedTextResult = await selectedTextResult
        warnings.append(contentsOf: resolvedSelectedTextResult.warnings)
        let selectedText = browser?.selectedText ?? resolvedSelectedTextResult.value?.text

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
            inkMarks: inkMarks,
            warnings: warnings
        )
    }
}

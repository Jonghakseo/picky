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

/// Transcript-independent context collected at a single point in time.
/// Voice capture collects this at PTT release so browser and accessibility work
/// can overlap transcription, then attaches the final transcript at submission.
struct PickyContextPacketPreflight {
    let capturedAt: Date
    let activeApp: PickyApplicationContext?
    let activeWindow: PickyWindowContext?
    let browser: PickyBrowserContext?
    let selectedText: String?
    let warnings: [String]
}

/// A complete neutral context packet except for the final user transcript.
struct PickyPreparedContextPacket {
    let id: String
    let source: String
    let capturedAt: Date
    let selectedText: String?
    let cwd: String?
    let activeApp: PickyApplicationContext?
    let activeWindow: PickyWindowContext?
    let browser: PickyBrowserContext?
    let screenshots: [PickyScreenshotContext]
    let inkMarks: [PickyInkMarkContext]
    let warnings: [String]

    func attaching(transcript: String) -> PickyContextPacket {
        PickyContextPacket(
            id: id,
            source: source,
            capturedAt: capturedAt,
            transcript: transcript,
            selectedText: selectedText,
            cwd: cwd,
            activeApp: activeApp,
            activeWindow: activeWindow,
            browser: browser,
            screenshots: screenshots,
            inkMarks: inkMarks,
            warnings: warnings
        )
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

    /// Collects the parts of context that do not require a transcript. This is
    /// intentionally separate from screenshot persistence so voice capture can
    /// begin browser/AX work at PTT release alongside screen capture and STT.
    func capturePreflight() async -> PickyContextPacketPreflight {
        let capturedAt = now()
        let activeApp = appProvider.activeApplicationContext()
        let activeWindow = windowProvider.activeWindowContext()
        let fallbackBrowser = advancedBrowserProvider == nil ? browserProvider.browserContext() : nil
        async let advancedBrowserResult: PickyContextCaptureResult<PickyBrowserContext>? = {
            guard let advancedBrowserProvider else { return nil }
            return await advancedBrowserProvider.browserContextResult()
        }()
        async let selectedTextResult = selectedTextProvider.selectedTextResult()

        var warnings: [String] = []
        let browser: PickyBrowserContext?
        if let advancedResult = await advancedBrowserResult {
            browser = advancedResult.value
            warnings.append(contentsOf: advancedResult.warnings)
        } else {
            browser = fallbackBrowser
        }
        let resolvedSelectedTextResult = await selectedTextResult
        warnings.append(contentsOf: resolvedSelectedTextResult.warnings)
        let browserSelectedText = browser?.selectedText
        let providerSelectedText = resolvedSelectedTextResult.value?.text
        let selectedText = browserSelectedText ?? providerSelectedText
        let selectedTextSource = browserSelectedText != nil
            ? "browser"
            : (providerSelectedText != nil ? "selectedTextProvider" : "none")
        PickyLog.notice(
            .contextCapture,
            prefix: "🧭 Picky context —",
            message: "event=contextPreflightResolved activeBundle=\(activeApp?.bundleId ?? "none") browserSelectedChars=\(browserSelectedText?.count ?? 0) providerSelectedChars=\(providerSelectedText?.count ?? 0) selectedSource=\(selectedTextSource) selectedChars=\(selectedText?.count ?? 0)"
        )

        return PickyContextPacketPreflight(
            capturedAt: capturedAt,
            activeApp: activeApp,
            activeWindow: activeWindow,
            browser: browser,
            selectedText: selectedText,
            warnings: warnings
        )
    }

    /// Persists screen context and joins it with previously collected metadata.
    func prepare(source: String, preflight: PickyContextPacketPreflight) throws -> PickyPreparedContextPacket {
        let contextID = idGenerator()
        let screens = screenProvider.screenContexts()
        let screenshots = try screens.enumerated().map { index, screen in
            try screenshotStore.store(screen, contextID: contextID, index: index)
        }

        return PickyPreparedContextPacket(
            id: contextID,
            source: source,
            capturedAt: preflight.capturedAt,
            selectedText: preflight.selectedText,
            cwd: defaultCwd,
            activeApp: preflight.activeApp,
            activeWindow: preflight.activeWindow,
            browser: preflight.browser,
            screenshots: screenshots,
            inkMarks: screens.flatMap(\.inkMarks),
            warnings: preflight.warnings
        )
    }

    func prepare(source: String) async throws -> PickyPreparedContextPacket {
        try prepare(source: source, preflight: await capturePreflight())
    }

    func assemble(source: String, transcript: String) async throws -> PickyContextPacket {
        try await prepare(source: source).attaching(transcript: transcript)
    }
}

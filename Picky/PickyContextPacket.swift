//
//  PickyContextPacket.swift
//  Picky
//
//  Neutral desktop context models used by the app-to-agent boundary. These
//  structures intentionally describe what the user was doing without routing
//  to any specific workflow or skill.
//

import AppKit
import CoreGraphics
import Foundation

struct PickyContextPacket: Codable, Equatable, Identifiable {
    let id: String
    let source: String
    let capturedAt: Date
    let transcript: String?
    let selectedText: String?
    let cwd: String?
    let activeApp: PickyApplicationContext?
    let activeWindow: PickyWindowContext?
    let browser: PickyBrowserContext?
    let screenshots: [PickyScreenshotContext]
    let warnings: [String]
}

struct PickyApplicationContext: Codable, Equatable {
    let bundleId: String?
    let name: String?
    let pid: Int?
}

struct PickyWindowContext: Codable, Equatable {
    let title: String?
    let frame: PickyCGRect?
}

struct PickyBrowserContext: Codable, Equatable {
    let url: URL?
    let title: String?
    let selectedText: String?
}

struct PickyScreenshotContext: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let path: String
    let screenId: String?
    let bounds: PickyCGRect?
}

struct PickyScreenContext: Equatable {
    let label: String
    let frame: PickyCGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let isCursorScreen: Bool
    let imageData: Data?
}

struct PickyCGRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

protocol PickyApplicationContextProviding {
    func activeApplicationContext() -> PickyApplicationContext?
}

protocol PickyWindowContextProviding {
    func activeWindowContext() -> PickyWindowContext?
}

protocol PickyBrowserContextProviding {
    func browserContext() -> PickyBrowserContext?
}

protocol PickyScreenContextProviding {
    func screenContexts() -> [PickyScreenContext]
}

protocol PickyScreenshotStoring {
    func store(_ screen: PickyScreenContext, contextID: String, index: Int) throws -> PickyScreenshotContext
}

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
                imageData: capture.imageData
            )
        }
    }
}

struct PickyAppSupportScreenshotStore: PickyScreenshotStoring {
    let appSupportRoot: URL
    let fileManager: FileManager

    init(appSupportRoot: URL = PickyAppSupport.defaultRoot(), fileManager: FileManager = .default) {
        self.appSupportRoot = appSupportRoot
        self.fileManager = fileManager
    }

    func store(_ screen: PickyScreenContext, contextID: String, index: Int) throws -> PickyScreenshotContext {
        let directory = appSupportRoot.appendingPathComponent("Screenshots", isDirectory: true)
            .appendingPathComponent(contextID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = "shot-\(index + 1)"
        let fileURL = directory.appendingPathComponent("\(id).jpg")
        if let imageData = screen.imageData {
            try imageData.write(to: fileURL, options: .atomic)
        } else if !fileManager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }

        return PickyScreenshotContext(
            id: id,
            label: screen.label,
            path: fileURL.path,
            screenId: "screen\(index + 1)",
            bounds: screen.frame
        )
    }
}

enum PickyAppSupport {
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Picky", isDirectory: true)
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

//
//  PickyContextPacket.swift
//  Picky
//
//  Neutral desktop context models used by the app-to-agent boundary. These
//  structures intentionally describe what the user was doing without routing
//  to any specific workflow or skill.
//

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
    /// Width of the stored screenshot image in pixels. Used by visual-only
    /// pointer overlays to convert screenshot pixels into display points.
    let screenshotWidthInPixels: Int?
    /// Height of the stored screenshot image in pixels. Used by visual-only
    /// pointer overlays to convert screenshot pixels into display points.
    let screenshotHeightInPixels: Int?
    /// True when this screenshot was captured from the display containing the
    /// physical cursor / primary focus at capture time.
    let isCursorScreen: Bool?
    /// Physical cursor position at capture time, populated only for the cursor
    /// screen. displayPoint and screenshotPixel use top-left origin to match
    /// picky_show_pointer coordinate conventions.
    let cursor: PickyCursorContext?

    init(
        id: String,
        label: String,
        path: String,
        screenId: String?,
        bounds: PickyCGRect?,
        screenshotWidthInPixels: Int? = nil,
        screenshotHeightInPixels: Int? = nil,
        isCursorScreen: Bool? = nil,
        cursor: PickyCursorContext? = nil
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.screenId = screenId
        self.bounds = bounds
        self.screenshotWidthInPixels = screenshotWidthInPixels
        self.screenshotHeightInPixels = screenshotHeightInPixels
        self.isCursorScreen = isCursorScreen
        self.cursor = cursor
    }
}

struct PickyCursorContext: Codable, Equatable {
    /// Global AppKit screen point, bottom-left origin across the desktop.
    let globalPoint: PickyCGPoint
    /// Point relative to the display, top-left origin, in display points.
    let displayPoint: PickyCGPoint
    /// Point relative to the captured screenshot image, top-left origin, in pixels.
    let screenshotPixel: PickyCGPoint
}

struct PickyScreenContext: Equatable {
    let label: String
    let frame: PickyCGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let isCursorScreen: Bool
    let cursor: PickyCursorContext?
    let imageData: Data?
}

struct PickyCGPoint: Codable, Equatable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
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

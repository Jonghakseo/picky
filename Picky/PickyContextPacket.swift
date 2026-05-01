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

struct PickyContextPacket: Codable, Equatable {
    let source: String
    let transcript: String
    let capturedAt: Date
    let activeApplication: PickyApplicationContext?
    let activeWindow: PickyWindowContext?
    let screens: [PickyScreenContext]
    let defaultCwd: String?
}

struct PickyApplicationContext: Codable, Equatable {
    let localizedName: String?
    let bundleIdentifier: String?
    let processIdentifier: Int32?
}

struct PickyWindowContext: Codable, Equatable {
    let title: String?
    let frame: PickyCGRect?
}

struct PickyScreenContext: Codable, Equatable {
    let label: String
    let frame: PickyCGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let isCursorScreen: Bool
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
}

protocol PickyApplicationContextProviding {
    func activeApplicationContext() -> PickyApplicationContext?
}

protocol PickyScreenContextProviding {
    func screenContexts() -> [PickyScreenContext]
}

struct WorkspacePickyApplicationContextProvider: PickyApplicationContextProviding {
    func activeApplicationContext() -> PickyApplicationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PickyApplicationContext(
            localizedName: app.localizedName,
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier
        )
    }
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
                isCursorScreen: capture.isCursorScreen
            )
        }
    }
}

struct PickyContextPacketAssembler {
    let appProvider: PickyApplicationContextProviding
    let screenProvider: PickyScreenContextProviding
    let defaultCwd: String?
    var now: () -> Date = Date.init

    func assemble(source: String, transcript: String) -> PickyContextPacket {
        PickyContextPacket(
            source: source,
            transcript: transcript,
            capturedAt: now(),
            activeApplication: appProvider.activeApplicationContext(),
            activeWindow: nil,
            screens: screenProvider.screenContexts(),
            defaultCwd: defaultCwd
        )
    }
}

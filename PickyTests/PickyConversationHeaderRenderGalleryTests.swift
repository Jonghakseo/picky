//
//  PickyConversationHeaderRenderGalleryTests.swift
//  PickyTests
//
//  Deterministic offscreen renders for the context usage control and its
//  manual-compaction popover content. No NSWindow or NSPanel is created.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyConversationHeaderRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.conversation-context-output-path")
    private static let renderScale: CGFloat = 2

    private enum Appearance: String {
        case dark
        case light

        var nsAppearance: NSAppearance.Name {
            switch self {
            case .dark: .darkAqua
            case .light: .aqua
            }
        }

        var colorScheme: ColorScheme {
            switch self {
            case .dark: .dark
            case .light: .light
            }
        }
    }

    private struct Scene {
        let name: String
        let appearance: Appearance
        let content: AnyView
    }

    private struct Manifest: Encodable {
        let schemaVersion: Int
        let renderer: String
        let scale: Int
        let scenes: [ManifestScene]
    }

    private struct ManifestScene: Encodable {
        let file: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
    }

    @Test func writesConversationContextGalleryWhenOutputDirectoryIsRequested() throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }

        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            var manifestScenes: [ManifestScene] = []
            for scene in makeScenes() {
                let rendered = try render(scene)
                let file = output.appendingPathComponent(scene.name)
                try rendered.png.write(to: file, options: .atomic)
                #expect(NSImage(data: rendered.png) != nil)
                #expect(rendered.bitmap.pixelsWide > 0)
                #expect(rendered.bitmap.pixelsHigh > 0)
                manifestScenes.append(ManifestScene(
                    file: scene.name,
                    logicalWidth: Double(rendered.logicalSize.width),
                    logicalHeight: Double(rendered.logicalSize.height),
                    pixelWidth: rendered.bitmap.pixelsWide,
                    pixelHeight: rendered.bitmap.pixelsHigh,
                    appearance: scene.appearance.rawValue
                ))
            }

            let manifest = Manifest(
                schemaVersion: 1,
                renderer: "offscreen NSHostingView bitmap cache",
                scale: Int(Self.renderScale),
                scenes: manifestScenes
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: output.appendingPathComponent("manifest.json"),
                options: .atomic
            )
        }
    }

    private func makeScenes() -> [Scene] {
        let usage = PickyContextUsage(tokens: 136_000, contextWindow: 200_000, percent: 68)
        let display = PickyHeaderContextUsageDisplay(usage: usage)
        let meta = PickyConversationHeaderMetaPresentation(assistantRun: nil, contextUsage: usage)

        return [
            Scene(
                name: "context-control-ready-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyHeaderSessionMetaPill(
                    presentation: meta,
                    compactionPresentation: .init(status: .completed, lastSummary: "Completed"),
                    onCompact: {}
                ))
            ),
            Scene(
                name: "context-popover-ready-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyHeaderContextCompactionPopoverView(
                    display: display,
                    compactionPresentation: .init(status: .completed, lastSummary: "Completed"),
                    onCompact: {}
                ))
            ),
            Scene(
                name: "context-popover-ready-light-ko.png",
                appearance: .light,
                content: AnyView(PickyHeaderContextCompactionPopoverView(
                    display: display,
                    compactionPresentation: .init(status: .completed, lastSummary: "Completed"),
                    onCompact: {}
                ))
            ),
            Scene(
                name: "context-popover-unavailable-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyHeaderContextCompactionPopoverView(
                    display: display,
                    compactionPresentation: .init(status: .running, lastSummary: "Working"),
                    onCompact: {}
                ))
            ),
            Scene(
                name: "context-popover-compacting-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyHeaderContextCompactionPopoverView(
                    display: display,
                    compactionPresentation: .init(status: .running, lastSummary: "Compacting session…"),
                    onCompact: {}
                ))
            ),
        ]
    }

    private func render(_ scene: Scene) throws -> (
        png: Data,
        bitmap: NSBitmapImageRep,
        logicalSize: CGSize
    ) {
        let fontStore = PickyAppFontScaleStore()
        let measuredRoot = AnyView(
            PickyAppFontScaleRoot(store: fontStore) {
                scene.content
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .fixedSize()
            }
        )
        let measuringHost = NSHostingView(rootView: measuredRoot)
        measuringHost.appearance = NSAppearance(named: scene.appearance.nsAppearance)
        measuringHost.layoutSubtreeIfNeeded()
        let contentSize = measuringHost.fittingSize
        guard contentSize.width > 0, contentSize.height > 0 else {
            throw RenderError.emptyLogicalSize(scene.name)
        }

        let canvasInset = DS.Spacing.space4
        let logicalSize = CGSize(
            width: contentSize.width + canvasInset * 2,
            height: contentSize.height + canvasInset * 2
        )
        let pixelWidth = Int((logicalSize.width * Self.renderScale).rounded(.up))
        let pixelHeight = Int((logicalSize.height * Self.renderScale).rounded(.up))
        let renderedRoot = AnyView(
            PickyAppFontScaleRoot(store: fontStore) {
                scene.content
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .fixedSize()
                    .padding(canvasInset)
                    .scaleEffect(Self.renderScale, anchor: .topLeading)
                    .frame(
                        width: CGFloat(pixelWidth),
                        height: CGFloat(pixelHeight),
                        alignment: .topLeading
                    )
            }
        )
        let host = NSHostingView(rootView: renderedRoot)
        host.appearance = NSAppearance(named: scene.appearance.nsAppearance)
        host.frame = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.bitmapCreationFailed(scene.name)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        host.rootView = AnyView(EmptyView())
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed(scene.name)
        }
        return (png, bitmap, logicalSize)
    }

    private enum RenderError: Error {
        case emptyLogicalSize(String)
        case bitmapCreationFailed(String)
        case pngEncodingFailed(String)
    }
}

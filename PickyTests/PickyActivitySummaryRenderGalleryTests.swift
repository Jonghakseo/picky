//
//  PickyActivitySummaryRenderGalleryTests.swift
//  PickyTests
//
//  Deterministic offscreen renders for collapsed and expanded tool activity.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyActivitySummaryRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.conversation-activity-output-path")
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
        let expanded: Bool
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
        let expanded: Bool
    }

    @Test func writesConversationActivityGalleryWhenOutputDirectoryIsRequested() throws {
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
                    appearance: scene.appearance.rawValue,
                    expanded: scene.expanded
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
        [
            Scene(name: "activity-summary-collapsed-dark-ko.png", appearance: .dark, expanded: false),
            Scene(name: "activity-summary-expanded-dark-ko.png", appearance: .dark, expanded: true),
            Scene(name: "activity-summary-collapsed-light-ko.png", appearance: .light, expanded: false),
            Scene(name: "activity-summary-expanded-light-ko.png", appearance: .light, expanded: true),
        ]
    }

    private func content(for scene: Scene) -> some View {
        PickyActivitySummaryView(
            summary: PickyActivitySummary(
                edit: 1,
                bash: 10,
                read: 6,
                write: 1,
                todo: 4,
                subagent: 2
            ),
            onTap: {},
            initiallyExpanded: scene.expanded
        )
        .frame(width: 420, alignment: .leading)
        .padding(DS.Spacing.space3)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous))
    }

    private func render(_ scene: Scene) throws -> (
        png: Data,
        bitmap: NSBitmapImageRep,
        logicalSize: CGSize
    ) {
        let fontStore = PickyAppFontScaleStore()
        let measuredRoot = AnyView(
            PickyAppFontScaleRoot(store: fontStore) {
                content(for: scene)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .fixedSize(horizontal: false, vertical: true)
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
                content(for: scene)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .fixedSize(horizontal: false, vertical: true)
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

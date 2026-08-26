//
//  PickyHUDDockGroupRenderGalleryTests.swift
//  PickyTests
//
//  Deterministic, offscreen render artifacts for the dock group surfaces.
//  This test never creates an NSWindow or NSPanel. The gallery command writes
//  an ignored output request; ordinary test runs leave no artifacts behind.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupRenderGalleryTests {
    /// xcodebuild does not forward arbitrary shell environment variables to
    /// the XCTest host. The gallery script therefore passes its absolute
    /// output directory through this ignored request file instead.
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.dock-group-output-path")
    private static let renderScale: CGFloat = 2
    private static let referenceDate = Date(timeIntervalSince1970: 1_777_777_777)

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
        let contentLogicalSize: CGSize
        let canvasInsets: EdgeInsets
        let appearance: Appearance
        let preset: PickyHUDDockSizePreset
        let fontScale: CGFloat
        let content: AnyView

        var canvasLogicalSize: CGSize {
            CGSize(
                width: contentLogicalSize.width + canvasInsets.leading + canvasInsets.trailing,
                height: contentLogicalSize.height + canvasInsets.top + canvasInsets.bottom
            )
        }
    }

    private struct Manifest: Encodable {
        let schemaVersion: Int
        let renderer: String
        let scale: Int
        let scenes: [ManifestScene]
    }

    private struct ManifestScene: Encodable {
        let file: String
        let contentLogicalWidth: Double
        let contentLogicalHeight: Double
        let canvasLogicalWidth: Double
        let canvasLogicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
        let dockPreset: String
        let fontScale: Double
    }

    @Test func writesDockGroupGalleryWhenOutputDirectoryIsRequested() throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }

        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scenes = makeScenes()
        var manifestScenes: [ManifestScene] = []

        for scene in scenes {
            let rendered = try render(scene)
            let file = output.appendingPathComponent(scene.name)
            try rendered.png.write(to: file, options: .atomic)
            try verify(rendered, scene: scene)
            manifestScenes.append(ManifestScene(
                file: scene.name,
                contentLogicalWidth: Double(scene.contentLogicalSize.width),
                contentLogicalHeight: Double(scene.contentLogicalSize.height),
                canvasLogicalWidth: Double(scene.canvasLogicalSize.width),
                canvasLogicalHeight: Double(scene.canvasLogicalSize.height),
                pixelWidth: rendered.bitmap.pixelsWide,
                pixelHeight: rendered.bitmap.pixelsHigh,
                appearance: scene.appearance.rawValue,
                dockPreset: scene.preset.rawValue,
                fontScale: Double(scene.fontScale)
            ))
        }

        let manifest = Manifest(
            schemaVersion: 2,
            renderer: "offscreen NSHostingView bitmap cache",
            scale: Int(Self.renderScale),
            scenes: manifestScenes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        try makeIndex(for: manifestScenes).write(
            to: output.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test func panelGeometryIncludesProductionChromeRowsAndSpacing() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                for count in [0, 2, 5] {
                    let panelSize = listSize(memberCount: count, metrics: metrics, fontScale: fontScale)
                    let expected = PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: metrics)
                        + PickyHUDDockGroupListPolicy.rowStackHeight(
                            rowCount: max(1, count),
                            metrics: metrics,
                            fontScale: fontScale
                        )
                    #expect(panelSize.height == expected)
                    #expect(panelSize.width == metrics.groupListPanelWidth)
                }
            }
        }
    }

    @Test func folderGeometryContainsTheProductionHeaderAtAllGalleryScales() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                let size = folderSize(metrics: metrics, fontScale: fontScale)
                let headerHeight = PickyHUDDockGroupHeaderPresentation.labelHeight(
                    metrics: metrics,
                    fontScale: fontScale
                )
                #expect(size.width == PickyHUDDockGroupHeaderPresentation.labelWidth(
                    metrics: metrics,
                    fontScale: fontScale
                ))
                #expect(size.height == metrics.sessionTileHeight + metrics.groupHeaderContentSpacing + headerHeight)
                #expect(headerHeight > metrics.groupHeaderVerticalInset * 2)
            }
        }
    }

    private func makeScenes() -> [Scene] {
        let small = PickyHUDDockMetrics(preset: .small)
        let medium = PickyHUDDockMetrics(preset: .medium)
        let large = PickyHUDDockMetrics(preset: .large)
        let picky = group(id: "group-picky", name: "Picky", color: .blue, memberIDs: fiveRows.map(\.id))
        let research = group(id: "group-research", name: "Research", color: .teal, memberIDs: twoRows.map(\.id))
        let cjk = group(id: "group-cjk", name: "한글그룹", color: .purple, memberIDs: fiveRows.map(\.id))
        let empty = group(id: "group-empty", name: "Empty", color: .gray, memberIDs: [])

        return [
            folderScene("folder-small-dark-100.png", group: picky, members: fiveSessions, metrics: small, fontScale: 1, appearance: .dark),
            folderScene("folder-medium-dark-100.png", group: picky, members: fiveSessions, metrics: medium, fontScale: 1, appearance: .dark),
            folderScene("folder-large-light-100.png", group: picky, members: fiveSessions, metrics: large, fontScale: 1, appearance: .light),
            folderScene("folder-small-dark-130-cjk.png", group: cjk, members: fiveSessions, metrics: small, fontScale: 1.3, appearance: .dark),
            folderScene("folder-empty-small-dark-100.png", group: empty, members: [], metrics: small, fontScale: 1, appearance: .dark),
            listScene("list-five-selected-small-dark-100.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: small, fontScale: 1, appearance: .dark),
            listScene("list-five-selected-medium-dark-100.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: medium, fontScale: 1, appearance: .dark),
            listScene("list-five-selected-large-light-100.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: large, fontScale: 1, appearance: .light),
            listScene("list-five-selected-small-dark-130.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: small, fontScale: 1.3, appearance: .dark),
            listScene("list-two-selected-medium-dark-100.png", group: research, rows: twoRows, selectedID: twoRows[1].id, metrics: medium, fontScale: 1, appearance: .dark),
            listScene("list-empty-medium-dark-100.png", group: empty, rows: [], selectedID: nil, metrics: medium, fontScale: 1, appearance: .dark),
            combinedScene(group: picky, metrics: medium),
        ]
    }

    private func folderScene(
        _ name: String,
        group: PickyDockGroup,
        members: [PickyHUDDockSession],
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        appearance: Appearance
    ) -> Scene {
        Scene(
            name: name,
            contentLogicalSize: folderSize(metrics: metrics, fontScale: fontScale),
            canvasInsets: galleryCanvasInsets,
            appearance: appearance,
            preset: metrics.preset,
            fontScale: fontScale,
            content: AnyView(folder(group: group, members: members, metrics: metrics, fontScale: fontScale))
        )
    }

    private func listScene(
        _ name: String,
        group: PickyDockGroup,
        rows: [PickyHUDDockGroupListRowModel],
        selectedID: String?,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        appearance: Appearance
    ) -> Scene {
        Scene(
            name: name,
            contentLogicalSize: listSize(memberCount: rows.count, metrics: metrics, fontScale: fontScale),
            canvasInsets: galleryCanvasInsets,
            appearance: appearance,
            preset: metrics.preset,
            fontScale: fontScale,
            content: AnyView(list(group: group, rows: rows, selectedID: selectedID, metrics: metrics))
        )
    }

    private func combinedScene(group: PickyDockGroup, metrics: PickyHUDDockMetrics) -> Scene {
        let panelSize = listSize(memberCount: fiveRows.count, metrics: metrics, fontScale: 1)
        let folderFrame = folderSize(metrics: metrics, fontScale: 1)
        return Scene(
            name: "combined-folder-panel-medium-dark-100.png",
            contentLogicalSize: CGSize(
                width: folderFrame.width + PickyHUDDockLayout.panelGap + panelSize.width,
                height: max(folderFrame.height, panelSize.height)
            ),
            canvasInsets: galleryCanvasInsets,
            appearance: .dark,
            preset: metrics.preset,
            fontScale: 1,
            content: AnyView(
                HStack(alignment: .top, spacing: PickyHUDDockLayout.panelGap) {
                    self.folder(group: group, members: fiveSessions, metrics: metrics, fontScale: 1)
                        .frame(width: folderFrame.width, alignment: .center)
                    list(group: group, rows: fiveRows, selectedID: fiveRows[0].id, metrics: metrics)
                }
            )
        )
    }

    private func folder(
        group: PickyDockGroup,
        members: [PickyHUDDockSession],
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> some View {
        PickyHUDDockGroupFolderTileView(
            group: group,
            metrics: metrics,
            fontScale: fontScale
        ) {
            if members.isEmpty {
                PickyHUDDockGroupEmptySlot(color: group.color, metrics: metrics, onCreatePickle: {})
            } else {
                PickyHUDDockCollapsedGroupBadge(
                    members: members,
                    unreadCount: 2,
                    tint: group.color.accent,
                    metrics: metrics,
                    shortcutNumber: 1,
                    isCommandShortcutHintVisible: false,
                    onTap: {},
                    onReorderBegan: {},
                    onReorderChanged: { _ in },
                    onReorderEnded: { _ in }
                )
            }
        } header: { header in
            header
        }
    }

    private func list(
        group: PickyDockGroup,
        rows: [PickyHUDDockGroupListRowModel],
        selectedID: String?,
        metrics: PickyHUDDockMetrics
    ) -> some View {
        PickyHUDDockGroupListView(
            group: group,
            rows: rows,
            unreadSessionIDs: Set(rows.prefix(1).map(\.id)),
            openedSessionID: selectedID,
            highlightedRowID: nil,
            metrics: metrics,
            onSelectSession: { _ in },
            onCreatePickle: {},
            moveTargetGroups: [],
            screenContextTargetSessionID: nil,
            screenContextTargetSticky: false,
            onToggleScreenContextTarget: { _ in },
            onToggleStickyScreenContextTarget: { _ in },
            onCompactSession: { _ in },
            onArchiveSession: { _ in },
            onStopSession: { _ in },
            onMoveSessionToGroup: { _, _ in },
            onUngroupSession: { _ in },
            onReorderSession: { _, _ in },
            relativeTime: { _ in "5 min ago" },
            liveRowIDs: { rows.map(\.id) },
            convertScreenPointToPanel: { $0 }
        )
    }

    private func render(_ scene: Scene) throws -> (png: Data, bitmap: NSBitmapImageRep) {
        let canvasSize = scene.canvasLogicalSize
        let pixelWidth = Int((canvasSize.width * Self.renderScale).rounded(.up))
        let pixelHeight = Int((canvasSize.height * Self.renderScale).rounded(.up))
        let fontStore = PickyAppFontScaleStore()
        fontStore.setScale(Double(scene.fontScale))
        let root = AnyView(
            PickyAppFontScaleRoot(store: fontStore) {
                scene.content
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .frame(
                        width: scene.contentLogicalSize.width,
                        height: scene.contentLogicalSize.height,
                        alignment: .topLeading
                    )
                    .padding(scene.canvasInsets)
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                    .scaleEffect(Self.renderScale, anchor: .topLeading)
                    .frame(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight), alignment: .topLeading)
            }
        )
        let host = NSHostingView(rootView: root)
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
            throw GalleryError.bitmapCreationFailed(scene.name)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        host.rootView = AnyView(EmptyView())
        guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw GalleryError.pngEncodingFailed(scene.name)
        }
        return (png, bitmap)
    }

    private func verify(_ rendered: (png: Data, bitmap: NSBitmapImageRep), scene: Scene) throws {
        let expectedWidth = Int((scene.canvasLogicalSize.width * Self.renderScale).rounded(.up))
        let expectedHeight = Int((scene.canvasLogicalSize.height * Self.renderScale).rounded(.up))
        guard rendered.bitmap.pixelsWide == expectedWidth, rendered.bitmap.pixelsHigh == expectedHeight else {
            throw GalleryError.unexpectedDimensions(scene.name)
        }
        guard !rendered.png.isEmpty, NSImage(data: rendered.png) != nil else {
            throw GalleryError.decodeFailed(scene.name)
        }
        guard rendered.bitmap.bitmapData != nil, hasVisibleContent(rendered.bitmap) else {
            throw GalleryError.emptyContent(scene.name)
        }
        guard !hasVisiblePixelTouchingCanvasEdge(rendered.bitmap) else {
            throw GalleryError.contentTouchesCanvasEdge(scene.name)
        }
    }

    private func hasVisibleContent(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let bytes = bitmap.bitmapData else { return false }
        let alphaOffset = bitmap.samplesPerPixel - 1
        for row in 0..<bitmap.pixelsHigh {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide where bytes[rowStart + (column * bitmap.samplesPerPixel) + alphaOffset] > 0 {
                return true
            }
        }
        return false
    }

    private func hasVisiblePixelTouchingCanvasEdge(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let bytes = bitmap.bitmapData else { return true }
        let alphaOffset = bitmap.samplesPerPixel - 1
        func alpha(atColumn column: Int, row: Int) -> UInt8 {
            bytes[(row * bitmap.bytesPerRow) + (column * bitmap.samplesPerPixel) + alphaOffset]
        }

        for column in 0..<bitmap.pixelsWide {
            if alpha(atColumn: column, row: 0) > 0
                || alpha(atColumn: column, row: bitmap.pixelsHigh - 1) > 0 {
                return true
            }
        }
        for row in 0..<bitmap.pixelsHigh {
            if alpha(atColumn: 0, row: row) > 0
                || alpha(atColumn: bitmap.pixelsWide - 1, row: row) > 0 {
                return true
            }
        }
        return false
    }

    /// The gallery canvas stays transparent around every scene. Its top inset
    /// explicitly covers the production unread badge's 4pt upward offset plus
    /// its 2.5pt shadow bleed, while the remaining sides use `screenMargin` as
    /// neutral review framing. This never changes production tile geometry.
    private var galleryCanvasInsets: EdgeInsets {
        let edgeInset = PickyHUDDockLayout.screenMargin * 2 // space.4 review frame
        return EdgeInsets(
            top: max(edgeInset, PickyHUDDockFolderBadgePresentation.unreadBadgeTopOverflow),
            leading: edgeInset,
            bottom: edgeInset,
            trailing: edgeInset
        )
    }

    private func makeIndex(for scenes: [ManifestScene]) -> String {
        let cards = scenes.map { scene in
            """
            <figure>
              <img src="\(scene.file)" alt="\(scene.file)">
              <figcaption><code>\(scene.file)</code><br>\(scene.dockPreset.uppercased()) · \(scene.appearance) · \(scene.fontScale)x · content \(scene.contentLogicalWidth)×\(scene.contentLogicalHeight)pt, canvas \(scene.canvasLogicalWidth)×\(scene.canvasLogicalHeight)pt</figcaption>
            </figure>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <meta charset="utf-8">
        <title>Picky dock-group render gallery</title>
        <style>
          body { background: #171918; color: #eceeed; font: 13px -apple-system, sans-serif; margin: 24px; }
          main { display: grid; gap: 20px; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); }
          figure { background: #202221; border-radius: 12px; margin: 0; padding: 16px; }
          img { background: #101211; display: block; max-width: 100%; }
          figcaption { color: #adb5b2; line-height: 1.5; margin-top: 12px; }
          code { color: #eceeed; }
        </style>
        <h1>Picky dock-group render gallery</h1>
        <p>Offscreen production SwiftUI components at 2×. See <code>manifest.json</code> for exact geometry.</p>
        <main>\(cards)</main>
        """
    }

    private func folderSize(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGSize {
        CGSize(
            width: PickyHUDDockGroupHeaderPresentation.labelWidth(metrics: metrics, fontScale: fontScale),
            height: metrics.sessionTileHeight
                + metrics.groupHeaderContentSpacing
                + PickyHUDDockGroupHeaderPresentation.labelHeight(metrics: metrics, fontScale: fontScale)
        )
    }

    private func listSize(memberCount: Int, metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGSize {
        PickyHUDDockGroupListPolicy.panelSize(
            memberCount: max(1, memberCount),
            metrics: metrics,
            fontScale: fontScale
        )
    }

    private func group(id: String, name: String, color: PickyDockGroupColor, memberIDs: [String]) -> PickyDockGroup {
        PickyDockGroup(id: id, name: name, color: color, memberSessionIDs: memberIDs)
    }

    private var fiveRows: [PickyHUDDockGroupListRowModel] {
        fiveSessions.enumerated().map { index, session in
            PickyHUDDockGroupListRowModel(
                session: session,
                updatedAt: Self.referenceDate.addingTimeInterval(-Double(index * 60))
            )
        }
    }

    private var twoRows: [PickyHUDDockGroupListRowModel] {
        Array(fiveRows.prefix(2))
    }

    private var fiveSessions: [PickyHUDDockSession] {
        [
            session(id: "pickle-1", title: "Inspect dock density", status: .running, cwd: "/work/picky"),
            session(id: "pickle-2", title: "Answer the product question", status: .waiting_for_input, cwd: "/work/research"),
            session(id: "pickle-3", title: "Render the design gallery", status: .completed, cwd: "/work/picky"),
            session(id: "pickle-4", title: "Review failed integration", status: .failed, cwd: "/work/agentd"),
            session(id: "pickle-5", title: "Queue final report", status: .queued, cwd: "/work/docs"),
        ]
    }

    private func session(id: String, title: String, status: PickySessionStatus, cwd: String) -> PickyHUDDockSession {
        let agentSession = PickyAgentSession(
            id: id,
            title: title,
            status: status,
            cwd: cwd,
            createdAt: Self.referenceDate.addingTimeInterval(-600),
            updatedAt: Self.referenceDate,
            lastSummary: "Deterministic render fixture",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )
        return PickyHUDDockSession(session: PickySessionCard.fromAgentSession(agentSession))
    }

    private enum GalleryError: LocalizedError {
        case bitmapCreationFailed(String)
        case pngEncodingFailed(String)
        case unexpectedDimensions(String)
        case decodeFailed(String)
        case emptyContent(String)
        case contentTouchesCanvasEdge(String)

        var errorDescription: String? {
            switch self {
            case .bitmapCreationFailed(let name): "Unable to create bitmap for \(name)"
            case .pngEncodingFailed(let name): "Unable to encode PNG for \(name)"
            case .unexpectedDimensions(let name): "Unexpected render dimensions for \(name)"
            case .decodeFailed(let name): "PNG did not decode for \(name)"
            case .emptyContent(let name): "Rendered image had no visible content for \(name)"
            case .contentTouchesCanvasEdge(let name): "Rendered content touched the canvas edge for \(name)"
            }
        }
    }
}

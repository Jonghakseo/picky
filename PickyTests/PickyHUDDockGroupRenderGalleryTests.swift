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
@Suite(.serialized)
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
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
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
    }

    @Test func galleryEnglishLocalizationOverridesAndRestoresKoreanLocaleState() throws {
        let localeManager = LocaleManager.shared
        let originalChoice = localeManager.choice
        defer { localeManager.apply(originalChoice) }
        localeManager.apply(.korean)
        #expect(L10n.t("group.list.newPickle.accessibilityLabel") == "그룹에 피클 생성")

        try localeManager.withTemporaryChoiceForTesting(.english) {
            #expect(L10n.t("group.list.newPickle.accessibilityLabel") == "Create Pickle in group")
            let oneMemberScene = try #require(makeScenes().first(where: { $0.name == "list-one-selected-medium-dark-100.png" }))
            try verify(render(oneMemberScene), scene: oneMemberScene)
        }

        #expect(localeManager.choice == .korean)
        #expect(localeManager.effectiveLocale.identifier == "ko")
        #expect(L10n.t("group.list.newPickle.accessibilityLabel") == "그룹에 피클 생성")
    }

    @Test func panelGeometryIncludesProductionChromeRowsAndSpacing() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                for count in [1, 2, 5] {
                    let panelSize = listSize(memberCount: count, metrics: metrics, fontScale: fontScale)
                    let expected = PickyHUDDockGroupListPolicy.panelChromeHeight(metrics: metrics)
                        + PickyHUDDockGroupListPolicy.rowStackHeight(
                            rowCount: count,
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

    @Test func combinedSceneKeepsThePanelAnchoredToTheBadgeBelowTheTitle() {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let folderFrame = folderSize(metrics: metrics, fontScale: 1)
        let panelSize = listSize(memberCount: fiveRows.count, metrics: metrics, fontScale: 1)
        let scene = combinedScene(group: group(id: "group", name: "Picky", color: .blue, memberIDs: fiveRows.map(\.id)), metrics: metrics)

        #expect(scene.contentLogicalSize.width == folderFrame.width + PickyHUDDockLayout.panelGap + panelSize.width)
        #expect(scene.contentLogicalSize.height == max(folderFrame.height, folderBadgeTopInset(metrics: metrics, fontScale: 1) + panelSize.height))
    }

    private func makeScenes() -> [Scene] {
        let small = PickyHUDDockMetrics(preset: .small)
        let medium = PickyHUDDockMetrics(preset: .medium)
        let large = PickyHUDDockMetrics(preset: .large)
        let picky = group(id: "group-picky", name: "Picky", color: .blue, memberIDs: fiveRows.map(\.id))
        let research = group(id: "group-research", name: "Research", color: .teal, memberIDs: twoRows.map(\.id))
        let idleRows = Array(fiveRows.prefix(4))
        let idle = group(id: "group-idle", name: "Idle", color: .gray, memberIDs: idleRows.map(\.id))
        let cjk = group(id: "group-cjk", name: "한글그룹", color: .purple, memberIDs: fiveRows.map(\.id))
        let empty = group(id: "group-empty", name: "Empty", color: .gray, memberIDs: [])

        return [
            folderScene("folder-small-dark-100.png", group: picky, members: fiveSessions, metrics: small, fontScale: 1, appearance: .dark),
            folderScene("folder-medium-dark-100.png", group: picky, members: fiveSessions, metrics: medium, fontScale: 1, appearance: .dark),
            folderScene("folder-large-light-100.png", group: picky, members: fiveSessions, metrics: large, fontScale: 1, appearance: .light),
            folderScene("folder-selected-medium-dark-100.png", group: picky, members: fiveSessions, metrics: medium, fontScale: 1, appearance: .dark, isSelected: true),
            folderScene("folder-selected-large-light-100.png", group: picky, members: fiveSessions, metrics: large, fontScale: 1, appearance: .light, isSelected: true),
            folderScene("folder-targeted-medium-dark-100.png", group: picky, members: fiveSessions, metrics: medium, fontScale: 1, appearance: .dark, isDropTargeted: true),
            folderScene("folder-small-dark-130-cjk.png", group: cjk, members: fiveSessions, metrics: small, fontScale: 1.3, appearance: .dark),
            folderScene("folder-empty-small-dark-100.png", group: empty, members: [], metrics: small, fontScale: 1, appearance: .dark),
            folderScene("folder-empty-targeted-large-light-100.png", group: empty, members: [], metrics: large, fontScale: 1, appearance: .light, isDropTargeted: true),
            listScene("list-five-selected-small-dark-100.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: small, fontScale: 1, appearance: .dark),
            listScene("list-five-selected-medium-dark-100.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: medium, fontScale: 1, appearance: .dark),
            listScene("list-five-selected-large-light-100.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: large, fontScale: 1, appearance: .light),
            listScene("list-five-selected-small-dark-130.png", group: picky, rows: fiveRows, selectedID: fiveRows[0].id, metrics: small, fontScale: 1.3, appearance: .dark),
            listScene("list-four-idle-medium-dark-100.png", group: idle, rows: idleRows, selectedID: nil, metrics: medium, fontScale: 1, appearance: .dark),
            listScene(
                "list-five-highlighted-small-dark-130.png",
                group: picky,
                rows: fiveRows,
                selectedID: nil,
                highlightedID: fiveRows[0].id,
                metrics: small,
                fontScale: 1.3,
                appearance: .dark
            ),
            listScene("list-two-selected-medium-dark-100.png", group: research, rows: twoRows, selectedID: twoRows[1].id, metrics: medium, fontScale: 1, appearance: .dark),
            listScene("list-one-selected-medium-dark-100.png", group: group(id: "group-one", name: "Solo", color: .blue, memberIDs: [fiveRows[0].id]), rows: [fiveRows[0]], selectedID: fiveRows[0].id, metrics: medium, fontScale: 1, appearance: .dark),
            combinedScene(group: picky, metrics: medium),
            externalDragFeedbackScene(metrics: medium),
            externalTopLevelProjectionScene(metrics: large),
        ]
    }

    private func folderScene(
        _ name: String,
        group: PickyDockGroup,
        members: [PickyHUDDockSession],
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        appearance: Appearance,
        isSelected: Bool = false,
        isDropTargeted: Bool = false
    ) -> Scene {
        Scene(
            name: name,
            contentLogicalSize: folderSize(
                metrics: metrics,
                fontScale: fontScale,
                tileHeight: members.isEmpty ? metrics.emptyGroupSlotHeight : metrics.sessionTileHeight
            ),
            canvasInsets: galleryCanvasInsets,
            appearance: appearance,
            preset: metrics.preset,
            fontScale: fontScale,
            content: AnyView(folder(
                group: group,
                members: members,
                metrics: metrics,
                fontScale: fontScale,
                isSelected: isSelected,
                isDropTargeted: isDropTargeted
            ))
        )
    }

    private func listScene(
        _ name: String,
        group: PickyDockGroup,
        rows: [PickyHUDDockGroupListRowModel],
        selectedID: String?,
        highlightedID: String? = nil,
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
            content: AnyView(
                list(
                    group: group,
                    rows: rows,
                    selectedID: selectedID,
                    highlightedID: highlightedID,
                    metrics: metrics
                )
            )
        )
    }

    private func combinedScene(group: PickyDockGroup, metrics: PickyHUDDockMetrics) -> Scene {
        let panelSize = listSize(memberCount: fiveRows.count, metrics: metrics, fontScale: 1)
        let folderFrame = folderSize(metrics: metrics, fontScale: 1)
        let badgeTopInset = folderBadgeTopInset(metrics: metrics, fontScale: 1)
        return Scene(
            name: "combined-folder-panel-medium-dark-100.png",
            contentLogicalSize: CGSize(
                width: folderFrame.width + PickyHUDDockLayout.panelGap + panelSize.width,
                height: max(folderFrame.height, badgeTopInset + panelSize.height)
            ),
            canvasInsets: galleryCanvasInsets,
            appearance: .dark,
            preset: metrics.preset,
            fontScale: 1,
            content: AnyView(
                ZStack(alignment: .topLeading) {
                    self.folder(
                        group: group,
                        members: fiveSessions,
                        metrics: metrics,
                        fontScale: 1,
                        isSelected: true
                    )
                        .frame(
                            width: folderFrame.width,
                            height: folderFrame.height,
                            alignment: .top
                        )
                    list(group: group, rows: fiveRows, selectedID: fiveRows[0].id, metrics: metrics)
                        .frame(
                            width: panelSize.width,
                            height: panelSize.height,
                            alignment: .topLeading
                        )
                        .offset(
                            x: folderFrame.width + PickyHUDDockLayout.panelGap,
                            y: badgeTopInset
                        )
                }
            )
        )
    }

    /// One scene captures the external-drag handoff as users see it: the
    /// source list retains a 35% ghost, the target folder alone advertises
    /// acceptance, and a separate invalid detached preview has no destination.
    private func externalDragFeedbackScene(metrics: PickyHUDDockMetrics) -> Scene {
        let source = group(id: "external-source", name: "Source", color: .blue, memberIDs: fiveRows.map(\.id))
        let target = group(id: "external-target", name: "Target", color: .teal, memberIDs: [])
        let layout = PickyDockLayout(entries: [.group(source), .group(target)])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: fiveSessions.map(\.id))
        let presentationStore = PickyHUDDockExternalDragRailPresentationStore()
        presentationStore.show(
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionID: fiveRows[0].id,
            destination: .group(id: target.id, memberIndex: 0)
        )
        let panelSize = listSize(memberCount: fiveRows.count, metrics: metrics, fontScale: 1)
        let railSize = CGSize(
            width: PickyHUDDockRailLayoutPolicy.verticalCrossSize(groupCount: 2, metrics: metrics, fontScale: 1),
            height: PickyHUDDockRailLayoutPolicy.contentLength(
                sessionCount: projection.slots.count,
                groupCount: 2,
                isAddSlotExpanded: false,
                dockSide: .right,
                metrics: metrics,
                fontScale: 1
            )
        )
        // The production preview scales and shadows its icon beyond the tile
        // frame. Reserve a neutral gallery cell so that intentional elevation
        // cannot be mistaken for clipping at the transparent canvas edge.
        let previewSize = CGSize(
            width: metrics.sessionTileWidth + (DS.Spacing.space4 * 2),
            height: metrics.sessionTileHeight + (DS.Spacing.space4 * 2)
        )
        return Scene(
            name: "external-drag-feedback-medium-dark-100.png",
            contentLogicalSize: CGSize(
                width: panelSize.width + DS.Spacing.space4 + railSize.width + DS.Spacing.space4 + previewSize.width,
                height: max(panelSize.height, max(railSize.height, previewSize.height))
            ),
            canvasInsets: externalDragGalleryCanvasInsets,
            appearance: .dark,
            preset: metrics.preset,
            fontScale: 1,
            content: AnyView(
                HStack(alignment: .top, spacing: DS.Spacing.space4) {
                    list(
                        group: source,
                        rows: fiveRows,
                        selectedID: fiveRows[0].id,
                        metrics: metrics,
                        externalDragPresentationStore: presentationStore
                    )
                    .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
                    dockRail(
                        sessions: fiveSessions,
                        allSessions: fiveSessions,
                        layout: layout,
                        projection: projection,
                        dockSide: .right,
                        metrics: metrics,
                        availableRailLength: railSize.height,
                        externalDragPresentationStore: presentationStore
                    )
                    .frame(width: railSize.width, height: railSize.height, alignment: .topLeading)
                    PickyHUDDockExternalDragPreviewContent(
                        session: fiveRows[0].session,
                        dockSide: .right,
                        metrics: metrics,
                        destination: nil
                    )
                    .frame(width: previewSize.width, height: previewSize.height, alignment: .topLeading)
                }
            )
        )
    }

    /// The rail store drives the real external projection path, which injects
    /// a formerly grouped Pickle into the top-level rail and leaves a visible
    /// insertion position before persistence occurs.
    private func externalTopLevelProjectionScene(metrics: PickyHUDDockMetrics) -> Scene {
        let source = group(id: "projection-source", name: "Source", color: .purple, memberIDs: [fiveRows[0].id])
        let target = group(id: "projection-target", name: "Review", color: .amber, memberIDs: twoRows.map(\.id))
        let looseSession = fiveSessions[4]
        let layout = PickyDockLayout(entries: [.group(source), .group(target), .session(id: looseSession.id)])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: fiveSessions.map(\.id))
        let presentationStore = PickyHUDDockExternalDragRailPresentationStore()
        presentationStore.show(
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sessionID: fiveRows[0].id,
            destination: .topLevel(index: 1)
        )
        let contentSize = CGSize(width: 460, height: 130)
        return Scene(
            name: "external-drag-top-level-large-light-130.png",
            contentLogicalSize: contentSize,
            canvasInsets: externalDragGalleryCanvasInsets,
            appearance: .light,
            preset: metrics.preset,
            fontScale: 1.3,
            content: AnyView(
                dockRail(
                    sessions: fiveSessions,
                    allSessions: fiveSessions,
                    layout: layout,
                    projection: projection,
                    dockSide: .bottom,
                    metrics: metrics,
                    availableRailLength: contentSize.width,
                    externalDragPresentationStore: presentationStore
                )
                .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            )
        )
    }

    private func folder(
        group: PickyDockGroup,
        members: [PickyHUDDockSession],
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        isSelected: Bool = false,
        isDropTargeted: Bool = false
    ) -> some View {
        PickyHUDDockGroupFolderTileView(
            group: group,
            metrics: metrics,
            fontScale: fontScale
        ) {
            if members.isEmpty {
                PickyHUDDockGroupEmptySlot(
                    color: group.color,
                    metrics: metrics,
                    isDropTargeted: isDropTargeted,
                    onCreatePickle: {}
                )
            } else {
                PickyHUDDockCollapsedGroupBadge(
                    members: members,
                    unreadCount: 2,
                    tint: group.color.accent,
                    metrics: metrics,
                    shortcutNumber: 1,
                    isCommandShortcutHintVisible: false,
                    isSelected: isSelected,
                    isDropTargeted: isDropTargeted,
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
        highlightedID: String? = nil,
        metrics: PickyHUDDockMetrics,
        externalDragPresentationStore: PickyHUDDockExternalDragRailPresentationStore? = nil
    ) -> some View {
        let presentationStore = externalDragPresentationStore ?? PickyHUDDockExternalDragRailPresentationStore()
        return PickyHUDDockGroupListView(
            group: group,
            rows: rows,
            unreadSessionIDs: Set(rows.prefix(1).map(\.id)),
            openedSessionID: selectedID,
            highlightedRowID: highlightedID,
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
            convertScreenPointToPanel: { $0 },
            externalDragPresentationStore: presentationStore
        )
    }

    private func dockRail(
        sessions: [PickyHUDDockSession],
        allSessions: [PickyHUDDockSession],
        layout: PickyDockLayout,
        projection: PickyDockProjection,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        availableRailLength: CGFloat,
        externalDragPresentationStore: PickyHUDDockExternalDragRailPresentationStore
    ) -> some View {
        PickyHUDDockRailView(
            sessions: sessions,
            allSessions: allSessions,
            baseProjection: projection,
            layout: layout,
            activeSessionID: nil,
            openedSessionID: nil,
            previewSessionID: nil,
            screenContextTargetSessionID: nil,
            screenContextTargetSticky: false,
            dockSide: dockSide,
            isCommandShortcutHintVisible: false,
            pendingDoneFlashSessionIDs: [],
            unreadSessionIDs: [],
            metrics: metrics,
            availableRailLength: availableRailLength,
            onHoverSession: { _ in },
            onOpenSession: { _ in },
            onToggleScreenContextTarget: { _ in },
            onToggleStickyScreenContextTarget: { _ in },
            onCompactSession: { _ in },
            onArchiveSession: { _ in },
            onStopSession: { _ in },
            onCreatePickle: { _ in },
            pinnedPickleCwds: [],
            recentPickleCwds: [],
            onCreatePickleInRecentFolder: { _, _ in },
            onRemoveRecentPickleFolder: { _ in },
            onPinPickleFolder: { _ in },
            onUnpinPickleFolder: { _ in },
            onReorderPinnedPickleFolders: { _ in },
            onCreateDockGroup: { _, _ in "render-gallery-group" },
            onRenameDockGroup: { _, _ in },
            onSetDockGroupColor: { _, _ in },
            onActivateDockGroup: { _ in },
            onRemoveDockGroup: { _, _ in },
            onMoveSessionInDock: { _, _ in },
            onMoveDockGroup: { _, _ in },
            pendingPickleFolderPickerRequest: nil,
            onPickleFolderPickerPresentationAcknowledged: { _ in },
            onDockHoverChanged: { _ in },
            onAddSlotExpandedChanged: { _ in },
            onDoneFlashConsumed: { _ in },
            onDockHandleDragChanged: { _ in },
            onDockHandleDragEnded: {},
            onDockHandleDoubleClick: {},
            externalDragPresentationStore: externalDragPresentationStore
        )
    }

    private func render(_ scene: Scene) throws -> (png: Data, bitmap: NSBitmapImageRep) {
        let canvasSize = scene.canvasLogicalSize
        let pixelWidth = Int((canvasSize.width * Self.renderScale).rounded(.up))
        let pixelHeight = Int((canvasSize.height * Self.renderScale).rounded(.up))
        // Pixel-aligned canvas so the renderer emits exactly the expected pixel grid.
        let renderSize = CGSize(
            width: CGFloat(pixelWidth) / Self.renderScale,
            height: CGFloat(pixelHeight) / Self.renderScale
        )
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
                    .frame(width: renderSize.width, height: renderSize.height, alignment: .topLeading)
            }
        )
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            root,
            logicalSize: renderSize,
            scale: Self.renderScale,
            appearance: scene.appearance.nsAppearance
        ) else {
            throw GalleryError.bitmapCreationFailed(scene.name)
        }
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

    /// The production rail and detached preview use dragging elevation. Give
    /// those two scenes one extra `space.4` above the content so their real
    /// shadow remains inspectable instead of touching the transparent edge.
    private var externalDragGalleryCanvasInsets: EdgeInsets {
        EdgeInsets(
            top: galleryCanvasInsets.top + DS.Spacing.space4,
            leading: galleryCanvasInsets.leading,
            bottom: galleryCanvasInsets.bottom,
            trailing: galleryCanvasInsets.trailing
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

    private func folderSize(
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        tileHeight: CGFloat? = nil
    ) -> CGSize {
        CGSize(
            width: PickyHUDDockGroupHeaderPresentation.labelWidth(metrics: metrics, fontScale: fontScale),
            height: (tileHeight ?? metrics.sessionTileHeight)
                + metrics.groupHeaderContentSpacing
                + PickyHUDDockGroupHeaderPresentation.labelHeight(metrics: metrics, fontScale: fontScale)
        )
    }

    private func folderBadgeTopInset(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        PickyHUDDockGroupHeaderPresentation.labelHeight(metrics: metrics, fontScale: fontScale)
            + metrics.groupHeaderContentSpacing
    }

    private func listSize(memberCount: Int, metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGSize {
        PickyHUDDockGroupListPolicy.panelSize(
            memberCount: memberCount,
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

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHUDDockChromeTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func utilityHoverAndGroupMembershipLeaveTheRenderedRailFootprintUnchanged() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for side: PickyHUDDockSide in [.right, .bottom] {
                let full = NSHostingView(rootView: fixture(side: side, metrics: metrics, emptyGroup: false))
                let empty = NSHostingView(rootView: fixture(side: side, metrics: metrics, emptyGroup: true))
                #expect(full.fittingSize == empty.fittingSize)
                let before = PickyHUDDockRailLayoutPolicy.contentLength(sessionCount: 3, groupCount: 1,
                    isAddSlotExpanded: false, dockSide: side, metrics: metrics, hasArchiveAccess: true)
                let after = PickyHUDDockRailLayoutPolicy.contentLength(sessionCount: 3, groupCount: 1,
                    isAddSlotExpanded: true, dockSide: side, metrics: metrics, hasArchiveAccess: true)
                #expect(before == after)
                let renderedLength = side.orientation == .horizontal ? full.fittingSize.width : full.fittingSize.height
                #expect(abs(renderedLength - before) < 1)
            }
        }
    }

    @Test func renderedHandleKeepsTheApprovedThinGripAtEveryDockSize() throws {
        for preset in PickyHUDDockSizePreset.allCases {
            for side: PickyHUDDockSide in [.right, .bottom] {
                let horizontal = side.orientation == .horizontal
                let view = PickyHUDDockHandleNotch(dockSide: side,
                    metrics: PickyHUDDockMetrics(preset: preset)).environment(\.colorScheme, .light)
                let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                    logicalSize: horizontal ? CGSize(width: 11, height: 34) : CGSize(width: 34, height: 11),
                    scale: 2, appearance: .aqua))
                var gripPixels: [CGPoint] = []
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.alphaComponent > 0.8,
                              max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65 else { continue }
                        gripPixels.append(CGPoint(x: x, y: y))
                    }
                }
                let width = try #require(gripPixels.map(\.x).max()) - #require(gripPixels.map(\.x).min()) + 1
                let height = try #require(gripPixels.map(\.y).max()) - #require(gripPixels.map(\.y).min()) + 1
                // The approved 15 x 2.5pt capsule at 2x, allowing antialiasing at its edges.
                #expect(abs((horizontal ? height : width) - 30) <= 2)
                #expect(abs((horizontal ? width : height) - 5) <= 1)
            }
        }
    }

    @Test func minimizedDockRendersOnlyA32PointRestoreControl() {
        let host = NSHostingView(rootView: PickyHUDDockMinimizedButton(onRestore: {}))
        #expect(host.fittingSize == CGSize(width: 32, height: 32))
    }

    @Test func rendersActualDockCasesWhenRequested() throws {
        let request = Self.root.appendingPathComponent("build/render-gallery/.dock-chrome-output-path")
        guard let path = try? String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String] = []
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            for preset in PickyHUDDockSizePreset.allCases {
                let metrics = PickyHUDDockMetrics(preset: preset)
                for dark in [false, true] {
                    for side: PickyHUDDockSide in [.right, .bottom] {
                        for state in ["group", "empty-group", "empty-dock", "overflow"] {
                            let view = fixture(side: side, metrics: metrics, emptyGroup: state == "empty-group",
                                               emptyDock: state == "empty-dock", overflow: state == "overflow")
                            let host = NSHostingView(rootView: view)
                            let size = host.fittingSize
                            let canvas = CGSize(width: ceil(size.width) + 40, height: ceil(size.height) + 40)
                            let content = view.padding(20).environment(\.colorScheme, dark ? .dark : .light)
                            let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(content,
                                logicalSize: canvas, scale: 2, appearance: dark ? .darkAqua : .aqua))
                            let png = try #require(bitmap.representation(using: .png, properties: [:]))
                            let name = "\(preset.rawValue)-\(dark ? "dark" : "light")-\(side.orientation == .horizontal ? "horizontal" : "vertical")-\(state).png"
                            try png.write(to: directory.appendingPathComponent(name))
                            #expect(NSImage(data: png) != nil)
                            files.append(name)
                        }
                    }
                }
            }
            // The live HUD panel is transparent, so the shell must read the same over any wallpaper.
            let metrics = PickyHUDDockMetrics(preset: .medium)
            for dark in [false, true] {
                for blackBackdrop in [false, true] {
                    let view = fixture(side: .right, metrics: metrics)
                    let size = NSHostingView(rootView: view).fittingSize
                    let canvas = CGSize(width: ceil(size.width) + 40, height: ceil(size.height) + 40)
                    let content = view.padding(20)
                        .background(blackBackdrop ? Color.black : Color.white)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(content,
                        logicalSize: canvas, scale: 2, appearance: dark ? .darkAqua : .aqua))
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "backdrop-\(dark ? "dark" : "light")-\(blackBackdrop ? "black" : "white").png"
                    try png.write(to: directory.appendingPathComponent(name)); files.append(name)
                }
            }
            for dark in [false, true] {
                let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(
                    PickyHUDDockMinimizedButton(onRestore: {}).padding(20).environment(\.colorScheme, dark ? .dark : .light),
                    logicalSize: CGSize(width: 72, height: 72), scale: 2, appearance: dark ? .darkAqua : .aqua))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "minimized-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(name)); files.append(name)
            }
        }
        try JSONEncoder().encode(files).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(files.count == 54)
    }

    private func fixture(side: PickyHUDDockSide, metrics: PickyHUDDockMetrics,
                         emptyGroup: Bool = false, emptyDock: Bool = false, overflow: Bool = false) -> some View {
        let sessions = emptyGroup
            ? [session("a", .running), session("d", .failed)]
            : [session("a", .running), session("b", .waiting_for_input), session("c", .completed), session("d", .failed)]
        let group = PickyDockGroup(id: "group", name: "제품 디자인 검토", color: .gray,
                                   memberSessionIDs: emptyGroup ? [] : ["b", "c"])
        let layout = PickyDockLayout(entries: emptyDock ? [] : [.session(id: "a"), .group(group), .session(id: "d")])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: sessions.map(\.id))
        let archive = EmptyArchive()
        return dockRail(sessions: emptyDock ? [] : sessions, allSessions: emptyDock ? [] : sessions,
                        layout: layout, projection: projection, dockSide: side, metrics: metrics,
                        availableRailLength: overflow ? 150 : 800,
                        externalDragPresentationStore: PickyHUDDockExternalDragRailPresentationStore(),
                        archiveAccess: PickyHUDArchivedSessionAccess(membership: archive, commands: archive))
    }

    private func session(_ id: String, _ status: PickySessionStatus) -> PickyHUDDockSession {
        PickyHUDDockSession(session: PickySessionCard.fromAgentSession(PickyAgentSession(
            id: id, title: "피클 \(id)", status: status, cwd: "/fixture", createdAt: Date(timeIntervalSince1970: 1_777_777_777),
            updatedAt: Date(timeIntervalSince1970: 1_777_777_777), lastSummary: "Fixture", logs: [], tools: [], artifacts: [], changedFiles: [])))
    }

    private final class EmptyArchive: PickySessionArchiveMembership, PickySessionArchiveCommands {
        var archivedSessionIDs: [String] { [] }
        func existingSessionStore(sessionID: String) -> PickySessionStore? { nil }
        func unarchive(sessionID: String) {}
        func deleteArchivedSession(sessionID: String) {}
        func deleteArchivedSession(sessionID: String, onFailure: @escaping @MainActor (Error) -> Void) {}
        func deleteAllArchivedSessions() {}
        func deleteAllArchivedSessions(onFailure: @escaping @MainActor (Error) -> Void) {}
        func stopArchivedAsyncWork(sessionID: String) async throws {}
    }

    private func dockRail(
        sessions: [PickyHUDDockSession],
        allSessions: [PickyHUDDockSession],
        layout: PickyDockLayout,
        projection: PickyDockProjection,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        availableRailLength: CGFloat,
        externalDragPresentationStore: PickyHUDDockExternalDragRailPresentationStore,
        openedSessionID: String? = nil,
        archiveAccess: PickyHUDArchivedSessionAccess? = nil
    ) -> some View {
        PickyHUDDockRailView(
            sessions: sessions,
            allSessions: allSessions,
            baseProjection: projection,
            layout: layout,
            activeSessionID: nil,
            openedSessionID: openedSessionID,
            previewSessionID: nil,
            screenContextTargetSessionID: nil,
            screenContextTargetSticky: false,
            dockSide: dockSide,
            isCommandShortcutHintVisible: false,
            pendingDoneFlashSessionIDs: [],
            unreadSessionIDs: [],
            metrics: metrics,
            availableRailLength: availableRailLength,
            onHoverSession: { _, _ in },
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
            onActivateDockGroupFromKeyboard: { _ in },
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
            externalDragPresentationStore: externalDragPresentationStore,
            archiveAccess: archiveAccess
        )
    }

}

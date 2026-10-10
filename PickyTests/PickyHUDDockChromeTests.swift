import AppKit
import Combine
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHUDDockChromeTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtureAvailableLength: CGFloat = 800
    /// Tight enough that every preset has to scroll. A horizontal rail needs a
    /// larger budget because its chips run along the long axis.
    private static let fixtureVerticalOverflowAvailableLength: CGFloat = 110
    private static let fixtureHorizontalOverflowAvailableLength: CGFloat = 220

    /// Panel placement sizes the HUD from the layout policy before SwiftUI
    /// measures anything, so the rendered rail must match it exactly.
    @Test func renderedRailMatchesThePlacementPolicyForEveryPresetAndGroupState() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for side: PickyHUDDockSide in [.right, .bottom] {
                for state in FixtureState.allCases {
                    let data = fixtureData(state: state)
                    let host = NSHostingView(rootView: fixture(side: side, metrics: metrics, state: state))
                    let expectedLength = PickyHUDDockOverflowPolicy.layout(
                        contentLength: PickyHUDDockRailLayoutPolicy.contentLength(
                            projection: data.projection,
                            activeSessionIDs: Set(data.sessions.map(\.id)),
                            dockSide: side,
                            metrics: metrics,
                            fontScale: 1
                        ),
                        availableLength: Self.availableRailLength(for: state, side: side),
                        fixedChromeLength: PickyHUDDockRailLayoutPolicy.fixedChromeLength(
                            dockSide: side, metrics: metrics, hasDockAddUtility: !data.projection.items.isEmpty
                        )
                    ).railLength
                    let expectedCross = PickyHUDDockRailLayoutPolicy.crossSize(dockSide: side, metrics: metrics, fontScale: 1)
                    let size = host.fittingSize
                    let renderedLength = side.orientation == .horizontal ? size.width : size.height
                    let renderedCross = side.orientation == .horizontal ? size.height : size.width
                    #expect(abs(renderedLength - expectedLength) < 1, "\(preset) \(side) \(state)")
                    #expect(abs(renderedCross - expectedCross) < 1, "\(preset) \(side) \(state)")
                    if state == .emptyDock {
                        // Independent of the list policy: an empty dock still
                        // renders its `+` at one row's size, so the rail cannot
                        // collapse onto the chrome alone.
                        let oneEntry = side.orientation == .horizontal
                            ? metrics.horizontalCompactCellSide(fontScale: 1)
                            : metrics.rowHeight(fontScale: 1)
                        let minimumLength = PickyHUDDockRailLayoutPolicy.fixedChromeLength(
                            dockSide: side, metrics: metrics, hasDockAddUtility: false
                        ) + oneEntry
                        #expect(renderedLength >= minimumLength - 1, "\(preset) \(side) empty dock")
                    }
                }
            }
        }
    }

    @Test func compactRailReservesPresetWidthButOnlyVisibleChromeClaimsDesktopInput() throws {
        final class Frames { var values: [CGRect] = [] }
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for side: PickyHUDDockSide in [.left, .right] {
                for expanded in [false, true] {
                    let frames = Frames()
                    let controller = PickyHUDDockExpansionController()
                    controller.update(pointerInside: false, heldOpen: expanded)
                    let state: FixtureState = expanded ? .attention : .expandedGroup
                    let data = fixtureData(state: state)
                    let view = PickyHUDDockMinimizedPresentation(
                        isLoading: false, isMinimized: false, dockSide: side, metrics: metrics,
                        projection: data.projection, activeSessionIDs: Set(data.sessions.map(\.id)),
                        availableRailLength: Self.fixtureAvailableLength,
                        activeSessionID: expanded ? "a" : nil, onRestore: {}
                    ) { fixture(side: side, metrics: metrics, state: state, expansion: controller) }
                        .padding(20)
                        .coordinateSpace(name: PickyHUDVisibleChromeCoordinateSpaceName)
                        .onPreferenceChange(PickyHUDVisibleChromeFramePreferenceKey.self) { frames.values = $0 }
                    let size = NSHostingView(rootView: view).fittingSize
                    #expect(size.width == metrics.listWidth + 40)
                    #expect(PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size,
                        scale: 2, appearance: .aqua) != nil)
                    let shell = try #require(frames.values.count == 1 ? frames.values.first : nil)
                    #expect(shell.width == (expanded ? metrics.listWidth : 36))
                    let expectedX: CGFloat = side == .right && !expanded ? 20 + metrics.listWidth - 36 : 20
                    #expect(shell.minX == expectedX)
                    let panel = CGRect(origin: .zero, size: size)
                    let namePoint = CGPoint(x: side == .right ? 21 : metrics.listWidth + 19,
                                            y: size.height - shell.midY)
                    #expect(PickyHUDInkPassThroughPolicy.contains(namePoint,
                        swiftUIFrames: frames.values, panelFrame: panel) == expanded)
                    let iconPoint = CGPoint(x: side == .right ? metrics.listWidth + 2 : 38,
                                            y: size.height - shell.midY)
                    #expect(PickyHUDInkPassThroughPolicy.contains(iconPoint,
                        swiftUIFrames: frames.values, panelFrame: panel))
                    controller.stop()
                }
            }
        }
    }

    @Test func pointerExitCollapsesTheRenderedRailWhileItsControlsRemainActive() async throws {
        final class Frames { var values: [CGRect] = [] }
        let frames = Frames()
        let controller = PickyHUDDockExpansionController()
        let view = fixture(side: .right, metrics: .medium, state: .expandedGroup, expansion: controller)
            .environment(\.controlActiveState, .key)
            .transaction { $0.disablesAnimations = true }
            .coordinateSpace(name: PickyHUDVisibleChromeCoordinateSpaceName)
            .onPreferenceChange(PickyHUDVisibleChromeFramePreferenceKey.self) { frames.values = $0 }
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        defer {
            controller.stop()
            host.rootView = AnyView(EmptyView())
        }

        controller.update(pointerInside: true, heldOpen: false)
        try await withPickyTestTimeout("rendered dock expands after hover") {
            for await expanded in controller.$isExpanded.values {
                if expanded { return }
            }
        }
        host.layoutSubtreeIfNeeded()
        #expect(frames.values.first?.width == 168)

        controller.update(pointerInside: false, heldOpen: false)
        try await withPickyTestTimeout("rendered dock collapses without resigning focus") {
            for await expanded in controller.$isExpanded.values {
                if !expanded { return }
            }
        }
        host.layoutSubtreeIfNeeded()
        #expect(frames.values.first?.width == 36)
        #expect(host.frame.width == 168)
    }

    @Test func horizontalPreviewKeepsEveryIconFixedAndOnlyVisibleChromeClaimsInput() throws {
        final class Frames {
            var chrome: [CGRect] = []
            var icons: [String: CGPoint] = [:]
        }
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            let cell = metrics.horizontalCompactCellSide(fontScale: 1)
            let reserved = cell + metrics.horizontalPreviewHeight(fontScale: 1)
            for side: PickyHUDDockSide in [.top, .bottom] {
                var restingIcons: [String: CGPoint] = [:]
                for expanded in [false, true] {
                    let frames = Frames()
                    let state: FixtureState = expanded ? .attention : .expandedGroup
                    let data = fixtureData(state: state)
                    let view = PickyHUDDockMinimizedPresentation(
                        isLoading: false, isMinimized: false, dockSide: side, metrics: metrics,
                        projection: data.projection, activeSessionIDs: Set(data.sessions.map(\.id)),
                        availableRailLength: Self.fixtureAvailableLength,
                        activeSessionID: expanded ? "a" : nil, onRestore: {}
                    ) { fixture(side: side, metrics: metrics, state: state) }
                        .padding(20)
                        .coordinateSpace(name: PickyHUDVisibleChromeCoordinateSpaceName)
                        .onPreferenceChange(PickyHUDVisibleChromeFramePreferenceKey.self) { frames.chrome = $0 }
                        .onPreferenceChange(PickyDockSlotCenterPreferenceKey.self) { frames.icons = $0 }
                    let size = NSHostingView(rootView: view).fittingSize
                    #expect(size.height == reserved + 40)
                    #expect(PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size,
                        scale: 2, appearance: .aqua) != nil)
                    let shell = try #require(frames.chrome.count == 1 ? frames.chrome.first : nil)
                    #expect(shell.height == (expanded ? reserved : cell))
                    #expect(shell.minY == (side == .bottom && !expanded ? 20 + reserved - cell : 20))
                    #expect(frames.icons.count == data.sessions.count)
                    if expanded { #expect(frames.icons == restingIcons) }
                    else { restingIcons = frames.icons }
                    let previewPoint = CGPoint(x: shell.midX,
                        y: size.height - (side == .bottom ? 21 : reserved + 19))
                    #expect(PickyHUDInkPassThroughPolicy.contains(previewPoint,
                        swiftUIFrames: frames.chrome, panelFrame: CGRect(origin: .zero, size: size)) == expanded)
                }
            }
        }
    }

    @Test func expandingAGroupGrowsTheVerticalListByItsMemberRows() {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let collapsed = fixtureData(state: .collapsedGroup)
        let expanded = fixtureData(state: .expandedGroup)
        let active = Set(collapsed.sessions.map(\.id))
        let collapsedLength = PickyHUDDockRailLayoutPolicy.listLength(
            projection: collapsed.projection, activeSessionIDs: active, orientation: .vertical, metrics: metrics, fontScale: 1)
        let expandedLength = PickyHUDDockRailLayoutPolicy.listLength(
            projection: expanded.projection, activeSessionIDs: active, orientation: .vertical, metrics: metrics, fontScale: 1)
        // Two member rows with their spacing, plus the card that replaces the
        // collapsed header's top gap: an outer gap on each side and room under
        // the last member.
        let card = 2 * metrics.groupCardOuterGap + metrics.groupCardInnerBottom - metrics.groupHeaderTopGap
        #expect(expandedLength - collapsedLength == 2 * (metrics.rowHeight(fontScale: 1) + metrics.rowSpacing) + card)
    }

    @Test func renderedHandleGripWidensWithTheVerticalListAndStaysThinHorizontally() throws {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for side: PickyHUDDockSide in [.right, .bottom] {
                let horizontal = side.orientation == .horizontal
                let notchWidth = horizontal ? metrics.horizontalHandleNotchWidth : metrics.handleNotchWidth
                let gripWidth = horizontal
                    ? PickyHUDDockMetrics.gripLength(preferred: metrics.horizontalHandleIdleWidth, notchLength: notchWidth)
                    : metrics.handleIdleWidth
                let view = PickyHUDDockHandleNotch(dockSide: side, metrics: metrics).environment(\.colorScheme, .light)
                let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                    logicalSize: horizontal ? CGSize(width: 11, height: notchWidth) : CGSize(width: notchWidth, height: 11),
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
                // The grip capsule at 2x, allowing antialiasing at its edges.
                #expect(abs((horizontal ? height : width) - gripWidth * 2) <= 2)
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
            #expect(statusGlyphAssetsRender(), "status glyph assets rendered blank")
            for preset in PickyHUDDockSizePreset.allCases {
                let metrics = PickyHUDDockMetrics(preset: preset)
                for dark in [false, true] {
                    for side: PickyHUDDockSide in [.right, .bottom] {
                        for state in FixtureState.allCases {
                            let view = fixture(side: side, metrics: metrics, state: state)
                            let host = NSHostingView(rootView: view)
                            let size = host.fittingSize
                            let canvas = CGSize(width: ceil(size.width) + 40, height: ceil(size.height) + 40)
                            let content = view.padding(20).environment(\.colorScheme, dark ? .dark : .light)
                            let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(content,
                                logicalSize: canvas, scale: 2, appearance: dark ? .darkAqua : .aqua))
                            let png = try #require(bitmap.representation(using: .png, properties: [:]))
                            let name = "\(preset.rawValue)-\(dark ? "dark" : "light")-\(side.orientation == .horizontal ? "horizontal" : "vertical")-\(state.rawValue).png"
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
                    let view = fixture(side: .right, metrics: metrics, state: .expandedGroup)
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
        #expect(files.count == PickyHUDDockSizePreset.allCases.count * 2 * 2 * FixtureState.allCases.count + 4 + 2)
    }

    private static let statusGlyphAssetNames = ["PickleDockWait", "PickleDockBlocked", "PickleDockHelp", "PickyCursorNormal"]

    /// Status glyphs are asset-catalog images, which the rasterizer has to
    /// treat differently from the shapes and SF Symbols around them. Without
    /// that handling every scene draws them blank, which is easy to miss in a
    /// 78-image gallery.
    private func statusGlyphAssetsRender() -> Bool {
        Self.statusGlyphAssetNames.allSatisfy { name in
            let probe = Image(name)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(Color.black)
                .frame(width: 16, height: 16)
            guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
                probe, logicalSize: CGSize(width: 16, height: 16), scale: 2, appearance: .aqua
            ) else { return false }
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide
                where (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0) > 0.5 {
                    return true
                }
            }
            return false
        }
    }

    private enum FixtureState: String, CaseIterable {
        case collapsedGroup = "collapsed-group"
        case expandedGroup = "expanded-group"
        case emptyGroup = "empty-group"
        case emptyDock = "empty-dock"
        case overflow
        /// Expanded group with an opened row, an unread row, and a Pickle armed
        /// for the next Picky input.
        case attention
        /// Two expanded groups back to back, then a loose Pickle: the group
        /// cards must keep their gap instead of merging into one tinted run.
        case adjacentGroups = "adjacent-groups"
    }

    private func fixtureData(state: FixtureState) -> (sessions: [PickyHUDDockSession], layout: PickyDockLayout, projection: PickyDockProjection) {
        let sessions = state == .emptyGroup
            ? [session("a", .running), session("d", .failed)]
            : [session("a", .running), session("b", .waiting_for_input), session("c", .completed), session("d", .failed)]
        let group = PickyDockGroup(id: "group", name: "제품 디자인 검토", color: .gray,
                                   memberSessionIDs: state == .emptyGroup ? [] : ["b", "c"],
                                   isCollapsed: state == .collapsedGroup || state == .overflow)
        if state == .adjacentGroups {
            let second = PickyDockGroup(id: "second", name: "운영", color: .teal,
                                        memberSessionIDs: ["a"], isCollapsed: false)
            let layout = PickyDockLayout(entries: [.group(group), .group(second), .session(id: "d")])
            let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: sessions.map(\.id))
            return (sessions, layout, projection)
        }
        let layout = PickyDockLayout(entries: state == .emptyDock ? [] : [.session(id: "a"), .group(group), .session(id: "d")])
        let visible = state == .emptyDock ? [] : sessions
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: visible.map(\.id))
        return (visible, layout, projection)
    }

    private static func availableRailLength(for state: FixtureState, side: PickyHUDDockSide) -> CGFloat {
        guard state == .overflow else { return fixtureAvailableLength }
        return side.orientation == .horizontal
            ? fixtureHorizontalOverflowAvailableLength
            : fixtureVerticalOverflowAvailableLength
    }

    private func fixture(side: PickyHUDDockSide, metrics: PickyHUDDockMetrics, state: FixtureState,
                         expansion: PickyHUDDockExpansionController? = nil) -> some View {
        let expansion = expansion ?? PickyHUDDockExpansionController()
        let data = fixtureData(state: state)
        let archive = EmptyArchive()
        let attention = state == .attention
        if attention { expansion.update(pointerInside: false, heldOpen: true) }
        return dockRail(sessions: data.sessions,
                        layout: data.layout, projection: data.projection, dockSide: side, metrics: metrics,
                        availableRailLength: Self.availableRailLength(for: state, side: side),
                        openedSessionID: attention ? "a" : nil,
                        unreadSessionIDs: attention ? ["c"] : [],
                        screenContextTargetSessionID: attention ? "d" : nil,
                        archiveAccess: PickyHUDArchivedSessionAccess(membership: archive, commands: archive),
                        expansion: expansion)
            .environment(\.pickyAppFontScale, 1)
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
        layout: PickyDockLayout,
        projection: PickyDockProjection,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        availableRailLength: CGFloat,
        openedSessionID: String? = nil,
        unreadSessionIDs: Set<String> = [],
        screenContextTargetSessionID: String? = nil,
        archiveAccess: PickyHUDArchivedSessionAccess? = nil,
        expansion: PickyHUDDockExpansionController? = nil
    ) -> some View {
        PickyHUDDockRailView(
            sessions: sessions,
            baseProjection: projection,
            layout: layout,
            activeSessionID: openedSessionID,
            openedSessionID: openedSessionID,
            screenContextTargetSessionID: screenContextTargetSessionID,
            screenContextTargetSticky: false,
            dockSide: dockSide,
            isCommandShortcutHintVisible: false,
            pendingDoneFlashSessionIDs: [],
            unreadSessionIDs: unreadSessionIDs,
            metrics: metrics,
            availableRailLength: availableRailLength,
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
            onSetDockGroupCollapsed: { _, _ in },
            onRemoveDockGroup: { _, _ in },
            onMoveSessionInDock: { _, _ in },
            onMoveDockGroup: { _, _ in },
            onDockHoverChanged: { _ in },
            onAddSlotExpandedChanged: { _ in },
            onDoneFlashConsumed: { _ in },
            onDockHandleDragChanged: { _ in },
            onDockHandleDragEnded: {},
            onDockHandleDoubleClick: {},
            archiveAccess: archiveAccess,
            expansion: expansion ?? PickyHUDDockExpansionController()
        )
    }

}

//
//  PickyHubPluginUpdatesRenderGalleryTests.swift
//  PickyTests
//
//  Offscreen renders of the production pending-updates section on the Hub
//  Plugins page: the page context plus checking, Update All, partial failure,
//  and finished states. Writes PNGs only when an output path is requested.
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHubPluginUpdatesRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.plugin-updates-output-path")
    private static let renderScale: CGFloat = 2
    private static let contentWidth = PickyHubTheme.Layout.contentMaxWidth

    private struct Scene {
        let name: String
        let dark: Bool
        let content: () -> AnyView
    }

    @Test func writesPluginUpdatesGalleryWhenOutputDirectoryIsRequested() throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }
        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            for scene in scenes() {
                let png = try render(scene)
                try png.write(to: output.appendingPathComponent(scene.name), options: .atomic)
                #expect(NSImage(data: png) != nil)
            }
        }
    }

    private static func item(
        _ plugin: PickyCuratedPlugin,
        version: String,
        latest: String?,
        hasUpdate: Bool = true
    ) -> PickyHubPluginItem {
        PickyHubPluginItem(
            plugin: plugin,
            metadata: PickyHubPluginMetadata.metadata(for: plugin),
            status: .installed(isPinned: false),
            installedVersion: version,
            errorMessage: nil,
            successMessage: nil,
            progressMessage: nil,
            hasUpdate: hasUpdate,
            isBusy: false,
            latestVersion: latest
        )
    }

    private static let bashAsync = item(.bashAsync, version: "0.3.0", latest: "0.3.1")
    private static let excalidraw = item(.excalidraw, version: "1.2.0", latest: "1.3.0")
    private static let bashAsyncUpdated = item(.bashAsync, version: "0.3.1", latest: nil, hasUpdate: false)

    private static let ready = PickyHubPluginUpdates(phase: .ready, entries: [
        .init(item: bashAsync, state: .idle),
        .init(item: excalidraw, state: .idle),
    ])

    private func scenes() -> [Scene] {
        let sections: [(String, PickyHubPluginUpdates)] = [
            ("2-checking", PickyHubPluginUpdates(phase: .checking, entries: [])),
            ("3-updating-all", PickyHubPluginUpdates(phase: .updatingAll(done: 1, total: 2), entries: [
                .init(item: Self.bashAsyncUpdated, state: .updated),
                .init(item: Self.excalidraw, state: .updating),
            ])),
            ("4-partial-failure", PickyHubPluginUpdates(phase: .ready, entries: [
                .init(item: Self.bashAsyncUpdated, state: .updated),
                .init(item: Self.excalidraw, state: .failed("npm 레지스트리에 연결하지 못했어요.")),
            ])),
            ("5-all-updated", PickyHubPluginUpdates(phase: .allUpdated(count: 2), entries: [])),
        ]
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            scenes.append(Scene(name: "1-page-context-\(suffix).png", dark: dark) { AnyView(PageContext()) })
            for (name, updates) in sections {
                scenes.append(Scene(name: "\(name)-\(suffix).png", dark: dark) {
                    AnyView(PickyHubPluginUpdatesSection(updates: updates, onUpdateAll: {}, onUpdate: { _ in }))
                })
            }
        }
        return scenes
    }

    /// Page header, the section, and two production catalog cards below it.
    private struct PageContext: View {
        @FocusState private var focus: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                PickyHubPageHeader(title: PickyHubPage.plugins.titleKey, subtitle: "hub.page.plugins.subtitle")
                PickyHubPluginUpdatesSection(updates: PickyHubPluginUpdatesRenderGalleryTests.ready, onUpdateAll: {}, onUpdate: { _ in })
                    .padding(.bottom, PickyHubTheme.Spacing.group)
                HStack(alignment: .top, spacing: PickyHubTheme.Spacing.field) {
                    card(PickyHubPluginUpdatesRenderGalleryTests.bashAsync)
                    card(PickyHubPluginUpdatesRenderGalleryTests.item(.webAccess, version: "0.9.2", latest: nil, hasUpdate: false))
                }
            }
        }

        private func card(_ item: PickyHubPluginItem) -> some View {
            PickyHubPluginCardView(
                item: item,
                onDetail: {}, onInstall: {}, onRemove: {}, onUpdate: {},
                onViewCronJobs: {}, onSetupCronDaemon: {},
                focusedControl: $focus
            )
        }
    }

    private enum RenderError: Error { case empty(String), encode(String) }

    private func render(_ scene: Scene) throws -> Data {
        let fontStore = PickyAppFontScaleStore()
        let inset = PickyHubTheme.Layout.contentHorizontalPadding
        func root(frame: CGSize?) -> AnyView {
            AnyView(PickyAppFontScaleRoot(store: fontStore) {
                scene.content()
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .frame(width: Self.contentWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(inset)
                    .frame(width: frame?.width, height: frame?.height, alignment: .topLeading)
                    .background(PickyHubTheme.Colors.canvas)
                    .preferredColorScheme(scene.dark ? .dark : .light)
            })
        }
        let appearance: NSAppearance.Name = scene.dark ? .darkAqua : .aqua
        let measuring = NSHostingView(rootView: root(frame: nil))
        measuring.appearance = NSAppearance(named: appearance)
        measuring.layoutSubtreeIfNeeded()
        let size = measuring.fittingSize
        guard size.width > 0, size.height > 0 else { throw RenderError.empty(scene.name) }
        let renderSize = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            root(frame: renderSize), logicalSize: renderSize, scale: Self.renderScale, appearance: appearance
        ), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.encode(scene.name)
        }
        return png
    }
}

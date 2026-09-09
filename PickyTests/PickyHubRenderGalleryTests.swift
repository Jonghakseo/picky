//
//  PickyHubRenderGalleryTests.swift
//  PickyTests
//
//  Deterministic offscreen renders for all seven production Hub pages.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHubRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.hub-output-path")
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
        let page: PickyHubPage
        let name: String
        let appearance: Appearance
        let logicalSize: CGSize
        let widthClass: String
        var dialog: String? = nil
    }

    private struct Manifest: Encodable {
        let schemaVersion: Int
        let renderer: String
        let scale: Int
        let scenes: [ManifestScene]
    }

    private struct ManifestScene: Encodable {
        let file: String
        let page: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let appearance: String
        let widthClass: String
    }

    @Test func fontScaleMenusRetainPercentageOptionsAcrossControlActivation() throws {
        let fixture = try PickyHubRenderGalleryFixture()
        defer { fixture.removeTemporaryState() }
        fixture.navigator.select(.settings)
        let root = PickyHubSettingsPage(dependencies: fixture.dependencies)
            .environmentObject(fixture.navigator)
            .environmentObject(fixture.dependencies.modalHost)
            .environmentObject(fixture.appearanceStore)
            .environmentObject(fixture.fontScaleStore)
            .environmentObject(fixture.updaterController)
            .environmentObject(fixture.pluginReloadController)
            .environment(\.locale, Locale(identifier: "ko"))
            .frame(width: 1020, height: 720)
        let host = NSHostingView(rootView: root.environment(\.controlActiveState, .inactive))
        host.frame = NSRect(x: 0, y: 0, width: 1020, height: 720)
        func menus(in view: NSView) -> [[String]] {
            let own = (view as? NSPopUpButton).map { [$0.itemTitles] } ?? []
            return own + view.subviews.flatMap { menus(in: $0) }
        }
        for state in [ControlActiveState.inactive, .key, .inactive] {
            host.rootView = root.environment(\.controlActiveState, state)
            host.layoutSubtreeIfNeeded()
            let options = menus(in: host)
            #expect(options.contains(["90%", "100%", "110%", "120%", "130%"]))
            let reportAndTerminal = options.filter { $0.first == "70%" && $0.last == "250%" }
            #expect(reportAndTerminal.count == 2)
            #expect(reportAndTerminal.allSatisfy { $0.count == 19 && $0.contains("100%") })
        }
    }

    @Test func writesHubGalleryWhenOutputDirectoryIsRequested() async throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }

        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try PickyHubRenderGalleryFixture()
        defer { fixture.removeTemporaryState() }

        let didRegisterThumbnailBlocker = URLProtocol.registerClass(PickyHubRenderGalleryThumbnailBlocker.self)
        defer {
            if didRegisterThumbnailBlocker {
                URLProtocol.unregisterClass(PickyHubRenderGalleryThumbnailBlocker.self)
            }
        }

        fixture.statisticsStore.filter.period = .all
        fixture.statisticsStore.refresh()
        try await waitUntilLoaded(fixture.statisticsStore)

        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            var manifestScenes: [ManifestScene] = []
            for scene in makeScenes() {
                fixture.navigator.select(scene.page)
                configureModal(scene, fixture: fixture)
                let rendered = try render(scene, fixture: fixture)
                try validate(rendered.bitmap, for: scene)

                let file = output.appendingPathComponent(scene.name)
                try rendered.png.write(to: file, options: .atomic)
                #expect(NSImage(data: rendered.png) != nil)

                manifestScenes.append(ManifestScene(
                    file: scene.name,
                    page: scene.page.rawValue,
                    logicalWidth: Double(scene.logicalSize.width),
                    logicalHeight: Double(scene.logicalSize.height),
                    pixelWidth: rendered.bitmap.pixelsWide,
                    pixelHeight: rendered.bitmap.pixelsHigh,
                    appearance: scene.appearance.rawValue,
                    widthClass: scene.widthClass
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
            try writeIndex(scenes: manifestScenes, to: output)
        }

        #expect(fixture.client.usedOnlyGalleryCommands)
    }

    /// Opt-in, local-only audit. Never reads the live application directory itself.
    @Test func writesFullPageHubAuditFromExportedSnapshot() async throws {
        let request = Self.outputRequestFile.deletingLastPathComponent().appendingPathComponent(".hub-audit-request.json")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        struct Request: Decodable { let snapshot: String; let output: String; let packages: String? }
        let config = try JSONDecoder().decode(Request.self, from: Data(contentsOf: request))
        let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyHubStatisticsSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: config.snapshot))
        )
        let filter = PickyHubStatisticsFilter(period: .all)
        let records = PickyHubStatisticsAggregator.records(in: snapshot, filter: filter)
        let usage = PickyHubStatisticsAggregator.usageSummary(in: snapshot, filter: filter)
        try #require(!records.isEmpty, "A work-table audit requires visible records")
        try #require(usage.totalTokens > 0, "A chart audit requires visible usage, not an empty-state render")
        let output = URL(fileURLWithPath: config.output, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let packages = try config.packages.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let fixture = try PickyHubRenderGalleryFixture(snapshot: snapshot, packageSettings: packages)
        defer { fixture.removeTemporaryState() }
        let blocked = URLProtocol.registerClass(PickyHubRenderGalleryThumbnailBlocker.self)
        defer { if blocked { URLProtocol.unregisterClass(PickyHubRenderGalleryThumbnailBlocker.self) } }
        fixture.statisticsStore.filter.period = .all
        fixture.statisticsStore.refresh()
        try await waitUntilLoaded(fixture.statisticsStore)
        #expect(fixture.statisticsStore.snapshot == snapshot)

        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            var scenes: [ManifestScene] = []
            for (width, appearance, fontScale) in [(1020.0, Appearance.dark, 1.0), (1020.0, .light, 1.0), (760.0, .dark, 1.3)] {
                fixture.fontScaleStore.setScale(fontScale)
                for surface in ["dashboard", "statistics", "usage"] {
                    let page: PickyHubPage = surface == "dashboard" ? .dashboard : .statistics
                    let rowCount = surface == "statistics" ? records.count : (surface == "usage" ? usage.models.count : 0)
                    // 64pt bounds either table's 42/48pt row plus divider; reserve
                    // 1600pt for filters, summary cards, charts, and the footer.
                    let height = max(3600, Double(rowCount) * 64 + 1600)
                    let scene = Scene(page: page,
                        name: "audit-\(surface)-\(Int(width))-\(appearance.rawValue)-\(Int(fontScale * 100)).png",
                        appearance: appearance, logicalSize: CGSize(width: width, height: height), widthClass: "full-page")
                    if page == .statistics {
                        fixture.navigator.showStatistics(tab: surface == "usage" ? .usage : .work)
                    } else {
                        fixture.navigator.select(page)
                    }
                    let rendered = try render(scene, fixture: fixture, locale: Locale(identifier: "ko_KR"))
                    try validate(rendered.bitmap, for: scene)
                    try rendered.png.write(to: output.appendingPathComponent(scene.name), options: .atomic)
                    scenes.append(ManifestScene(file: scene.name, page: page.rawValue,
                        logicalWidth: width, logicalHeight: height,
                        pixelWidth: rendered.bitmap.pixelsWide, pixelHeight: rendered.bitmap.pixelsHigh,
                        appearance: appearance.rawValue, widthClass: scene.widthClass))
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Manifest(schemaVersion: 1, renderer: "production Hub, exported local statistics, full-height offscreen viewport", scale: 2, scenes: scenes))
                .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
            try writeIndex(scenes: scenes, to: output)
        }
        #expect(fixture.client.usedOnlyGalleryCommands)
    }

    private func makeScenes() -> [Scene] {
        let pages = PickyHubPage.allCases.flatMap { page in
            [
                Scene(
                    page: page,
                    name: "hub-\(page.rawValue)-wide-dark.png",
                    appearance: .dark,
                    logicalSize: PickyHubTheme.Layout.defaultWindowSize,
                    widthClass: "wide"
                ),
                Scene(
                    page: page,
                    name: "hub-\(page.rawValue)-wide-light.png",
                    appearance: .light,
                    logicalSize: PickyHubTheme.Layout.defaultWindowSize,
                    widthClass: "wide"
                ),
                Scene(
                    page: page,
                    name: "hub-\(page.rawValue)-narrow-dark.png",
                    appearance: .dark,
                    logicalSize: PickyHubTheme.Layout.minimumWindowSize,
                    widthClass: "narrow"
                ),
            ]
        }
        let dialogs = ["pluginDetail", "statisticsReset"].flatMap { dialog in
            [(Appearance.dark, "wide"), (.light, "wide"), (.dark, "narrow")].map { appearance, widthClass in
                Scene(
                    page: dialog == "pluginDetail" ? .plugins : .settings,
                    name: "hub-\(dialog)-\(widthClass)-\(appearance.rawValue).png",
                    appearance: appearance,
                    logicalSize: widthClass == "narrow" ? PickyHubTheme.Layout.minimumWindowSize : PickyHubTheme.Layout.defaultWindowSize,
                    widthClass: widthClass,
                    dialog: dialog
                )
            }
        }
        return pages + dialogs
    }

    private func configureModal(_ scene: Scene, fixture: PickyHubRenderGalleryFixture) {
        let host = fixture.dependencies.modalHost
        host.dismiss()
        if scene.dialog == "pluginDetail", let item = fixture.dependencies.pluginCatalog.items.first {
            host.present(width: 540, accessibilityLabel: item.title) {
                PickyHubPluginDetailDialog(item: item, onInstall: {}, onRemove: {})
            }
        } else if scene.dialog == "statisticsReset" {
            host.present(width: 430, accessibilityLabel: L10n.t("hub.settings.statisticsReset.dialog.title")) {
                PickyHubConfirmDialog(
                    title: L10n.t("hub.settings.statisticsReset.dialog.title"),
                    message: L10n.t("hub.settings.statisticsReset.dialog.message"),
                    confirmTitle: "hub.settings.statisticsReset.dialog.confirm",
                    onCancel: {}, onConfirm: {}
                )
            }
        }
        #expect(host.isPresenting == (scene.dialog != nil))
    }

    private func render(
        _ scene: Scene,
        fixture: PickyHubRenderGalleryFixture,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) throws -> (png: Data, bitmap: NSBitmapImageRep) {
        let root = AnyView(
            PickyAppFontScaleRoot(store: fixture.fontScaleStore) {
                PickyHubRootView(dependencies: fixture.dependencies, dockDisplayIDProvider: { nil })
                    .environmentObject(fixture.appearanceStore)
                    .environmentObject(fixture.hudVisibilityStore)
                    .environmentObject(fixture.updaterController)
                    .environmentObject(fixture.pluginReloadController)
                    .environment(\.locale, locale)
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .frame(width: scene.logicalSize.width, height: scene.logicalSize.height)
            }
        )
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            root,
            logicalSize: scene.logicalSize,
            scale: Self.renderScale,
            appearance: scene.appearance.nsAppearance
        ) else {
            throw RenderError.bitmapCreationFailed(scene.name)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed(scene.name)
        }
        return (png, bitmap)
    }

    private func validate(_ bitmap: NSBitmapImageRep, for scene: Scene) throws {
        let expectedWidth = Int((scene.logicalSize.width * Self.renderScale).rounded(.up))
        let expectedHeight = Int((scene.logicalSize.height * Self.renderScale).rounded(.up))
        guard bitmap.pixelsWide == expectedWidth, bitmap.pixelsHigh == expectedHeight else {
            throw RenderError.unexpectedDimensions(
                scene.name,
                actual: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
                expected: CGSize(width: expectedWidth, height: expectedHeight)
            )
        }
        guard bitmap.hasAlpha, let bytes = bitmap.bitmapData else {
            throw RenderError.missingAlpha(scene.name)
        }

        let samplesPerPixel = bitmap.samplesPerPixel
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : samplesPerPixel - 1
        var hasVisiblePixel = false
        var colors = Set<UInt32>()
        let samplingStride = 16

        for y in 0..<bitmap.pixelsHigh {
            let row = y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let offset = row + x * samplesPerPixel
                if bytes[offset + alphaOffset] > 0 { hasVisiblePixel = true }
                guard x.isMultiple(of: samplingStride), y.isMultiple(of: samplingStride) else { continue }
                let redOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
                let greenOffset = redOffset + 1
                let blueOffset = redOffset + 2
                let color = UInt32(bytes[offset + redOffset]) << 16
                    | UInt32(bytes[offset + greenOffset]) << 8
                    | UInt32(bytes[offset + blueOffset])
                colors.insert(color)
            }
        }

        guard hasVisiblePixel else { throw RenderError.emptyAlpha(scene.name) }
        guard colors.count >= 8 else { throw RenderError.insufficientLayoutDetail(scene.name, colorCount: colors.count) }
    }

    private func waitUntilLoaded(_ store: PickyHubStatisticsStore) async throws {
        let deadline = Date().addingTimeInterval(1)
        while true {
            if case .loaded = store.state { return }
            if Date() >= deadline { throw RenderError.statisticsDidNotLoad }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func writeIndex(scenes: [ManifestScene], to output: URL) throws {
        let items = scenes.map { scene in
            "<figure><img src=\"\(scene.file)\" alt=\"\(scene.page) \(scene.appearance) \(scene.widthClass)\"><figcaption>\(scene.page), \(scene.appearance), \(scene.widthClass)</figcaption></figure>"
        }.joined(separator: "\n")
        let html = """
        <!doctype html>
        <meta charset="utf-8">
        <title>Picky Hub render gallery</title>
        <style>body{font-family:-apple-system;margin:24px;background:#202124;color:#f1f3f4}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:20px}figure{margin:0}img{width:100%;height:auto;border:1px solid #5f6368}figcaption{margin-top:6px;font-size:13px}</style>
        <main>
        \(items)
        </main>
        """
        try html.write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private enum RenderError: Error {
        case bitmapCreationFailed(String)
        case pngEncodingFailed(String)
        case unexpectedDimensions(String, actual: CGSize, expected: CGSize)
        case missingAlpha(String)
        case emptyAlpha(String)
        case insufficientLayoutDetail(String, colorCount: Int)
        case statisticsDidNotLoad
    }
}

@MainActor
final class PickyHubRenderGalleryFixture {
    let client: PickyHubRenderGalleryClient
    let navigator: PickyHubNavigator
    let appearanceStore: PickyAppearanceStore
    let fontScaleStore: PickyAppFontScaleStore
    let hudVisibilityStore: PickyHUDVisibilityStore
    let updaterController: PickyUpdaterController
    let pluginReloadController: PickyPluginReloadController
    let statisticsStore: PickyHubStatisticsStore
    let dependencies: PickyHubDependencies

    private let temporaryRoot: URL
    private let defaults: UserDefaults
    private let defaultsSuiteName: String

    init(snapshot: PickyHubStatisticsSnapshot? = nil, packageSettings: Data? = nil) throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyHubRenderGallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let defaultsSuite = "PickyHubRenderGallery.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw FixtureError.userDefaultsUnavailable
        }
        self.defaults = defaults
        self.defaultsSuiteName = defaultsSuite

        let settingsStore = PickySettingsStore(appSupportRoot: temporaryRoot)
        let client = PickyHubRenderGalleryClient(snapshot: snapshot ?? Self.statisticsSnapshot)
        let selectionStore = PickyHubRenderGallerySelectionStore()
        let sessionListViewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: selectionStore,
            archiveStore: PickyHubRenderGalleryArchiveStore(),
            manualOrderStore: PickyHubRenderGalleryManualOrderStore(),
            composerDraftStore: PickyHubRenderGalleryDraftStore(),
            composerAttachmentDraftStore: PickyHubRenderGalleryAttachmentStore(),
            recentPickleFolderStore: PickyNoopRecentPickleFolderStore(),
            dockLayoutStore: PickyNoopDockLayoutStore(),
            artifactPathValidator: PickyArtifactPathValidator(appSupportRoot: temporaryRoot),
            generatedReportDirectory: temporaryRoot.appendingPathComponent("GeneratedReports", isDirectory: true),
            pickleRuntimeDefaultsStore: settingsStore
        )
        let permissionMonitor = PickyPermissionMonitor(probes: .init(
            accessibility: { true },
            screenRecording: { true },
            microphone: { true },
            persistedScreenContent: { true },
            persistScreenContent: {}
        ))
        let companionManager = CompanionManager(
            agentClient: client,
            ownsAgentClientLifecycle: false,
            selectionStore: selectionStore,
            initialSettings: settingsStore.load(),
            appearanceStore: PickyAppearanceStore(settingsStore: settingsStore),
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settingsStore),
            permissions: permissionMonitor,
            pointerLocationProvider: { .zero }
        )
        companionManager.mainConversation.replaceMessages([
            PickyMainAgentMessage(role: .user, text: "Summarize this week's work.", createdAt: Date(timeIntervalSince1970: 1_784_000_000)),
            PickyMainAgentMessage(role: .assistant, text: "You completed two interface reviews and prepared a focused follow-up.", createdAt: Date(timeIntervalSince1970: 1_784_000_060)),
        ])
        companionManager.mainConversation.updateSessionInfo(sessionFilePath: "/tmp/hub-gallery.jsonl", cwd: "/tmp/hub-gallery")

        self.client = client
        navigator = PickyHubNavigator()
        appearanceStore = PickyAppearanceStore(settingsStore: settingsStore)
        fontScaleStore = PickyAppFontScaleStore(settingsStore: settingsStore)
        hudVisibilityStore = PickyHUDVisibilityStore(settingsStore: settingsStore)
        updaterController = PickyUpdaterController(releaseChannel: "alpha", automaticChecksEnabled: false)
        pluginReloadController = PickyPluginReloadController(client: client)
        statisticsStore = PickyHubStatisticsStore(client: client, timeoutNanoseconds: 100_000_000)
        let packageHome = temporaryRoot.appendingPathComponent("package-home", isDirectory: true)
        if let packageSettings {
            let directory = packageHome.appendingPathComponent(".pi/agent", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try packageSettings.write(to: directory.appendingPathComponent("settings.json"))
        }
        let curated = PickyCuratedPluginsViewModel(
            plugins: packageSettings == nil ? [.diffReview, .askUserQuestion] : PickyCuratedPlugin.curatedDefaults,
            statusForSource: { source in
                if packageSettings != nil {
                    return PickyCuratedPluginInstaller.status(source: source, homeURL: packageHome)
                }
                return source == PickyCuratedPlugin.diffReview.source ? .installed(isPinned: false) : .notInstalled
            },
            installedVersionForSource: { _ in packageSettings == nil ? "1.2.3" : nil }
        )
        let pluginCatalog = PickyHubPluginCatalogViewModel(curated: curated, pluginReloadController: pluginReloadController)
        let quickStartLauncher = PickyHubQuickStartLauncher(
            sessions: sessionListViewModel,
            defaultCwd: { "/tmp/hub-gallery" },
            presentSessionInHUD: { _ in },
            defaults: defaults,
            projectionTimeoutNanoseconds: 100_000_000
        )
        dependencies = PickyHubDependencies(
            companionManager: companionManager,
            sessionListViewModel: sessionListViewModel,
            settingsViewModel: PickySettingsViewModel(store: settingsStore),
            settingsStore: settingsStore,
            appearanceStore: appearanceStore,
            fontScaleStore: fontScaleStore,
            hudVisibilityStore: hudVisibilityStore,
            updaterController: updaterController,
            pluginReloadController: pluginReloadController,
            agentClient: client,
            navigator: navigator,
            modalHost: PickyHubModalHost(),
            statisticsStore: statisticsStore,
            quickStartLauncher: quickStartLauncher,
            pluginCatalog: pluginCatalog
        )
    }

    func readPersistedSettings() -> PickySettings {
        PickySettingsStore(appSupportRoot: temporaryRoot).load()
    }

    func removeTemporaryState() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private static let statisticsSnapshot = PickyHubStatisticsSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_784_000_120),
        records: [
            PickyHubPickleRecord(id: "gallery-fix", title: "Refine Hub gallery", project: "picky", cwd: "/tmp/picky", createdAt: Date(timeIntervalSince1970: 1_783_900_000), lastActivityAt: Date(timeIntervalSince1970: 1_784_000_000), followUpCount: 3, delegationCount: 2, reviewCount: 1, category: .fix),
            PickyHubPickleRecord(id: "gallery-research", title: "Compare local renderers", project: "picky", cwd: "/tmp/picky", createdAt: Date(timeIntervalSince1970: 1_783_800_000), lastActivityAt: Date(timeIntervalSince1970: 1_783_990_000), followUpCount: 1, delegationCount: 1, reviewCount: 2, category: .research),
            PickyHubPickleRecord(id: "gallery-create", title: "Build a workflow", project: "studio", cwd: "/tmp/studio", createdAt: Date(timeIntervalSince1970: 1_783_700_000), lastActivityAt: Date(timeIntervalSince1970: 1_783_980_000), followUpCount: 0, delegationCount: 1, reviewCount: 0, category: .create),
        ],
        usageSamples: [
            PickyHubUsageSample(day: "2026-07-13", provider: "Anthropic", model: "Claude Sonnet", project: "picky", inputTokens: 12_000, outputTokens: 3_000, cacheTokens: 1_500),
            PickyHubUsageSample(day: "2026-07-14", provider: "OpenAI", model: "GPT-5", project: "studio", inputTokens: 8_000, outputTokens: 2_000, cacheTokens: 500),
            PickyHubUsageSample(day: "2026-07-15", provider: "Anthropic", model: "Claude Sonnet", project: "picky", inputTokens: 16_000, outputTokens: 4_000, cacheTokens: 2_000),
        ],
        pendingClassificationCount: 1
    )

    private enum FixtureError: Error {
        case userDefaultsUnavailable
    }
}

final class PickyHubRenderGalleryClient: PickyAgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [AsyncStream<PickyClientEvent>.Continuation] = []
    var events: AsyncStream<PickyClientEvent> {
        AsyncStream { continuation in lock.withLock { subscribers.append(continuation) } }
    }
    private func emit(_ event: PickyClientEvent) {
        for continuation in lock.withLock({ subscribers }) { continuation.yield(event) }
    }
    private let snapshot: PickyHubStatisticsSnapshot
    @MainActor private(set) var sentCommandTypes: [PickyCommandType] = []

    init(snapshot: PickyHubStatisticsSnapshot) {
        self.snapshot = snapshot
    }

    @MainActor var usedOnlyGalleryCommands: Bool {
        sentCommandTypes.allSatisfy { [.getHubStatistics, .checkPackageUpdates].contains($0) }
    }

    func connect() async { emit(.connected) }

    func submit(_: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "hub-gallery", message: "gallery")
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        await MainActor.run { sentCommandTypes.append(command.type) }
        guard command.type == .getHubStatistics else { return }
        emit(.protocolEvent(PickyEventEnvelope(
            id: "hub-gallery-statistics-result",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(timeIntervalSince1970: 1_784_000_120),
            event: .hubStatisticsResult(PickyHubStatisticsResultEvent(
                commandId: command.id,
                ok: true,
                errorMessage: nil,
                snapshot: snapshot
            ))
        )))
    }

    func disconnect() { emit(.disconnected) }
}

private final class PickyHubRenderGallerySelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky = false
    private(set) var screenContextTargetRevision: UInt64 = 0

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
        screenContextTargetRevision &+= 1
    }
}

private final class PickyHubRenderGalleryArchiveStore: PickySessionArchiveStoring {
    var archivedSessionIDs = Set<String>()
    var manuallyArchivedSessionIDs = Set<String>()
}

private final class PickyHubRenderGalleryManualOrderStore: PickySessionManualOrderStoring {
    var manualOrder: [String] = []
}

private final class PickyHubRenderGalleryDraftStore: PickyComposerDraftStoring {
    private var values: [String: String] = [:]
    func draft(for sessionID: String) -> String? { values[sessionID] }
    func setDraft(_ draft: String?, for sessionID: String) { values[sessionID] = draft }
    func prune(knownSessionIDs: Set<String>) { values = values.filter { knownSessionIDs.contains($0.key) } }
}

private final class PickyHubRenderGalleryAttachmentStore: PickyComposerAttachmentDraftStoring {
    private var values: [String: [String]] = [:]
    func attachmentPaths(for sessionID: String) -> [String] { values[sessionID] ?? [] }
    func setAttachmentPaths(_ paths: [String], for sessionID: String) { values[sessionID] = paths }
    func prune(knownSessionIDs: Set<String>) { values = values.filter { knownSessionIDs.contains($0.key) } }
}

private final class PickyHubRenderGalleryThumbnailBlocker: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("ytimg.com") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

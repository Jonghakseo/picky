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
    private static let composerOutputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.conversation-composer-output-path")
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
        try writeGallery(requestFile: Self.outputRequestFile, scenes: makeScenes())
    }

    @Test func writesConversationComposerGalleryWhenOutputDirectoryIsRequested() throws {
        try writeGallery(requestFile: Self.composerOutputRequestFile, scenes: makeComposerScenes())
    }

    private func writeGallery(requestFile: URL, scenes: [Scene]) throws {
        guard let rawOutput = try? String(contentsOf: requestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawOutput.isEmpty
        else { return }

        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            var manifestScenes: [ManifestScene] = []
            for scene in scenes {
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
            Scene(
                name: "context-band-ramp-dark-ko.png",
                appearance: .dark,
                content: AnyView(contextBandRamp)
            ),
            Scene(
                name: "context-band-ramp-light-ko.png",
                appearance: .light,
                content: AnyView(contextBandRamp)
            ),
        ]
    }

    /// One pill per usage band so the neutral / caution / warning / destructive
    /// ramp can be compared in a single artifact.
    private var contextBandRamp: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach([42, 68, 84, 96], id: \.self) { percent in
                PickyHeaderSessionMetaPill(
                    presentation: PickyConversationHeaderMetaPresentation(
                        assistantRun: nil,
                        contextUsage: PickyContextUsage(
                            tokens: 2_000 * percent,
                            contextWindow: 200_000,
                            percent: Double(percent)
                        )
                    ),
                    compactionPresentation: .init(status: .completed, lastSummary: "Completed"),
                    onCompact: {}
                )
            }
        }
    }

    private func makeComposerScenes() -> [Scene] {
        [
            Scene(
                name: "composer-empty-running-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyConversationComposerRenderScene(
                    id: "composer-empty-running",
                    draft: ""
                ))
            ),
            Scene(
                name: "composer-one-line-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyConversationComposerRenderScene(
                    id: "composer-one-line",
                    draft: "메시지를 입력하세요"
                ))
            ),
            Scene(
                name: "composer-option-follow-up-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyConversationComposerRenderScene(
                    id: "composer-option-follow-up",
                    draft: "현재 작업이 끝나면 결과를 요약해 주세요",
                    isOptionModifierPressed: true
                ))
            ),
            Scene(
                name: "composer-long-model-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyConversationComposerRenderScene(
                    id: "composer-long-model",
                    draft: "긴 모델명에서도 전송 버튼을 유지해 주세요",
                    model: "google/gemini-3-pro-preview-long-model-name"
                ))
            ),
            Scene(
                name: "composer-four-lines-dark-ko.png",
                appearance: .dark,
                content: AnyView(PickyConversationComposerRenderScene(
                    id: "composer-four-lines",
                    draft: "첫 번째 줄\n두 번째 줄\n세 번째 줄\n네 번째 줄"
                ))
            ),
            Scene(
                name: "composer-four-lines-light-ko.png",
                appearance: .light,
                content: AnyView(PickyConversationComposerRenderScene(
                    id: "composer-four-lines-light",
                    draft: "첫 번째 줄\n두 번째 줄\n세 번째 줄\n네 번째 줄"
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
        let initialSize = measuringHost.fittingSize
        measuringHost.frame = NSRect(origin: .zero, size: initialSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
        // Pixel-aligned canvas so the renderer emits exactly the expected pixel grid.
        let renderSize = CGSize(
            width: CGFloat(pixelWidth) / Self.renderScale,
            height: CGFloat(pixelHeight) / Self.renderScale
        )
        let renderedRoot = AnyView(
            PickyAppFontScaleRoot(store: fontStore) {
                scene.content
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .preferredColorScheme(scene.appearance.colorScheme)
                    .fixedSize()
                    .padding(canvasInset)
                    .frame(
                        width: renderSize.width,
                        height: renderSize.height,
                        alignment: .topLeading
                    )
            }
        )
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            renderedRoot,
            logicalSize: renderSize,
            scale: Self.renderScale,
            appearance: scene.appearance.nsAppearance
        ) else {
            throw RenderError.bitmapCreationFailed(scene.name)
        }
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

@MainActor
private struct PickyConversationComposerRenderScene: View {
    private let session: PickySessionListViewModel.SessionCard
    @StateObject private var viewModel: PickySessionListViewModel

    private let isOptionModifierPressed: Bool

    init(
        id: String,
        draft: String,
        isOptionModifierPressed: Bool = false,
        model: String = "openai-codex/gpt-5.6"
    ) {
        let date = Date(timeIntervalSince1970: 1_775_000_000)
        let session = PickySessionListViewModel.SessionCard.fromAgentSession(
            PickyAgentSession(
                id: id,
                title: "Composer render",
                status: .running,
                cwd: "/tmp/picky",
                createdAt: date,
                updatedAt: date,
                lastSummary: "Ready",
                logs: [],
                tools: [],
                artifacts: [],
                changedFiles: [],
                messages: [
                    PickySessionMessage(
                        id: "assistant-run",
                        kind: .agentText,
                        createdAt: date,
                        originatedBy: nil,
                        text: "Ready",
                        question: nil,
                        cancelledAt: nil,
                        activitySnapshot: nil,
                        assistantRun: PickyAssistantRunMetadata(
                            model: model,
                            thinkingLevel: .high
                        ),
                        errorContext: nil,
                        errorMessage: nil
                    ),
                ],
                queuedSteers: [],
                queuedFollowUps: [],
                steeringMode: .oneAtATime,
                followUpMode: .oneAtATime,
                activitySummary: .zero,
                contextUsage: nil,
                currentAssistantRun: PickyAssistantRunMetadata(
                    model: model,
                    thinkingLevel: .high
                ),
                pendingExtensionUiRequest: nil,
                notifyMainOnCompletion: false
            )
        )
        let viewModel = PickySessionListViewModel(
            client: LocalStubPickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            composerDraftStore: PickyConversationComposerRenderDraftStore(),
            composerAttachmentDraftStore: PickyConversationComposerRenderAttachmentStore()
        )
        viewModel.updateComposerDraft(draft, sessionID: session.id)
        self.session = session
        self.isOptionModifierPressed = isOptionModifierPressed
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        PickyConversationComposerView(
            session: session,
            viewModel: viewModel,
            isOptionModifierPressed: isOptionModifierPressed
        )
        .frame(width: PickyHUDDockLayout.detailWidth)
    }
}

private final class PickyConversationComposerRenderDraftStore: PickyComposerDraftStoring {
    private var drafts: [String: String] = [:]

    func draft(for sessionID: String) -> String? { drafts[sessionID] }
    func setDraft(_ draft: String?, for sessionID: String) { drafts[sessionID] = draft }
    func prune(knownSessionIDs: Set<String>) {
        drafts = drafts.filter { knownSessionIDs.contains($0.key) }
    }
}

private final class PickyConversationComposerRenderAttachmentStore: PickyComposerAttachmentDraftStoring {
    func attachmentPaths(for _: String) -> [String] { [] }
    func setAttachmentPaths(_: [String], for _: String) { }
    func prune(knownSessionIDs _: Set<String>) { }
}

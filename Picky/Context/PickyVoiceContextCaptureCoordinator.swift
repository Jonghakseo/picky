//
//  PickyVoiceContextCaptureCoordinator.swift
//  Picky
//

import CoreGraphics
import Foundation

struct PickyVoiceContextCaptureResult {
    let contextPacket: PickyContextPacket
    let source: String
}

/// Screen capture is independent of transcription. A prepared capture lets the
/// PTT release path overlap that expensive work with STT, then adds the final
/// transcript only when it is available.
struct PickyPreparedVoiceContextCapture {
    let captureID: UUID
    let contextPacket: PickyPreparedContextPacket
    let source: String
}

@MainActor
struct PickyVoiceContextCaptureCoordinator {
    typealias ScreenCapture = @MainActor (
        _ scope: PickyScreenContextScope,
        _ maximumDimension: Int,
        _ inkGlobalPoints: [CGPoint],
        _ onlyWhenInked: Bool,
        _ displayOverrides: PickyScreenContextDisplayOverrides,
        _ displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot?
    ) async throws -> [CompanionScreenCapture]
    typealias SettingsProvider = @MainActor () -> PickySettings
    typealias ContextPreflightCapture = @MainActor () async -> PickyContextPacketPreflight
    typealias ContextPreparer = @MainActor (
        _ screenCaptures: [CompanionScreenCapture],
        _ source: String,
        _ inkCapture: PickyInkCapture?,
        _ preflight: PickyContextPacketPreflight
    ) async throws -> PickyPreparedContextPacket

    private let screenCapture: ScreenCapture
    private let settingsProvider: SettingsProvider
    private let contextPreflightCapture: ContextPreflightCapture
    private let contextPreparer: ContextPreparer

    init(
        screenCapture: @escaping ScreenCapture = PickyVoiceContextCaptureCoordinator.captureScreens,
        settingsProvider: @escaping SettingsProvider = { PickySettingsStore().load() },
        contextPreflightCapture: @escaping ContextPreflightCapture =
            PickyVoiceContextCaptureCoordinator.captureContextPreflight,
        contextPreparer: @escaping ContextPreparer = PickyVoiceContextCaptureCoordinator.prepareContextPacket
    ) {
        self.screenCapture = screenCapture
        self.settingsProvider = settingsProvider
        self.contextPreflightCapture = contextPreflightCapture
        self.contextPreparer = contextPreparer
    }

    func captureContext(
        transcript: String,
        voiceFollowUpSessionID: String?,
        inkCapture: PickyInkCapture? = nil,
        displayOverrides: PickyScreenContextDisplayOverrides = [:],
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        return try await captureContext(
            transcript: transcript,
            source: source,
            inkCapture: inkCapture,
            displayOverrides: displayOverrides,
            displaySelectionSnapshot: displaySelectionSnapshot
        )
    }

    func captureContext(
        transcript: String,
        source: String,
        inkCapture: PickyInkCapture? = nil,
        displayOverrides: PickyScreenContextDisplayOverrides = [:],
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        guard let prepared = try await prepareContext(
            source: source,
            inkCapture: inkCapture,
            displayOverrides: displayOverrides,
            displaySelectionSnapshot: displaySelectionSnapshot
        ) else { return nil }
        return try await assembleContext(prepared, transcript: transcript)
    }

    /// Starts transcript-independent context capture as soon as PTT is
    /// released. Browser/AX state intentionally reflects the release moment,
    /// matching the screen snapshot while transcription is still in progress.
    func prepareContext(
        source: String,
        inkCapture: PickyInkCapture? = nil,
        displayOverrides: PickyScreenContextDisplayOverrides = [:],
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot? = nil
    ) async throws -> PickyPreparedVoiceContextCapture? {
        let captureID = UUID()
        let settings = settingsProvider()
        let contextPreparationStartedAt = Date()
        let screenCapture = screenCapture
        let contextPreflightCapture = contextPreflightCapture
        async let preflight = contextPreflightCapture()
        let inkGlobalPoints = (inkCapture?.strokes ?? []).flatMap { stroke in
            stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        }
        let screenCaptures = try await screenCapture(
            settings.screenContextScope,
            settings.screenshotQuality.maximumDimension,
            inkGlobalPoints,
            settings.attachScreenshotsOnlyWhenInked,
            displayOverrides,
            displaySelectionSnapshot
        )
        let includedScreenCaptures = Self.filterScreenCapturesForAttachment(
            screenCaptures,
            onlyWhenInked: settings.attachScreenshotsOnlyWhenInked,
            inkGlobalPoints: inkGlobalPoints,
            displayOverrides: displayOverrides,
            displaySelectionSnapshot: displaySelectionSnapshot
        )
        let screenCaptureMilliseconds = Int(Date().timeIntervalSince(contextPreparationStartedAt) * 1_000)
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=screenCaptureFinished captureID=\(captureID) source=\(source) "
                + "ms=\(screenCaptureMilliseconds) screens=\(screenCaptures.count)"
        )
        guard !Task.isCancelled else { return nil }
        let preparedPacket = try await contextPreparer(includedScreenCaptures, source, inkCapture, await preflight)
        let contextPreparationMilliseconds = Int(Date().timeIntervalSince(contextPreparationStartedAt) * 1_000)
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=contextAssemblerFinished captureID=\(captureID) "
                + "contextID=\(preparedPacket.id) source=\(source) phase=preTranscript "
                + "ms=\(contextPreparationMilliseconds)"
        )
        guard !Task.isCancelled else { return nil }
        return PickyPreparedVoiceContextCapture(
            captureID: captureID,
            contextPacket: preparedPacket,
            source: source
        )
    }

    /// Joins the prepared neutral context with the final STT transcript.
    func assembleContext(
        _ prepared: PickyPreparedVoiceContextCapture,
        transcript: String
    ) async throws -> PickyVoiceContextCaptureResult? {
        guard !Task.isCancelled else { return nil }
        let assembled = prepared.contextPacket.attaching(transcript: transcript)
        return PickyVoiceContextCaptureResult(contextPacket: assembled, source: prepared.source)
    }

    static func filterScreenCapturesForAttachment(
        _ captures: [CompanionScreenCapture],
        onlyWhenInked: Bool,
        inkGlobalPoints: [CGPoint],
        displayOverrides: PickyScreenContextDisplayOverrides,
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot? = nil
    ) -> [CompanionScreenCapture] {
        captures.filter { capture in
            if let displaySelectionSnapshot,
               !displaySelectionSnapshot.includedDisplayIDs.contains(capture.displayID) {
                return false
            }
            let hasInk = inkGlobalPoints.contains { capture.displayFrame.contains($0) }
            switch displayOverrides[capture.displayID] {
            case .included:
                return true
            case .excluded:
                return false
            case nil:
                return PickyScreenContextInclusionPolicy.passesInkAttachmentGate(
                    onlyWhenInked: onlyWhenInked,
                    hasInk: hasInk
                )
            }
        }
    }

    private static func captureScreens(
        scope: PickyScreenContextScope,
        maximumDimension: Int,
        inkGlobalPoints: [CGPoint],
        onlyWhenInked: Bool,
        displayOverrides: PickyScreenContextDisplayOverrides,
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot?
    ) async throws -> [CompanionScreenCapture] {
        try await CompanionScreenCaptureUtility.captureScreensAsJPEG(
            scope: scope,
            maximumDimension: maximumDimension,
            inkGlobalPoints: inkGlobalPoints,
            onlyWhenInked: onlyWhenInked,
            displayOverrides: displayOverrides,
            displaySelectionSnapshot: displaySelectionSnapshot
        )
    }

    private static func captureContextPreflight() async -> PickyContextPacketPreflight {
        await makeContextAssembler(screenCaptures: [], inkCapture: nil).capturePreflight()
    }

    private static func prepareContextPacket(
        screenCaptures: [CompanionScreenCapture],
        source: String,
        inkCapture: PickyInkCapture?,
        preflight: PickyContextPacketPreflight
    ) async throws -> PickyPreparedContextPacket {
        try makeContextAssembler(screenCaptures: screenCaptures, inkCapture: inkCapture)
            .prepare(source: source, preflight: preflight)
    }

    private static func makeContextAssembler(
        screenCaptures: [CompanionScreenCapture],
        inkCapture: PickyInkCapture?
    ) -> PickyContextPacketAssembler {
        PickyContextPacketAssembler(
            appProvider: WorkspacePickyApplicationContextProvider(),
            windowProvider: CGWindowPickyWindowContextProvider(),
            advancedBrowserProvider: ChainedBrowserContextProvider(providers: [
                AppleScriptBrowserContextProvider(),
                AccessibilityBrowserContextProvider()
            ]),
            selectedTextProvider: ChainedSelectedTextProvider(providers: [
                AccessibilitySelectedTextProvider(),
                ClipboardSelectedTextProvider()
            ]),
            screenProvider: StaticPickyScreenContextProvider(captures: screenCaptures, inkCapture: inkCapture),
            defaultCwd: PickySettingsStore().load().mainAgentCwd
        )
    }
}

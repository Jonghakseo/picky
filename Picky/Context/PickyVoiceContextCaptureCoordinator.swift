//
//  PickyVoiceContextCaptureCoordinator.swift
//  Picky
//

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
    let settings: PickySettings
    let screenCaptures: [CompanionScreenCapture]
    let source: String
    let inkCapture: PickyInkCapture?
}

@MainActor
struct PickyVoiceContextCaptureCoordinator {
    typealias ScreenCapture = @MainActor (_ scope: PickyScreenContextScope, _ maximumDimension: Int) async throws -> [CompanionScreenCapture]
    typealias SettingsProvider = @MainActor () -> PickySettings
    typealias ContextAssembler = @MainActor (_ screenCaptures: [CompanionScreenCapture], _ source: String, _ transcript: String, _ inkCapture: PickyInkCapture?) async throws -> PickyContextPacket

    private let screenCapture: ScreenCapture
    private let settingsProvider: SettingsProvider
    private let contextAssembler: ContextAssembler

    init(
        screenCapture: @escaping ScreenCapture = { scope, maximumDimension in
            try await CompanionScreenCaptureUtility.captureScreensAsJPEG(
                scope: scope,
                maximumDimension: maximumDimension
            )
        },
        settingsProvider: @escaping SettingsProvider = { PickySettingsStore().load() },
        contextAssembler: @escaping ContextAssembler = PickyVoiceContextCaptureCoordinator.assembleContextPacket
    ) {
        self.screenCapture = screenCapture
        self.settingsProvider = settingsProvider
        self.contextAssembler = contextAssembler
    }

    func captureContext(
        transcript: String,
        voiceFollowUpSessionID: String?,
        inkCapture: PickyInkCapture? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        return try await captureContext(
            transcript: transcript,
            source: source,
            inkCapture: inkCapture
        )
    }

    func captureContext(
        transcript: String,
        source: String,
        inkCapture: PickyInkCapture? = nil
    ) async throws -> PickyVoiceContextCaptureResult? {
        guard let prepared = try await prepareContext(source: source, inkCapture: inkCapture) else { return nil }
        return try await assembleContext(prepared, transcript: transcript)
    }

    /// Starts the screen portion of a neutral context capture. Call this as
    /// soon as PTT is released, before transcription has finished.
    func prepareContext(
        source: String,
        inkCapture: PickyInkCapture? = nil
    ) async throws -> PickyPreparedVoiceContextCapture? {
        let captureID = UUID()
        let settings = settingsProvider()
        let screenCaptureStartedAt = Date()
        let screenCaptures = try await screenCapture(
            settings.screenContextScope,
            settings.screenshotQuality.maximumDimension
        )
        let screenCaptureMilliseconds = Int(Date().timeIntervalSince(screenCaptureStartedAt) * 1_000)
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=screenCaptureFinished captureID=\(captureID) source=\(source) ms=\(screenCaptureMilliseconds) screens=\(screenCaptures.count)"
        )
        guard !Task.isCancelled else { return nil }
        return PickyPreparedVoiceContextCapture(
            captureID: captureID,
            settings: settings,
            screenCaptures: screenCaptures,
            source: source,
            inkCapture: inkCapture
        )
    }

    /// Joins a prepared screen capture with the final STT transcript and
    /// assembles the packet that is sent to the agent.
    func assembleContext(
        _ prepared: PickyPreparedVoiceContextCapture,
        transcript: String
    ) async throws -> PickyVoiceContextCaptureResult? {
        guard !Task.isCancelled else { return nil }
        let contextAssemblyStartedAt = Date()
        let assembled = try await contextAssembler(
            prepared.screenCaptures,
            prepared.source,
            transcript,
            prepared.inkCapture
        )
        let contextAssemblyMilliseconds = Int(Date().timeIntervalSince(contextAssemblyStartedAt) * 1_000)
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=contextAssemblerFinished captureID=\(prepared.captureID) contextID=\(assembled.id) source=\(prepared.source) ms=\(contextAssemblyMilliseconds)"
        )
        let gated = Self.applyInkOnlyAttachmentGate(assembled, settings: prepared.settings)
        return PickyVoiceContextCaptureResult(contextPacket: gated, source: prepared.source)
    }

    /// Honors `PickySettings.attachScreenshotsOnlyWhenInked` by stripping
    /// screenshots/ink from the model-bound packet when the user did not draw
    /// during this turn. Screen capture and on-disk persistence have already
    /// happened by this point — only the model payload is gated.
    static func applyInkOnlyAttachmentGate(
        _ packet: PickyContextPacket,
        settings: PickySettings
    ) -> PickyContextPacket {
        guard settings.attachScreenshotsOnlyWhenInked else { return packet }
        guard packet.inkMarks.isEmpty else { return packet }
        return packet.withScreenshotsCleared()
    }

    private static func assembleContextPacket(
        screenCaptures: [CompanionScreenCapture],
        source: String,
        transcript: String,
        inkCapture: PickyInkCapture?
    ) async throws -> PickyContextPacket {
        let assembler = PickyContextPacketAssembler(
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
        return try await assembler.assemble(source: source, transcript: transcript)
    }
}

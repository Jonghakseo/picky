//
//  CompanionManager+AgentAnnotationOverlay.swift
//  Picky
//
//  Agent-driven screen overlays: pointer/annotation requests, visual narration
//  segments, and annotation scene baseline tracking. CompanionManager remains
//  the sole mutable owner of all referenced state.
//

import AppKit
import Foundation
import OSLog

@MainActor
extension CompanionManager {
    func applyVisualNarrationSegmentPrepared(
        _ segment: PickyVisualNarrationSegmentPreparedEvent
    ) {
        guard shouldApplyOverlay(
            contextID: segment.identity.contextId,
            generation: segment.identity.contextGeneration
        ) else { return }
        do {
            let visual: PickyResolvedVisualNarrationVisual
            switch segment.visual {
            case .point(let request):
                guard request.contextId == segment.identity.contextId,
                      request.contextGeneration == segment.identity.contextGeneration else { return }
                let target = try PickyPointerOverlayResolver.resolve(request)
                visual = .point(PickyPointerTarget(
                    id: request.id,
                    source: .agent,
                    screenLocation: target.screenLocation,
                    displayFrame: target.displayFrame,
                    bubbleText: target.bubbleText,
                    duration: target.duration
                ))
            case .annotations(let request):
                guard request.contextId == segment.identity.contextId,
                      request.contextGeneration == segment.identity.contextGeneration else { return }
                let (annotations, screenshot) = try resolveAgentAnnotations(request)
                prepareAnnotationSceneIfNeeded(
                    request: request,
                    screenshot: screenshot,
                    annotations: annotations
                )
                visual = .annotations(annotations)
            }
            interactionCoordinator.accept(
                .visualNarrationSegmentPrepared(identity: segment.identity, visual: visual),
                correlation: PickyInteractionCorrelation(contextID: segment.identity.contextId, source: .agent)
            )
        } catch {
            PickyLog.logger(.agentClient).debug(
                "Visual narration segment prepare ignored ordinal=\(segment.identity.ordinal) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func applyVisualNarrationSegmentSentence(
        _ sentence: PickyVisualNarrationSegmentSentenceEvent
    ) {
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=visualNarrationSentenceReceived contextID=\(sentence.identity.contextId) sessionID=\(sentence.sessionId ?? "none") ordinal=\(sentence.identity.ordinal) index=\(sentence.index) chars=\(sentence.text.count)"
        )
        guard shouldApplyOverlay(
            contextID: sentence.identity.contextId,
            generation: sentence.identity.contextGeneration
        ) else { return }
        let playbackMode: PickyVisualNarrationPlaybackMode
        if !ttsPlaybackEnabled {
            playbackMode = .silent
        } else if speechPlaybackProvider.supportsIncrementalPlayback {
            playbackMode = .incremental
        } else {
            playbackMode = .finalReply
        }
        let owner = interactionOwner(for: sentence.identity.contextId)
        let originSource = sentence.originSource ?? owner.map { $0.isVoiceOwned ? .voice : .text }
        interactionCoordinator.accept(
            .visualNarrationSegmentSentence(
                identity: sentence.identity,
                index: sentence.index,
                text: sentence.text,
                originSource: originSource,
                replyKind: sentence.replyKind ?? .main,
                sessionID: sentence.sessionId,
                playbackMode: playbackMode
            ),
            correlation: PickyInteractionCorrelation(
                contextID: sentence.identity.contextId,
                sessionID: sentence.sessionId,
                source: .agent
            )
        )
    }

    func applyVisualNarrationSegmentCommitted(
        _ segment: PickyVisualNarrationSegmentCommittedEvent
    ) {
        guard shouldApplyOverlay(
            contextID: segment.identity.contextId,
            generation: segment.identity.contextGeneration
        ) else { return }
        interactionCoordinator.accept(
            .visualNarrationSegmentCommitted(
                identity: segment.identity,
                text: segment.text,
                sentenceCount: segment.sentenceCount
            ),
            correlation: PickyInteractionCorrelation(
                contextID: segment.identity.contextId,
                sessionID: segment.sessionId,
                source: .agent
            )
        )
    }

    func applyPointerOverlayRequest(_ request: PickyPointerOverlayRequest) {
        guard shouldApplyOverlay(contextID: request.contextId, generation: request.contextGeneration) else { return }
        do {
            let target = try PickyPointerOverlayResolver.resolve(request)
            interactionCoordinator.accept(
                .pointerRequested(PickyPointerTarget(
                    id: request.id,
                    source: .agent,
                    screenLocation: target.screenLocation,
                    displayFrame: target.displayFrame,
                    bubbleText: target.bubbleText,
                    duration: target.duration
                )),
                correlation: PickyInteractionCorrelation(pointerID: request.id, source: .pointer)
            )
            latestAgentSessionSummary = target.bubbleText.map { L10n.t("agent.summary.pointingScreen", $0) } ?? L10n.t("agent.summary.pointingScreenAnon")
        } catch {
            latestAgentSessionSummary = "Pointer overlay ignored: \(error.localizedDescription)"
        }
    }

    func applyAnnotationOverlayRequest(_ request: PickyAnnotationOverlayRequest) {
        if request.mode == .clear {
            annotationBasePaletteByTurnScreen.removeAll()
            annotationSceneMonitor?.stop()
            activeAnnotationSceneIdentity = nil
            interactionCoordinator.accept(
                .agentAnnotationsRequested(mode: .clear, annotations: []),
                correlation: PickyInteractionCorrelation(source: .agent)
            )
            return
        }
        guard shouldApplyOverlay(contextID: request.contextId, generation: request.contextGeneration) else { return }
        do {
            let (annotations, screenshot) = try resolveAgentAnnotations(request)
            prepareAnnotationSceneIfNeeded(
                request: request,
                screenshot: screenshot,
                annotations: annotations
            )
            interactionCoordinator.accept(
                .agentAnnotationsRequested(mode: request.mode, annotations: annotations),
                correlation: PickyInteractionCorrelation(contextID: request.contextId, source: .agent)
            )
            if request.mode != .clear {
                latestAgentSessionSummary = "Showing \(annotations.count) screen annotation\(annotations.count == 1 ? "" : "s")."
            }
        } catch {
            latestAgentSessionSummary = "Annotation overlay ignored: \(error.localizedDescription)"
        }
    }

    func resolveAgentAnnotations(
        _ request: PickyAnnotationOverlayRequest
    ) throws -> ([PickyAgentAnnotation], PickyScreenshotContext?) {
        let screenshotSize = request.screenshotSize.map { CGSize(width: $0.width, height: $0.height) }
        let screenshot = overlayScreenshot(for: request)
        let sampleGrid = screenshot?.annotationColorSampleGrid
        let paletteKey = annotationPaletteKey(for: request)
        if request.mode == .replace {
            annotationBasePaletteByTurnScreen[paletteKey] = nil
        }
        let basePalette = annotationBasePaletteByTurnScreen[paletteKey]
            ?? screenshotSize.flatMap {
                PickyAnnotationPaletteResolver.basePalette(
                    for: request.annotations,
                    screenshotSize: $0,
                    sampleGrid: sampleGrid
                )
            }
        let annotations = try PickyAnnotationOverlayResolver.resolve(
            request,
            sampleGrid: sampleGrid,
            preferredBasePalette: basePalette
        )
        if let basePalette {
            annotationBasePaletteByTurnScreen[paletteKey] = basePalette
        }
        return (annotations, screenshot)
    }

    func noteMainOverlayContext(_ context: PickyContextPacket) {
        annotationSceneMonitor?.stop()
        activeAnnotationSceneIdentity = nil
        latestOverlayContextID = context.id
        latestOverlayContextGeneration = 0
        latestAnnotationSceneBaseline = PickyAnnotationSceneBaseline.capture(from: context)
        annotationBasePaletteByTurnScreen.removeAll()
        latestOverlayScreenshotsByID = context.screenshots.reduce(into: [:]) { result, screenshot in
            result[screenshot.id] = screenshot
            if let screenID = screenshot.screenId {
                result[screenID] = screenshot
            }
        }
    }

    func prepareAnnotationSceneIfNeeded(
        request: PickyAnnotationOverlayRequest,
        screenshot: PickyScreenshotContext?,
        annotations: [PickyAgentAnnotation]
    ) {
        guard let monitor = annotationSceneMonitor,
              let baseline = latestAnnotationSceneBaseline,
              let contextID = request.contextId,
              let generation = request.contextGeneration,
              baseline.contextID == contextID,
              let screenshot else {
            return
        }
        let identity: PickyAnnotationSceneIdentity
        if let active = activeAnnotationSceneIdentity,
           active.contextID == contextID,
           active.generation == generation {
            identity = active
        } else {
            identity = PickyAnnotationSceneIdentity(
                contextID: contextID,
                generation: generation,
                token: UUID()
            )
            activeAnnotationSceneIdentity = identity
            interactionCoordinator.accept(
                .agentAnnotationScenePrepared(identity: identity),
                correlation: PickyInteractionCorrelation(contextID: contextID, source: .system)
            )
            monitor.start(
                identity: identity,
                baseline: baseline,
                allowsTolerantRestoration: true
            )
        }
        monitor.updateTarget(
            screenshot: screenshot,
            annotations: annotations,
            mode: request.mode
        )
    }

    func applyAnnotationSceneMonitorOutput(_ output: PickyAnnotationSceneMonitorOutput) {
        let identity: PickyAnnotationSceneIdentity
        let event: PickyInteractionEvent
        switch output {
        case .matched(let matchedIdentity):
            identity = matchedIdentity
            event = .agentAnnotationSceneMatched(identity: matchedIdentity)
        case .mismatched(let mismatchedIdentity, let reason):
            identity = mismatchedIdentity
            event = .agentAnnotationSceneMismatched(identity: mismatchedIdentity, reason: reason)
        }
        guard activeAnnotationSceneIdentity == identity else {
            PickyLog.logger(.annotationScene).debug(
                "dropping stale monitor output context=\(identity.contextID, privacy: .public) generation=\(identity.generation)"
            )
            return
        }
        interactionCoordinator.accept(
            event,
            correlation: PickyInteractionCorrelation(contextID: identity.contextID, source: .system)
        )
    }

    func annotationPaletteKey(for request: PickyAnnotationOverlayRequest) -> String {
        "\(request.contextId ?? "none"):\(request.contextGeneration ?? -1):\(request.screenId ?? "default")"
    }

    func overlayScreenshot(for request: PickyAnnotationOverlayRequest) -> PickyScreenshotContext? {
        guard request.contextId == latestOverlayContextID else { return nil }
        if let screenID = request.screenId, let screenshot = latestOverlayScreenshotsByID[screenID] {
            return screenshot
        }
        return latestOverlayScreenshotsByID.values.first(where: { $0.isCursorScreen == true })
            ?? latestOverlayScreenshotsByID.values.first
    }

    func shouldApplyOverlay(contextID: String?, generation: Int?) -> Bool {
        guard let contextID, let generation else {
            if latestOverlayContextID != nil {
                PickyLog.logger(.agentClient).debug("Dropping overlay without a capture generation after a newer context was submitted")
                return false
            }
            return true
        }
        if let latestOverlayContextID, contextID != latestOverlayContextID {
            PickyLog.logger(.agentClient).debug("Dropping stale overlay context=\(contextID, privacy: .public) latest=\(latestOverlayContextID, privacy: .public)")
            return false
        }
        if generation < latestOverlayContextGeneration {
            PickyLog.logger(.agentClient).debug("Dropping stale overlay generation=\(generation) latest=\(self.latestOverlayContextGeneration)")
            return false
        }
        latestOverlayContextID = contextID
        latestOverlayContextGeneration = generation
        return true
    }
}

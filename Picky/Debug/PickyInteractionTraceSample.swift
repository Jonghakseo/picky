//
//  PickyInteractionTraceSample.swift
//  Picky
//
//  Turns one dispatched interaction event into a redacted `picky-debug` trace
//  record. This is the app-side redaction allowlist: the top-level switch is
//  exhaustive on purpose so a new interaction event cannot silently join the
//  trace without someone deciding what metadata it may expose.
//

import Foundation

/// One dispatched interaction event plus the states around it. Produced by
/// `PickyInteractionCoordinator` and consumed by `PickyDebugTraceRecorder`.
struct PickyInteractionTraceSample {
    let event: PickyInteractionEvent
    let correlation: PickyInteractionCorrelation
    let previousState: PickyInteractionState
    let state: PickyInteractionState
    let sequence: UInt64
    /// True when the runtime produced a stale projection that was dropped, so
    /// the published state did not change.
    let dropped: Bool
}

/// Allowlisted facts extracted from an interaction event. Everything here is a
/// label, an identifier, or a count — never user content.
struct PickyInteractionTraceFacts: Equatable {
    var name: String
    var inputID: UUID?
    var contextID: String?
    var sessionID: String?
    var textLength: Int?
    var modality: PickyDebugTraceModality?
    var outcome: String?
    var target: String?

    init(
        name: String,
        inputID: UUID? = nil,
        contextID: String? = nil,
        sessionID: String? = nil,
        textLength: Int? = nil,
        modality: PickyDebugTraceModality? = nil,
        outcome: String? = nil,
        target: String? = nil
    ) {
        self.name = name
        self.inputID = inputID
        self.contextID = contextID
        self.sessionID = sessionID
        self.textLength = textLength
        self.modality = modality
        self.outcome = outcome
        self.target = target
    }
}

enum PickyInteractionTraceMapper {
    static func record(
        _ sample: PickyInteractionTraceSample,
        now: Date = Date(),
        monotonicMs: Double = PickyDebugTraceClock.monotonicMs()
    ) -> PickyDebugTraceRecord {
        let facts = facts(for: sample.event)
        let previousSummary = sample.previousState.debugPhaseSummary
        let summary = sample.dropped ? previousSummary : sample.state.debugPhaseSummary
        return PickyDebugTraceRecord(
            source: .app,
            name: "interaction.\(facts.name)",
            timestamp: now,
            monotonicMs: monotonicMs,
            inputId: (facts.inputID ?? sample.correlation.inputID ?? createdVoiceInputID(sample))?.uuidString,
            contextId: facts.contextID ?? sample.correlation.contextID,
            sessionId: facts.sessionID ?? sample.correlation.sessionID,
            commandId: nil,
            state: summary,
            previousState: previousSummary,
            outcome: sample.dropped ? "staleDropped" : facts.outcome,
            event: sample.correlation.source.rawValue,
            target: facts.target,
            modality: facts.modality,
            textLength: facts.textLength
        )
    }

    /// `voicePressed` carries no input id of its own: the reducer mints one and
    /// parks it in the published state. Reading it back from that state is what
    /// lets an ordinary voice turn be followed by identity, with no timestamp
    /// adjacency involved. A dropped projection has no new input to report.
    private static func createdVoiceInputID(_ sample: PickyInteractionTraceSample) -> UUID? {
        guard case .voicePressed = sample.event, !sample.dropped else { return nil }
        guard case .voiceListening(let inputID, _) = sample.state.input else { return nil }
        return inputID
    }

    /// Exhaustive by design. Adding an interaction event must fail to compile
    /// here until its redaction decision is made.
    static func facts(for event: PickyInteractionEvent) -> PickyInteractionTraceFacts {
        switch event {
        case .appStarted, .permissionsChanged, .cursorPreferenceChanged:
            return lifecycleFacts(event)
        case .voicePressed, .voiceStartFailed, .voiceReleased, .transcriptFinal, .transcriptFailed,
             .textSubmitted, .textContextCaptured, .textSubmissionAccepted, .textSubmissionFailed,
             .pickleInputSubmitted, .voiceContextCaptured, .externalContextCaptured, .remoteContextCaptured,
             .agentSubmissionAccepted:
            return inputFacts(event)
        case .quickReply, .narrationChunk, .streamedQuickReplyFinal, .passiveAgentSummary,
             .pickleCompleted, .mainTurnSettled, .mainAgentSessionReset, .sessionTerminated:
            return replyFacts(event)
        case .visualNarrationSegmentPrepared, .visualNarrationSegmentSentence,
             .visualNarrationSegmentCommitted, .agentAnnotationsRequested,
             .agentAnnotationScenePrepared, .agentAnnotationSceneMatched,
             .agentAnnotationSceneMismatched, .agentAnnotationRecoveryExpired,
             .agentAnnotationRevealDue, .agentAnnotationsClearedForUserInput:
            return visualFacts(event)
        case .pointerRequested, .pointerCancelled, .pointerAnimationParked,
             .pointerAnimationFinished, .speechStarted, .speechFinished, .speechFailed,
             .minimumDisplayTimerFired, .overlayShown, .overlayHidden, .transientHideTimerFired:
            return presentationFacts(event)
        }
    }

    private static func lifecycleFacts(_ event: PickyInteractionEvent) -> PickyInteractionTraceFacts {
        switch event {
        case .permissionsChanged(let snapshot):
            return .init(name: "permissionsChanged", outcome: snapshot.debugGrantSummary)
        case .cursorPreferenceChanged(let enabled):
            return .init(name: "cursorPreferenceChanged", outcome: enabled ? "enabled" : "disabled")
        default:
            return .init(name: "appStarted")
        }
    }

    private static func inputFacts(_ event: PickyInteractionEvent) -> PickyInteractionTraceFacts {
        switch event {
        case .voicePressed(let targetSessionID):
            return .init(name: "voicePressed", sessionID: targetSessionID, modality: .audio)
        case .voiceStartFailed(_, let inputID):
            return .init(name: "voiceStartFailed", inputID: inputID, modality: .audio, outcome: "failed")
        case .voiceReleased(let inputID):
            return .init(name: "voiceReleased", inputID: inputID, modality: .audio)
        case .transcriptFinal(let text, let inputID):
            return .init(name: "transcriptFinal", inputID: inputID, textLength: text.utf16.count, modality: .audio)
        case .transcriptFailed(_, let inputID):
            return .init(name: "transcriptFailed", inputID: inputID, modality: .audio, outcome: "failed")
        case .textSubmitted(let text, let inputID):
            return .init(name: "textSubmitted", inputID: inputID, textLength: text.utf16.count, modality: .text)
        case .textContextCaptured(let inputID, let context):
            return .init(name: "textContextCaptured", inputID: inputID, contextID: context.id, modality: .text)
        case .textSubmissionAccepted(let contextID, let inputID):
            return .init(
                name: "textSubmissionAccepted",
                inputID: inputID,
                contextID: contextID,
                modality: .text,
                outcome: "accepted"
            )
        case .textSubmissionFailed(_, let inputID):
            return .init(name: "textSubmissionFailed", inputID: inputID, modality: .text, outcome: "failed")
        case .pickleInputSubmitted(let sessionID):
            return .init(name: "pickleInputSubmitted", sessionID: sessionID, modality: .text)
        case .voiceContextCaptured(let inputID, let transcript, let context, let targetSessionID):
            return .init(
                name: "voiceContextCaptured",
                inputID: inputID,
                contextID: context.id,
                sessionID: targetSessionID,
                textLength: transcript.utf16.count,
                modality: .audio
            )
        case .externalContextCaptured(let inputID, let text, let context):
            return .init(
                name: "externalContextCaptured",
                inputID: inputID,
                contextID: context.id,
                textLength: text.utf16.count,
                modality: .text
            )
        case .remoteContextCaptured(let context):
            return .init(name: "remoteContextCaptured", contextID: context.id, modality: .text)
        default:
            guard case .agentSubmissionAccepted(let contextID, let sessionID, let inputID) = event else {
                return .init(name: "unknownInput")
            }
            return .init(
                name: "agentSubmissionAccepted",
                inputID: inputID,
                contextID: contextID,
                sessionID: sessionID,
                outcome: "accepted"
            )
        }
    }

    private static func replyFacts(_ event: PickyInteractionEvent) -> PickyInteractionTraceFacts {
        switch event {
        case .quickReply(let contextID, let text, let origin, let kind, let sessionID, let inputID):
            return .init(
                name: "quickReply",
                inputID: inputID,
                contextID: contextID,
                sessionID: sessionID,
                textLength: text.utf16.count,
                outcome: kind?.rawValue,
                target: origin?.rawValue
            )
        case .narrationChunk(let contextID, let text, let origin, let kind, let sessionID, _, _):
            return .init(
                name: "narrationChunk",
                contextID: contextID,
                sessionID: sessionID,
                textLength: text.utf16.count,
                outcome: kind?.rawValue,
                target: origin?.rawValue
            )
        case .streamedQuickReplyFinal(let contextID, let text, let origin, let kind, let sessionID, let inputID):
            return .init(
                name: "streamedQuickReplyFinal",
                inputID: inputID,
                contextID: contextID,
                sessionID: sessionID,
                textLength: text.utf16.count,
                outcome: kind?.rawValue,
                target: origin?.rawValue
            )
        case .passiveAgentSummary(let sessionID, let text):
            return .init(name: "passiveAgentSummary", sessionID: sessionID, textLength: text.utf16.count)
        case .pickleCompleted(let sessionID, let summary):
            return .init(
                name: "pickleCompleted",
                sessionID: sessionID,
                textLength: summary?.utf16.count,
                outcome: "completed"
            )
        case .mainTurnSettled(let contextID):
            return .init(name: "mainTurnSettled", contextID: contextID, outcome: "settled")
        case .sessionTerminated(let sessionID):
            return .init(name: "sessionTerminated", sessionID: sessionID, outcome: "terminated")
        default:
            return .init(name: "mainAgentSessionReset", outcome: "reset")
        }
    }

    private static func visualFacts(_ event: PickyInteractionEvent) -> PickyInteractionTraceFacts {
        switch event {
        case .visualNarrationSegmentPrepared(let identity, _):
            return .init(
                name: "visualNarrationSegmentPrepared",
                contextID: identity.contextId,
                target: identity.segmentId
            )
        case .visualNarrationSegmentSentence(let identity, let index, let text, _, _, let sessionID, let mode):
            return .init(
                name: "visualNarrationSegmentSentence",
                contextID: identity.contextId,
                sessionID: sessionID,
                textLength: text.utf16.count,
                outcome: "\(mode.rawValue)#\(index)",
                target: identity.segmentId
            )
        case .visualNarrationSegmentCommitted(let identity, let text, let sentenceCount):
            return .init(
                name: "visualNarrationSegmentCommitted",
                contextID: identity.contextId,
                textLength: text?.utf16.count,
                outcome: "sentences=\(sentenceCount)",
                target: identity.segmentId
            )
        case .agentAnnotationsRequested(let mode, let annotations):
            return .init(name: "agentAnnotationsRequested", outcome: "\(mode.rawValue)#\(annotations.count)")
        case .agentAnnotationScenePrepared(let identity):
            return .init(name: "agentAnnotationScenePrepared", contextID: identity.contextID)
        case .agentAnnotationSceneMatched(let identity):
            return .init(name: "agentAnnotationSceneMatched", contextID: identity.contextID, outcome: "matched")
        case .agentAnnotationSceneMismatched(let identity, let reason):
            return .init(
                name: "agentAnnotationSceneMismatched",
                contextID: identity.contextID,
                outcome: reason.rawValue
            )
        case .agentAnnotationRecoveryExpired(let identity):
            return .init(name: "agentAnnotationRecoveryExpired", contextID: identity.contextID, outcome: "expired")
        case .agentAnnotationRevealDue(let id):
            return .init(name: "agentAnnotationRevealDue", target: id.uuidString)
        default:
            return .init(name: "agentAnnotationsClearedForUserInput", outcome: "cleared")
        }
    }

    private static func presentationFacts(_ event: PickyInteractionEvent) -> PickyInteractionTraceFacts {
        switch event {
        case .pointerRequested(let target):
            return .init(name: "pointerRequested", target: target.id)
        case .pointerCancelled(let pointerID, let reason):
            return .init(name: "pointerCancelled", outcome: reason.rawValue, target: pointerID)
        case .pointerAnimationParked(let pointerID):
            return .init(name: "pointerAnimationParked", target: pointerID)
        case .pointerAnimationFinished(let pointerID):
            return .init(name: "pointerAnimationFinished", target: pointerID)
        case .speechStarted(let text, let speechID, let sourceContextID):
            return .init(
                name: "speechStarted",
                contextID: sourceContextID,
                textLength: text.utf16.count,
                target: speechID.uuidString
            )
        case .speechFinished(let speechID):
            return .init(name: "speechFinished", outcome: "finished", target: speechID.uuidString)
        case .speechFailed(let speechID):
            return .init(name: "speechFailed", outcome: "failed", target: speechID.uuidString)
        case .minimumDisplayTimerFired(let timerID, _, let inputID):
            return .init(name: "minimumDisplayTimerFired", inputID: inputID, target: timerID.uuidString)
        case .overlayShown(let reason):
            return .init(name: "overlayShown", outcome: reason.rawValue)
        case .overlayHidden(let reason):
            return .init(name: "overlayHidden", outcome: reason.rawValue)
        default:
            guard case .transientHideTimerFired(let timerID) = event else {
                return .init(name: "unknownPresentation")
            }
            return .init(name: "transientHideTimerFired", target: timerID.uuidString)
        }
    }
}

extension PickyInteractionState {
    /// Compact phase triple, well under the 96-character label bound. This is
    /// deliberately not an encoding of the whole state: only the phases that
    /// describe where an input currently sits are exposed.
    var debugPhaseSummary: String {
        "in=\(input.debugLabel) out=\(output.debugLabel) overlay=\(overlay.debugLabel)"
    }
}

extension PickyInputPhase {
    var debugLabel: String {
        switch self {
        case .idle: "idle"
        case .voiceListening: "voiceListening"
        case .voiceFinalizing: "voiceFinalizing"
        case .voiceSubmitting: "voiceSubmitting"
        case .textSubmitting: "textSubmitting"
        }
    }
}

extension PickyOutputPhase {
    var debugLabel: String {
        switch self {
        case .idle: "idle"
        case .waitingForAgent: "waitingForAgent"
        case .showingTextReply: "showingTextReply"
        case .speaking: "speaking"
        case .suppressedReply: "suppressedReply"
        }
    }
}

extension PickyOverlayPhase {
    var debugLabel: String {
        switch self {
        case .hidden: "hidden"
        case .visible(let reasons): "visible#\(reasons.count)"
        case .hiding: "hiding"
        }
    }
}

extension PickyPermissionSnapshot {
    /// Four-slot grant mask. Order: accessibility, screen, mic, speech.
    var debugGrantSummary: String {
        func flag(_ granted: Bool) -> String { granted ? "1" : "0" }
        return "ax\(flag(accessibilityGranted)) screen\(flag(screenRecordingGranted))"
            + " mic\(flag(microphoneGranted)) speech\(flag(speechRecognitionGranted))"
    }
}

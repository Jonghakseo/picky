//
//  PickyInteractionAnnotationReducer.swift
//  Picky
//
//  Pure annotation scene, reveal, recovery, and pointer-turn transitions.
//

import Foundation

extension PickyInteractionReducing {
    // MARK: - Agent annotations

    mutating func applyAgentAnnotationsRequested(mode: PickyAnnotationOverlayMode, annotations: [PickyAgentAnnotation]) {
        switch mode {
        case .clear:
            clearAgentAnnotations(resetNarration: true)
        case .replace:
            state.pendingAgentAnnotations = []
            state.dueAgentAnnotationIDs = []
            state.agentAnnotations = []
            state.agentAnnotationsDismissible = false
            state = state.removingOverlayReason(.activeAgentAnnotations)
            for annotation in annotations { bufferOrRevealAnnotation(annotation) }
        case .append:
            if !annotations.isEmpty { state.agentAnnotationsDismissible = false }
            for annotation in annotations { bufferOrRevealAnnotation(annotation) }
        }
        record(.stateChanged, "Agent annotations \(mode.rawValue)")
    }

    mutating func applyAgentAnnotationScenePrepared(identity: PickyAnnotationSceneIdentity) {
        if state.annotationSceneIdentity != identity {
            state.pendingAgentAnnotations = []
            state.dueAgentAnnotationIDs = []
            state.agentAnnotations = []
            clearVisualAnnotationNarrationState()
            endAnnotationPointerTurn(discardingPendingTargets: true)
        }
        state.annotationSceneIdentity = identity
        state.annotationScenePhase = .validating
        state.annotationSceneRecoveryAllowed = true
        state.agentAnnotationsDismissible = false
        state = state.removingOverlayReason(.activeAgentAnnotations)
        record(.stateChanged, "Agent annotation scene validating")
    }

    mutating func applyAgentAnnotationSceneMatched(identity: PickyAnnotationSceneIdentity) {
        guard state.annotationSceneIdentity == identity else {
            record(.staleEvent, "Ignored stale annotation scene match")
            return
        }
        let wasValidating = state.annotationScenePhase == .validating
        state.annotationScenePhase = .visible
        if !state.agentAnnotations.isEmpty {
            state = state.addingOverlayReason(.activeAgentAnnotations)
            if wasValidating, annotationSpeechActive {
                enqueueAnnotationPointerTargets(state.agentAnnotations)
            }
        }
        record(.stateChanged, wasValidating ? "Agent annotation scene validated" : "Agent annotations resumed")
    }

    mutating func applyAgentAnnotationSceneMismatched(
        identity: PickyAnnotationSceneIdentity,
        reason: PickyAnnotationSceneMismatchReason
    ) {
        guard state.annotationSceneIdentity == identity else {
            record(.staleEvent, "Ignored stale annotation scene mismatch")
            return
        }
        guard state.annotationSceneRecoveryAllowed else {
            cancelAnnotationPointerForSceneSuspension()
            clearAgentAnnotations(resetNarration: true)
            record(.stateChanged, "Agent annotations cleared after narration: \(reason.rawValue)")
            return
        }
        state.annotationScenePhase = .suspended
        state = state.removingOverlayReason(.activeAgentAnnotations)
        cancelAnnotationPointerForSceneSuspension()
        record(.stateChanged, "Agent annotations suspended: \(reason.rawValue)")
    }

    /// Buffers a streamed annotation so the overlay cannot show it before narration
    /// reaches its position. Once narration has ended it reveals immediately instead.
    mutating func bufferOrRevealAnnotation(_ annotation: PickyAgentAnnotation) {
        let pending = PickyPendingAgentAnnotation(
            id: UUID(),
            annotation: annotation,
            precedingNarrationWeight: state.annotationNarrationWeight,
            silentTurnSequence: state.annotationArrivalSequence
        )
        state.annotationArrivalSequence += 1
        state.pendingAgentAnnotations.append(pending)
        let overflow = max(0, state.pendingAgentAnnotations.count - PickyInteractionReducer.maximumAgentAnnotationCount)
        if overflow > 0 {
            let removedIDs = state.pendingAgentAnnotations.prefix(overflow).map(\.id)
            state.pendingAgentAnnotations.removeFirst(overflow)
            state.dueAgentAnnotationIDs.subtract(removedIDs)
        }
        if let anchor = state.annotationSpeechAnchor {
            scheduleAnnotationReveal(pending, anchor: anchor)
        }
    }

    /// Reveals only the annotations from a silent Pickle DSL request. Other buffered
    /// annotations keep their own narration timing, even when unrelated speech is active.
    mutating func revealSilentAnnotations(annotationIDs: [String]) {
        let ids = Set(annotationIDs)
        guard !ids.isEmpty else { return }
        var remaining: [PickyPendingAgentAnnotation] = []
        for pending in state.pendingAgentAnnotations {
            if ids.contains(pending.annotation.id) {
                state.dueAgentAnnotationIDs.remove(pending.id)
                revealAnnotation(pending.annotation, animatePointer: false)
            } else {
                remaining.append(pending)
            }
        }
        state.pendingAgentAnnotations = remaining
        state.agentAnnotationsDismissible = state.annotationScenePhase != .suspended && !state.agentAnnotations.isEmpty
        record(.stateChanged, "Silent annotations revealed")
    }

    /// First accepted TTS start anchors reveal timing; schedule every buffered reveal.
    mutating func applyAnnotationSpeechStarted(now: Date) {
        guard state.annotationSpeechAnchor == nil else { return }
        state.agentAnnotationsDismissible = false
        state.annotationSpeechAnchor = now
        for pending in state.pendingAgentAnnotations {
            scheduleAnnotationReveal(pending, anchor: now)
        }
    }

    mutating func scheduleAnnotationReveal(_ pending: PickyPendingAgentAnnotation, anchor: Date) {
        let revealAt = anchor.addingTimeInterval(
            PickyNarrationPaceModel.speechPrerollSeconds
                + pending.precedingNarrationWeight * PickyNarrationPaceModel.secondsPerWeightUnit
        )
        let delay = max(0, revealAt.timeIntervalSince(envelope.occurredAt))
        effects.append(.scheduleAnnotationReveal(id: pending.id, delay: delay))
    }

    mutating func applyAnnotationRevealDue(id: UUID) {
        guard state.pendingAgentAnnotations.contains(where: { $0.id == id }) else {
            record(.staleEvent, "Ignored stale annotation reveal")
            return
        }
        state.dueAgentAnnotationIDs.insert(id)

        // Equal/overdue Task.sleep deadlines can resume in arbitrary order. Only
        // drain a due annotation after every earlier stream item is also due so
        // both drawing appearance and buddy traversal remain source-order FIFO.
        while let pending = state.pendingAgentAnnotations.first,
              state.dueAgentAnnotationIDs.remove(pending.id) != nil {
            state.pendingAgentAnnotations.removeFirst()
            revealAnnotation(pending.annotation)
        }
    }

    /// Stores an annotation and, when its original scene is visible, sends the buddy
    /// to it. Scene validation may keep the geometry resident but absent from projection.
    mutating func revealAnnotation(_ annotation: PickyAgentAnnotation, animatePointer: Bool = true) {
        if let index = state.agentAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            state.agentAnnotations[index] = annotation
        } else {
            state.agentAnnotations.append(annotation)
        }
        let overflow = max(0, state.agentAnnotations.count - PickyInteractionReducer.maximumAgentAnnotationCount)
        if overflow > 0 { state.agentAnnotations.removeFirst(overflow) }
        if state.annotationScenePhase.presentsAnnotations {
            state = state.addingOverlayReason(.activeAgentAnnotations)
            if animatePointer {
                enqueueAnnotationPointerTargets([annotation])
            }
        }
        record(.stateChanged, "Annotation revealed")
    }

    /// True while the turn still has audio playing or queued.
    var annotationSpeechActive: Bool {
        if case .speaking = state.output { return true }
        return !state.queuedSpeechReplies.isEmpty
    }

    /// The turn produced its terminal reply/settlement. If no audio is (or will be)
    /// playing, narration is over now, so conclude immediately; otherwise wait for the
    /// speech to drain (handled in `concludeAnnotationTurnIfSettled`).
    mutating func markAnnotationTurnSettled() {
        state.annotationTurnSettled = true
        if !annotationSpeechActive {
            concludeAnnotationTurn()
        }
    }

    /// Narration is over: a scene that disappeared during speech is no longer useful,
    /// so discard it rather than polling for a later restoration. A still-matching scene
    /// keeps its drawings, but the next mismatch clears them permanently.
    mutating func concludeAnnotationTurn() {
        // Narration ended, but keep the scene recoverable for a grace window so a brief
        // context switch hides and then restores the drawings instead of clearing them
        // outright. If the scene was suspended when narration ended, hold it suspended
        // rather than clearing immediately. A timer lapses the window later.
        let hadSpeech = state.annotationSpeechAnchor != nil
        while !state.pendingAgentAnnotations.isEmpty {
            revealAnnotation(state.pendingAgentAnnotations.removeFirst().annotation, animatePointer: false)
        }
        if hadSpeech {
            for index in state.agentAnnotations.indices {
                state.agentAnnotations[index].spotlight = false
            }
        }
        state.dueAgentAnnotationIDs = []
        state.annotationNarrationWeight = 0
        state.annotationSpeechAnchor = nil
        state.annotationTurnSettled = false
        state.annotationArrivalSequence = 0
        state.agentAnnotationsDismissible = state.annotationScenePhase != .suspended && !state.agentAnnotations.isEmpty
        endAnnotationPointerTurn(discardingPendingTargets: true)
        if state.annotationSceneRecoveryAllowed, let identity = state.annotationSceneIdentity {
            effects.append(.scheduleAnnotationRecoveryExpiry(
                identity: identity,
                delay: PickyInteractionReducer.annotationRecoveryGraceAfterNarration
            ))
        }
    }

    /// The post-narration recovery grace has elapsed. A scene the user never returned to
    /// (still suspended) is cleared for good; a restored/kept scene simply stops
    /// recovering, so the next mismatch clears it.
    mutating func applyAnnotationRecoveryExpired(identity: PickyAnnotationSceneIdentity) {
        guard state.annotationSceneIdentity == identity, state.annotationSceneRecoveryAllowed else {
            record(.staleEvent, "Ignored stale annotation recovery expiry")
            return
        }
        if state.annotationScenePhase == .suspended {
            clearAgentAnnotations(resetNarration: true)
            record(.stateChanged, "Suspended agent annotations cleared after recovery grace")
            return
        }
        state.annotationSceneRecoveryAllowed = false
        state.agentAnnotationsDismissible = !state.agentAnnotations.isEmpty
        record(.stateChanged, "Annotation recovery grace elapsed; scene locked")
    }

    mutating func concludeAnnotationTurnIfSettled() {
        guard state.annotationTurnSettled, !annotationSpeechActive else { return }
        concludeAnnotationTurn()
    }

    mutating func clearAgentAnnotationsForUserInput() {
        clearAgentAnnotations(resetNarration: true)
        clearProgressiveNarrationState()
        record(.stateChanged, "Agent annotations cleared for user input")
    }

    mutating func clearAgentAnnotations(resetNarration: Bool) {
        state.pendingAgentAnnotations = []
        state.dueAgentAnnotationIDs = []
        state.agentAnnotations = []
        state.annotationSceneIdentity = nil
        state.annotationScenePhase = .inactive
        state.annotationSceneRecoveryAllowed = false
        state.agentAnnotationsDismissible = false
        if resetNarration {
            state.annotationNarrationWeight = 0
            state.annotationSpeechAnchor = nil
            state.annotationTurnSettled = false
            state.annotationArrivalSequence = 0
            clearVisualAnnotationNarrationState()
        }
        state = state.removingOverlayReason(.activeAgentAnnotations)
        endAnnotationPointerTurn(discardingPendingTargets: true)
    }

    mutating func clearVisualAnnotationNarrationState() {
        let annotationSegmentIDs = Set(state.visualNarrationSegments.compactMap { id, segment in
            if case .annotations = segment.visual { return id }
            return nil
        })
        guard !annotationSegmentIDs.isEmpty else { return }
        for id in annotationSegmentIDs { state.visualNarrationSegments[id] = nil }
        state.visualNarrationOrder.removeAll { annotationSegmentIDs.contains($0) }
        state.visualNarrationSpeechMarkers = state.visualNarrationSpeechMarkers.filter {
            !annotationSegmentIDs.contains($0.value.identity.segmentId)
        }
        state.pendingVisualOnlyNarrationIdentities.removeAll {
            annotationSegmentIDs.contains($0.segmentId)
        }
        if let activeID = state.activeVisualNarrationIdentity?.segmentId,
           annotationSegmentIDs.contains(activeID) {
            state.activeVisualNarrationIdentity = nil
            state.activeVisualNarrationSentenceCount = 0
        }
    }

    mutating func clearProgressiveNarrationState() {
        invalidateActiveVisualNarrationTurn()
        state.streamedResponseContextID = nil
        state.streamedResponseText = nil
        state.finalNarrationSpeechContextIDs = []
        state.visualNarrationSegments = [:]
        state.visualNarrationOrder = []
        state.activeVisualNarrationIdentity = nil
        state.activeVisualNarrationSentenceCount = 0
        state.visualNarrationSpeechMarkers = [:]
        state.visualNarrationClearSpeechIDs = []
        state.pendingVisualOnlyNarrationIdentities = []
        state.streamedNarrationContextIDs = []
    }

    mutating func cancelAnnotationPointerForSceneSuspension() {
        state.pendingAnnotationPointerTargets = []
        state.annotationPointerTurnActive = false
        state.annotationPointerIsParked = false
        state.activeAnnotationPointerParksAtTarget = false
        state.activeAnnotationPointerReturnsToCursor = true
        guard let activeID = state.activeAnnotationPointerID else { return }
        effects.append(.cancelPointerAnimation(pointerID: activeID))
        state.activeAnnotationPointerID = nil
        state.pointer = .idle
        state = state.removingOverlayReason(.activePointerAnimation)
    }

    mutating func enqueueAnnotationPointerTargets(_ annotations: [PickyAgentAnnotation]) {
        let targets = annotations.compactMap(PickyAnnotationPointerTarget.make)
        guard !targets.isEmpty else { return }
        state.annotationPointerTurnActive = true
        state.pendingAnnotationPointerTargets.append(contentsOf: targets)
        if let activeID = state.activeAnnotationPointerID {
            // A final target may still be approaching or hovering when another DSL tag
            // arrives. Convert it into a direct hop instead of allowing a fly-back.
            state.activeAnnotationPointerParksAtTarget = false
            effects.append(.setPointerParksAtTarget(pointerID: activeID, parksAtTarget: false))
            if state.activeAnnotationPointerReturnsToCursor {
                state.activeAnnotationPointerReturnsToCursor = false
                effects.append(.setPointerReturnsToCursor(pointerID: activeID, returnsToCursor: false))
            }
            if state.annotationPointerIsParked {
                state.annotationPointerIsParked = false
                effects.append(.advancePointerAnimation(pointerID: activeID))
            }
        }
        startNextAnnotationPointerIfPossible()
    }

    mutating func startNextAnnotationPointerIfPossible() {
        guard case .idle = state.pointer,
              !state.pendingAnnotationPointerTargets.isEmpty else { return }
        var target = state.pendingAnnotationPointerTargets.removeFirst()
        let isFinalTarget = state.pendingAnnotationPointerTargets.isEmpty
        let parksAtTarget = state.annotationPointerTurnActive && isFinalTarget
        target = PickyAnnotationPointerTarget.settingHoldBehavior(
            target,
            returnsToCursor: !state.annotationPointerTurnActive && isFinalTarget,
            parksAtTarget: parksAtTarget
        )
        state.pointer = .requested(target)
        state.activeAnnotationPointerID = target.id
        state.activeAnnotationPointerReturnsToCursor = target.returnsToCursor
        state.activeAnnotationPointerParksAtTarget = target.parksAtTarget
        state.annotationPointerIsParked = false
        state = state.addingOverlayReason(.activePointerAnimation)
        effects.append(.startPointerAnimation(target: target))
    }

    /// Ends the current annotation stream without interrupting the buddy's current flight.
    /// Normal turn endings finish queued shapes before returning; user input/clear drops
    /// not-yet-visited anchors but still lets the active target spring back naturally.
    mutating func endAnnotationPointerTurn(discardingPendingTargets: Bool = false) {
        guard state.annotationPointerTurnActive || state.activeAnnotationPointerID != nil else { return }
        state.annotationPointerTurnActive = false
        if discardingPendingTargets {
            state.pendingAnnotationPointerTargets = []
        }
        guard let activeID = state.activeAnnotationPointerID else {
            state.annotationPointerIsParked = false
            state.activeAnnotationPointerParksAtTarget = false
            return
        }

        let shouldReturnAfterCurrentTarget = state.pendingAnnotationPointerTargets.isEmpty
        state.annotationPointerIsParked = false
        state.activeAnnotationPointerParksAtTarget = false
        state.activeAnnotationPointerReturnsToCursor = shouldReturnAfterCurrentTarget
        effects.append(.setPointerParksAtTarget(pointerID: activeID, parksAtTarget: false))
        effects.append(.setPointerReturnsToCursor(pointerID: activeID, returnsToCursor: shouldReturnAfterCurrentTarget))
    }

}

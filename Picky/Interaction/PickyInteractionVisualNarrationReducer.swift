//
//  PickyInteractionVisualNarrationReducer.swift
//  Picky
//
//  Pure visual narration transitions: segment preparation, sentences,
//  commit, activation, and turn invalidation.
//

import Foundation

extension PickyInteractionReducing {
    // MARK: - Visual narration

    mutating func applyVisualNarrationSegmentPrepared(
        identity: PickyVisualNarrationSegmentIdentity,
        visual: PickyResolvedVisualNarrationVisual
    ) {
        guard acceptVisualNarrationTurn(identity) else { return }
        if let existing = state.visualNarrationSegments[identity.segmentId], existing.identity != identity {
            record(.staleEvent, "Ignored mismatched visual narration prepare")
            return
        }
        var segment = state.visualNarrationSegments[identity.segmentId] ?? PickyVisualNarrationSegmentState(
            identity: identity,
            visual: nil,
            sentences: [],
            committedText: nil,
            expectedSentenceCount: nil
        )
        segment.visual = visual
        state.visualNarrationSegments[identity.segmentId] = segment
        if !state.visualNarrationOrder.contains(identity.segmentId) {
            state.visualNarrationOrder.append(identity.segmentId)
            state.visualNarrationOrder.sort {
                (state.visualNarrationSegments[$0]?.identity.ordinal ?? .max)
                    < (state.visualNarrationSegments[$1]?.identity.ordinal ?? .max)
            }
        }
        trimVisualNarrationSegmentsIfNeeded()
        if segment.expectedSentenceCount == 0 {
            queueOrActivateVisualOnlyNarration(identity)
        } else if let playbackMode = segment.sentences.first?.playbackMode,
                  playbackMode != .incremental {
            activateVisualNarration(identity: identity, sentenceCount: contiguousSentenceCount(in: segment))
        } else if let startedSentenceIndex = state.visualNarrationSpeechMarkers.values
            .filter({ $0.identity == identity })
            .map(\.sentenceIndex).max() {
            // Incremental race: a sentence began speaking before its geometry
            // arrived, so its speechStarted activation no-op'd. Now that the
            // visual exists, activate up to the highest already-started sentence.
            activateVisualNarration(identity: identity, sentenceCount: startedSentenceIndex + 1)
        }
        record(.accepted, "Visual narration segment prepared")
    }

    mutating func applyVisualNarrationSegmentSentence(
        identity: PickyVisualNarrationSegmentIdentity,
        index: Int,
        text: String,
        originSource: PickyQuickReplyOriginSource?,
        replyKind: PickyQuickReplyKind?,
        sessionID: String?,
        playbackMode: PickyVisualNarrationPlaybackMode
    ) {
        guard acceptVisualNarrationTurn(identity) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard index >= 0, !trimmed.isEmpty else {
            record(.staleEvent, "Ignored invalid visual narration sentence")
            return
        }
        let owner = state.contextOwnership[identity.contextId] ?? ownerFromMetadata(originSource)
        let resolvedReplyKind = replyKind ?? .main
        guard !state.hasActiveVoiceInput,
              presentsReplyAtCursor(owner: owner, replyKind: resolvedReplyKind) else {
            record(.accepted, "Visual narration sentence did not require presentation")
            return
        }
        if let existing = state.visualNarrationSegments[identity.segmentId], existing.identity != identity {
            record(.staleEvent, "Ignored mismatched visual narration sentence")
            return
        }
        var segment = state.visualNarrationSegments[identity.segmentId] ?? PickyVisualNarrationSegmentState(
            identity: identity,
            visual: nil,
            sentences: [],
            committedText: nil,
            expectedSentenceCount: nil
        )
        guard !segment.sentences.contains(where: { $0.index == index }) else {
            record(.staleEvent, "Ignored duplicate visual narration sentence")
            return
        }
        let sentence = PickyVisualNarrationSentenceState(
            index: index,
            text: trimmed,
            precedingNarrationWeight: state.annotationNarrationWeight,
            playbackMode: playbackMode,
            originSource: originSource,
            replyKind: resolvedReplyKind,
            sessionID: sessionID
        )
        segment.sentences.append(sentence)
        segment.sentences.sort { $0.index < $1.index }
        state.visualNarrationSegments[identity.segmentId] = segment
        if !state.visualNarrationOrder.contains(identity.segmentId) {
            state.visualNarrationOrder.append(identity.segmentId)
        }
        state.annotationNarrationWeight += PickyNarrationPaceModel.weightedUnits(forNarration: trimmed)
        if let sessionID { state.pendingAgentRequestsBySession[sessionID] = nil }

        switch playbackMode {
        case .incremental:
            let marker = PickyVisualNarrationSpeechMarker(identity: identity, sentenceIndex: index)
            enqueueOrSpeakQuickReply(
                contextID: identity.contextId,
                text: trimmed,
                replyKind: resolvedReplyKind,
                owner: owner,
                timerID: envelope.id,
                inputID: nil,
                visualNarrationMarker: marker
            )
            state.streamedNarrationContextIDs.insert(identity.contextId)
        case .finalReply:
            state.finalNarrationSpeechContextIDs.insert(identity.contextId)
            activateVisualNarration(identity: identity, sentenceCount: contiguousSentenceCount(in: segment))
        case .silent:
            activateVisualNarration(identity: identity, sentenceCount: contiguousSentenceCount(in: segment))
        }
        record(.accepted, "Visual narration sentence received")
    }

    mutating func applyVisualNarrationSegmentCommitted(
        identity: PickyVisualNarrationSegmentIdentity,
        text: String?,
        sentenceCount: Int
    ) {
        guard acceptVisualNarrationTurn(identity) else { return }
        guard sentenceCount >= 0 else {
            record(.staleEvent, "Ignored invalid visual narration commit")
            return
        }
        if let existing = state.visualNarrationSegments[identity.segmentId], existing.identity != identity {
            record(.staleEvent, "Ignored mismatched visual narration commit")
            return
        }
        var segment = state.visualNarrationSegments[identity.segmentId] ?? PickyVisualNarrationSegmentState(
            identity: identity,
            visual: nil,
            sentences: [],
            committedText: nil,
            expectedSentenceCount: nil
        )
        segment.committedText = text
        segment.expectedSentenceCount = sentenceCount
        state.visualNarrationSegments[identity.segmentId] = segment
        if !state.visualNarrationOrder.contains(identity.segmentId) {
            state.visualNarrationOrder.append(identity.segmentId)
        }
        trimVisualNarrationSegmentsIfNeeded()
        if sentenceCount == 0 {
            queueOrActivateVisualOnlyNarration(identity)
        }
        record(.accepted, "Visual narration segment committed")
    }

    mutating func applyVisualNarrationBarrierSpeechStarted(speechID: UUID) {
        guard state.visualNarrationClearSpeechIDs.remove(speechID) != nil else { return }
        clearActiveVisualNarration()
    }

    mutating func applyVisualNarrationSpeechStarted(speechID: UUID) {
        guard let marker = state.visualNarrationSpeechMarkers[speechID],
              let segment = state.visualNarrationSegments[marker.identity.segmentId],
              segment.identity == marker.identity else { return }
        let contiguous = contiguousSentenceCount(in: segment)
        guard marker.sentenceIndex < contiguous else { return }
        activateVisualNarration(identity: marker.identity, sentenceCount: marker.sentenceIndex + 1)
    }

    mutating func activateVisualNarration(
        identity: PickyVisualNarrationSegmentIdentity,
        sentenceCount: Int
    ) {
        guard sentenceCount >= 0,
              let segment = state.visualNarrationSegments[identity.segmentId],
              segment.identity == identity,
              let visual = segment.visual,
              sentenceCount > 0 || segment.expectedSentenceCount == 0 else { return }
        if state.activeVisualNarrationIdentity != identity {
            state.activeVisualNarrationIdentity = identity
            state.activeVisualNarrationSentenceCount = 0
            switch visual {
            case .point(let target):
                applyPointerRequested(target: target)
            case .annotations(let annotations):
                if let pointerID = state.pointer.target?.id,
                   state.activeAnnotationPointerID == nil {
                    effects.append(.cancelPointerAnimation(pointerID: pointerID))
                    state.pointer = .idle
                    state = state.removingOverlayReason(.activePointerAnimation)
                }
                for annotation in annotations { revealAnnotation(annotation) }
            }
        }
        state.activeVisualNarrationSentenceCount = max(
            state.activeVisualNarrationSentenceCount,
            min(sentenceCount, contiguousSentenceCount(in: segment))
        )
    }

    mutating func clearActiveVisualNarration() {
        state.activeVisualNarrationIdentity = nil
        state.activeVisualNarrationSentenceCount = 0
    }

    mutating func queueOrActivateVisualOnlyNarration(_ identity: PickyVisualNarrationSegmentIdentity) {
        guard let segment = state.visualNarrationSegments[identity.segmentId],
              segment.identity == identity,
              segment.expectedSentenceCount == 0,
              segment.visual != nil else { return }
        if annotationSpeechActive {
            if !state.pendingVisualOnlyNarrationIdentities.contains(identity) {
                state.pendingVisualOnlyNarrationIdentities.append(identity)
            }
        } else {
            activateVisualNarration(identity: identity, sentenceCount: 0)
        }
    }

    func contiguousSentenceCount(in segment: PickyVisualNarrationSegmentState) -> Int {
        var expected = 0
        for sentence in segment.sentences {
            guard sentence.index == expected else { break }
            expected += 1
        }
        return expected
    }

    mutating func trimVisualNarrationSegmentsIfNeeded() {
        while state.visualNarrationOrder.count > PickyInteractionReducer.maximumAgentAnnotationCount {
            let removedID = state.visualNarrationOrder.removeFirst()
            if state.activeVisualNarrationIdentity?.segmentId == removedID { continue }
            state.visualNarrationSegments[removedID] = nil
        }
    }

    mutating func acceptVisualNarrationTurn(_ identity: PickyVisualNarrationSegmentIdentity) -> Bool {
        let turnIdentity = PickyVisualNarrationTurnIdentity(segmentIdentity: identity)
        guard !state.invalidatedVisualNarrationTurnIdentities.contains(turnIdentity) else {
            record(.staleEvent, "Ignored visual narration event from invalidated turn")
            return false
        }
        if let activeTurn = state.activeVisualNarrationTurnIdentity,
           activeTurn != turnIdentity {
            record(.staleEvent, "Ignored visual narration event from non-active turn")
            return false
        }
        state.activeVisualNarrationTurnIdentity = turnIdentity
        return true
    }

    mutating func invalidateActiveVisualNarrationTurn(contextID: String? = nil) {
        guard let activeTurn = state.activeVisualNarrationTurnIdentity,
              contextID == nil || activeTurn.contextId == contextID else { return }
        if !state.invalidatedVisualNarrationTurnIdentities.contains(activeTurn) {
            state.invalidatedVisualNarrationTurnIdentities.append(activeTurn)
            let overflow = max(
                0,
                state.invalidatedVisualNarrationTurnIdentities.count
                    - PickyInteractionReducer.maximumInvalidatedVisualNarrationTurnCount
            )
            if overflow > 0 {
                state.invalidatedVisualNarrationTurnIdentities.removeFirst(overflow)
            }
        }
        state.activeVisualNarrationTurnIdentity = nil
    }
}

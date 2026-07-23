//
//  CompanionManager+MainTurnLifecycle.swift
//  Picky
//
//  Main-turn settlement, cancellation, and voice-response lifecycle.
//  CompanionManager remains the sole mutable owner of all referenced state.
//

import Foundation

@MainActor
extension CompanionManager {
    /// If the cursor is in transient mode (user toggled "Show Picky" off),
    /// waits for any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isCursorPreferenceEnabled && isOverlayVisible else { return }
        guard !hasActiveTransientOverlayBlocker else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil || hasActiveTransientOverlayBlocker {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !hasActiveTransientOverlayBlocker else { return }
            localOverlayVisibilityReasons.removeAll()
            interactionOverlayVisibilityReasons.removeAll()
            syncOverlayVisibility(animatedHide: true)
        }
    }

    // Shared with CompanionManager+SpeechLifecycle.swift; state remains owned by CompanionManager.
    var shouldSuppressSpokenAudioForVoiceInput: Bool {
        isPushToTalkShortcutHeld || isVoiceInputAudioSuppressionActive || buddyDictationManager.isDictationInProgress
    }

    func updateVoiceInputAudioSuppression(isVoiceInputActive: Bool) {
        guard isVoiceInputActive else {
            isVoiceInputAudioSuppressionActive = false
            return
        }

        isVoiceInputAudioSuppressionActive = true
        stopCurrentSpeech()
        // Voice input (PTT) means the user is taking over: drop any active
        // agent state so the UI flips off the yellow loading / blue speaking
        // indicator immediately and the STT subsystem can promote to
        // `.listening` on its own.
        if voiceState == .responding || voiceState == .processing {
            voiceState = .idle
        }
    }

    func interruptSpokenResponseForVoiceInput() {
        // Capture before this PTT press can begin a new turn. The abort command
        // must still precede that submission, but its eventual success must not
        // settle the new turn that follows this key press.
        let cancellation = makeMainTurnCancellation()
        stopCurrentSpeech()
        Task { [weak self] in
            _ = await self?.cancelMainTurn(cancellation, stopsLocalSpeech: false)
        }
        updateVoiceInputAudioSuppression(isVoiceInputActive: true)
        reduceVoiceInteraction(.abort)
    }

    /// Stops the current main turn regardless of whether it originated from
    /// voice or typed Quick Input. A Pickle follow-up needs its own session
    /// abort in addition to the main-agent abort.
    @discardableResult
    func cancelMainTurn() async -> Bool {
        await cancelMainTurn(makeMainTurnCancellation(), stopsLocalSpeech: true)
    }

    private func makeMainTurnCancellation() -> MainTurnCancellation {
        let hasPendingAgentResponse = pendingAgentResponseStartedAt != nil
        let shouldSettleLocalState = PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: hasPendingAgentResponse,
            voiceState: voiceState,
            isWaitingForCursorResponse: isWaitingForCursorResponse,
            hasLiveActivities: !mainLiveActivities.isEmpty,
            hasActiveFollowUpTurn: activeMainTurnFollowUpSessionID != nil
        )
        let shouldAbortFollowUpPickle = PickyMainCancelPillPolicy.shouldAbortFollowUpPickle(
            hasPendingAgentResponse: hasPendingAgentResponse,
            voiceState: voiceState
        )
        return MainTurnCancellation(
            shouldSettleLocalState: shouldSettleLocalState,
            followUpSessionID: PickyMainCancelPillPolicy.followUpAbortTarget(
                activeMainTurnFollowUpSessionID: activeMainTurnFollowUpSessionID,
                voiceFollowUpSessionID: voiceFollowUpSessionIDForCurrentUtterance,
                shouldAbortVoiceFollowUpPickle: shouldAbortFollowUpPickle
            ),
            generation: mainTurnGeneration,
            armedPickleDispatchToken: activeArmedPickleDispatch?.token
        )
    }

    private func cancelMainTurn(
        _ cancellation: MainTurnCancellation,
        stopsLocalSpeech: Bool
    ) async -> Bool {
        // Stop local narration immediately, but keep the in-flight projection
        // intact until agentd accepted the main abort. That lets the pill remain
        // usable when transport or command delivery fails.
        if stopsLocalSpeech {
            stopCurrentSpeech()
        }
        let mainAbortCommand = PickyCommandEnvelope(type: .abortMainAgent)
        let followUpAbortCommand = cancellation.followUpSessionID.map {
            PickyCommandEnvelope(type: .abort, sessionId: $0)
        }
        let cancellationCommandIDs = [mainAbortCommand.id, followUpAbortCommand?.id].compactMap { $0 }
        pendingMainTurnCancellationCommandIDs.formUnion(cancellationCommandIDs)
        defer {
            pendingMainTurnCancellationCommandIDs.subtract(cancellationCommandIDs)
            completedMainTurnCancellationCommandIDs.formUnion(cancellationCommandIDs)
            updateMainCancelPillPresentation()
        }

        do {
            async let mainAbortRejection = agentClient.sendAwaitingError(mainAbortCommand, timeout: 1.0)
            async let followUpAbortRejection: PickyErrorEvent? = {
                guard let followUpAbortCommand else { return nil }
                return try await agentClient.sendAwaitingError(followUpAbortCommand, timeout: 1.0)
            }()
            let (mainRejection, followUpRejection) = try await (mainAbortRejection, followUpAbortRejection)
            if let mainRejection {
                print("⚠️ Failed to abort Picky main turn: \(mainRejection.message)")
                return false
            }
            if let followUpRejection {
                print("⚠️ Failed to abort Pickle session: \(followUpRejection.message)")
                return false
            }
        } catch {
            print("⚠️ Failed to abort Picky main turn: \(error)")
            return false
        }

        // A PTT or typed submission may have started another turn while the
        // daemon was processing this cancellation. Never settle or confirm a
        // cancellation result against that newer turn.
        guard mainTurnGeneration == cancellation.generation else { return false }
        if let armedPickleDispatchToken = cancellation.armedPickleDispatchToken,
           activeArmedPickleDispatch?.token == armedPickleDispatchToken {
            activeArmedPickleDispatch = nil
        }
        if cancellation.shouldSettleLocalState {
            settleMainTurnAfterCancellation()
        }
        return true
    }

    private func settleMainTurnAfterCancellation() {
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        pendingAgentResponseStartedAt = nil
        // User-initiated cancellation: drop the chips immediately (and any
        // pending linger) — there is no settled response to linger beside.
        clearMainActivitiesImmediately()
        activeMainTurnFollowUpSessionID = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        // This is the same abort reduction used by the voice interruption path.
        // It clears the voice projection even though agentd's abort command has
        // no matching mainTurnSettled event.
        reduceVoiceInteraction(.abort)
        // Typed Quick Input uses the interaction coordinator rather than the
        // voice machine. Reset its waiting output as well so the cursor cannot
        // remain in the processing projection after a successful abort.
        interactionCoordinator.accept(
            .mainAgentSessionReset,
            correlation: PickyInteractionCorrelation(source: .system)
        )
    }

    func beginAwaitingAgentResponse(recognizedTranscript: String? = nil) {
        beginMainTurnGeneration()
        activeMainTurnFollowUpSessionID = voiceFollowUpSessionIDForCurrentUtterance
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        if !buddyDictationManager.isDictationInProgress {
            updateVoiceInputAudioSuppression(isVoiceInputActive: false)
        }
        stopCurrentSpeech()
        let trimmedTranscript = recognizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentVoicePromptPreview = trimmedTranscript.isEmpty ? nil : trimmedTranscript
        let startedAt = Date()
        pendingAgentResponseStartedAt = startedAt
        latestAgentSessionSummary = L10n.t("agent.summary.preparingResponse")
        reduceVoiceInteraction(.loadingStarted(
            inputID: interactionVoiceInputID,
            transcript: trimmedTranscript,
            targetSessionID: voiceFollowUpSessionIDForCurrentUtterance,
            now: startedAt,
            promptBubbleVisibility: .visible
        ))
        scheduleRecognizedTranscriptAutoHide(trimmedTranscript: trimmedTranscript)
    }

    private func scheduleRecognizedTranscriptAutoHide(trimmedTranscript: String) {
        voicePromptBubbleAutoHideTask?.cancel()
        voicePromptBubbleAutoHideTask = nil
        guard !trimmedTranscript.isEmpty else { return }

        let visibleDuration = Self.recognizedTranscriptVisibleDuration
        voicePromptBubbleAutoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only retract the bubble if it's still showing the same
                // recognized transcript. If the agent already responded, or a
                // new utterance replaced it, the didSet on voicePromptBubbleState
                // already cancelled this task — but guard defensively anyway.
                guard case .recognized = self.voicePromptBubbleState else { return }
                self.reduceVoiceInteraction(.promptBubbleAutoHide)
                self.currentVoicePromptPreview = nil
            }
        }
    }

    /// Releases cursor state tied to a session that just transitioned to a terminal
    /// status. The normal completion path runs through `quickReply` -> `finishAwaitingAgentResponse`,
    /// but HUD aborts (and runtime cancel/fail) reach the client only as a `sessionUpdated`
    /// with `.cancelled` / `.failed` — no `quickReply` ever lands. Without this hook the
    /// cursor stays at `.processing` (yellow) forever because both channels that drive it
    /// (`pendingAgentResponseStartedAt` + interaction state `.waitingForAgent`) never clear.
    ///
    /// Idempotent and side-effect-light when nothing matches:
    ///   - only the *transition* into a terminal status triggers cleanup (duplicate
    ///     `sessionUpdated` snapshots for the same terminal status are no-ops);
    ///   - voice-follow-up tracking is only released when the terminated session is the
    ///     one the cursor is actively waiting on;
    ///   - the interaction-coordinator dispatch is harmless when the reducer never
    ///     observed an `agentSubmissionAccepted` for this sessionID.
    func handleSessionStatusTransition(session: PickyAgentSession) {
        let previous = lastObservedSessionStatuses[session.id]
        lastObservedSessionStatuses[session.id] = session.status
        guard session.status.isTerminal else { return }
        if let previous, previous.isTerminal { return }
        releaseCursorForTerminatedSession(sessionID: session.id, status: session.status)
    }

    private func releaseCursorForTerminatedSession(sessionID: String, status: PickySessionStatus) {
        if activeMainTurnFollowUpSessionID == sessionID {
            activeMainTurnFollowUpSessionID = nil
        }
        releaseDeferredAcceptedReceiptIfNeeded(sessionID: sessionID)
        // Only release the voice-input "awaiting agent" timing when the cursor is
        // actually waiting on THIS session. Otherwise we'd race-clear a fresh voice
        // turn that started against a different (still-running) Pickle, or an in-flight
        // spoken reply for an unrelated completed session.
        if voiceFollowUpSessionIDForCurrentUtterance == sessionID {
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask = nil
            deferredFinishAwaitingAgentResponseSessionID = nil
            responseStateTask?.cancel()
            responseStateTask = nil
            pendingAgentResponseStartedAt = nil
            currentVoicePromptPreview = nil
            voicePromptBubbleState = .hidden
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "session-terminated-\(status.rawValue)")
            // Re-run the voice presentation pipeline. With pendingAgentResponseStartedAt
            // cleared and no dictation in progress, this falls through to the
            // `reduceVoiceInteraction(.reset)` branch which moves voiceState out of
            // `.processing` (the yellow cursor) back to `.idle`. Without this nudge the
            // PickyVoiceInteractionMachine stays parked in `.loading` and voiceState
            // never updates because nothing else drives a projection refresh.
            updateVoicePresentation()
        }
        // Dispatch the synthetic terminal event into the interaction reducer so any
        // `.waitingForAgent` output that the reducer recorded against this session
        // (CLI / quickInput / voice with cursor presentation) flips back to `.idle`.
        // The reducer is idempotent: unknown sessionIDs become `.staleEvent` records.
        interactionCoordinator.accept(
            .sessionTerminated(sessionID: sessionID),
            correlation: PickyInteractionCorrelation(sessionID: sessionID, source: .agent)
        )
    }

    private func releaseDeferredAcceptedReceiptIfNeeded(sessionID: String) {
        guard deferredFinishAwaitingAgentResponseSessionID == sessionID else { return }
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        pendingAgentResponseStartedAt = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        if voiceState == .processing {
            reduceVoiceInteraction(.reset)
        } else {
            updateVoicePresentation()
        }
    }

    func finishAwaitingAgentResponse(
        visibleText: String,
        spokenText: String?,
        enforceMinimumProcessingDuration: Bool = false,
        deferredSessionID: String? = nil
    ) {
        if enforceMinimumProcessingDuration,
           let pendingAgentResponseStartedAt,
           Date().timeIntervalSince(pendingAgentResponseStartedAt) < Self.minimumVoiceProcessingDisplayDuration {
            let remainingDelay = Self.minimumVoiceProcessingDisplayDuration - Date().timeIntervalSince(pendingAgentResponseStartedAt)
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseSessionID = deferredSessionID
            deferredFinishAwaitingAgentResponseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(remainingDelay, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.finishAwaitingAgentResponse(visibleText: visibleText, spokenText: spokenText)
                }
            }
            return
        }

        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        pendingAgentResponseStartedAt = nil
        activeMainTurnFollowUpSessionID = nil
        latestAgentSessionSummary = visibleText
        currentVoicePromptPreview = nil
        let textToSpeak = spokenText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let textToSpeak, !textToSpeak.isEmpty else {
            reduceVoiceInteraction(.textReply(text: visibleText))
            if !shouldSuppressSpokenAudioForVoiceInput {
                scheduleTransientHideIfNeeded()
            }
            return
        }
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            stopCurrentSpeech()
            reduceVoiceInteraction(.textReply(text: visibleText))
            return
        }
        speakSystemMessage(textToSpeak)
    }

}

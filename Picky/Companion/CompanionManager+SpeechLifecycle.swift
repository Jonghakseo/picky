//
//  CompanionManager+SpeechLifecycle.swift
//  Picky
//
//  Local speech playback lifecycle. CompanionManager remains the sole mutable
//  owner of speech state; this extension only groups that responsibility.
//

import Foundation

@MainActor
extension CompanionManager {
    /// Retry cadence and ceiling for speech deferred while voice input holds the mic.
    static let deferredSpeechRetryInterval: TimeInterval = 0.05
    static let deferredSpeechMaximumWait: TimeInterval = 2.0

    /// Speaks a short local status message through macOS system speech.
    func speakSystemMessage(_ utterance: String) {
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            stopCurrentSpeech()
            return
        }
        stopCurrentSpeech()

        let speechID = UUID()
        activeSpeechID = speechID
        reduceVoiceInteraction(.agentReply(text: utterance, shouldSpeak: true, speechID: speechID, timerID: speechID, inputID: interactionVoiceInputID, now: Date()))

        logSpeech("system start speechID=\(speechID) provider=\(speechPlaybackProvider.displayName) chars=\(utterance.count)")
        guard speechPlaybackProvider.speak(utterance, onFinish: { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.logSpeech("system provider callback speechID=\(speechID) didFinish=\(didFinish)")
                self?.handleSpeechFinished(speechID: speechID, didFinish: didFinish)
            }
        }) else {
            logSpeech("system provider refused start speechID=\(speechID)")
            handleSpeechFinished(speechID: speechID, didFinish: false)
            return
        }

        let startedAt = Date()
        let watchdogDeadline = Date().addingTimeInterval(speechWatchdogTimeout(for: utterance))
        responseStateTask = Task { [weak self] in
            var lastLoggedSecond = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let pollResult = await MainActor.run { [weak self] in
                    guard let self,
                          self.activeSpeechID == speechID else {
                        return PickySpeechPollResult.inactive
                    }
                    let isSpeaking = self.speechPlaybackProvider.isSpeaking
                    let elapsedSecond = Int(Date().timeIntervalSince(startedAt))
                    if elapsedSecond != lastLoggedSecond {
                        lastLoggedSecond = elapsedSecond
                        self.logSpeech("system poll speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) providerSpeaking=\(isSpeaking) voiceState=\(self.voiceState)")
                    }
                    if !isSpeaking { return .finished }
                    if Date() >= watchdogDeadline { return .timedOut }
                    return .speaking
                }
                switch pollResult {
                case .speaking:
                    continue
                case .inactive:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("system poll inactive speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                    }
                    return
                case .finished:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("system poll detected provider finished speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self?.handleSpeechFinished(speechID: speechID, didFinish: true)
                    }
                    return
                case .timedOut:
                    await MainActor.run { [weak self] in
                        guard let self, self.activeSpeechID == speechID else { return }
                        self.logSpeech("system poll timed out speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self.speechPlaybackProvider.stopSpeaking()
                        self.handleSpeechFinished(speechID: speechID, didFinish: false)
                    }
                    return
                }
            }
        }
    }

    /// Stops audio output only. Ending playback is an *effect*, not an
    /// interaction transition: the voice machine merely gets a guarded
    /// `.speechInterrupted` for the stopped utterance, so a stale or
    /// concurrent stop (coordinator preemption, audio suppression) can never
    /// reset an active PTT input or a loading turn to idle.
    func stopCurrentSpeech() {
        logSpeech("stop current speech active=\(activeSpeechID?.uuidString ?? "none") interaction=\(interactionSpeechID?.uuidString ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        let interruptedSpeechID = activeSpeechID
        activeSpeechID = nil
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechPlaybackProvider.stopSpeaking()
        reduceVoiceInteraction(.speechInterrupted(speechID: interruptedSpeechID))
    }

    func stopCurrentInteractionSpeech(speechID requestedSpeechID: UUID?) {
        // Prefer the speechID the reducer explicitly preempted. Falling back
        // to interactionSpeechID/activeSpeechID covers legacy call sites that
        // didn't know which utterance was active (e.g., voicePressed when no
        // interaction speech was running, just a system status message).
        let speechID = requestedSpeechID ?? interactionSpeechID ?? activeSpeechID
        logSpeech("stop current interaction speech requested=\(requestedSpeechID?.uuidString ?? "none") resolved=\(speechID?.uuidString ?? "none")")
        stopCurrentSpeech()
        guard let speechID else { return }
        interactionCoordinator.effectCompleted(
            .speechFailed(speechID: speechID),
            correlation: PickyInteractionCorrelation(speechID: speechID, source: .system)
        )
    }

    func handleSpeechFinished(speechID: UUID, didFinish: Bool) {
        guard activeSpeechID == speechID else {
            logSpeech("system finish ignored stale speechID=\(speechID) active=\(activeSpeechID?.uuidString ?? "none") didFinish=\(didFinish) providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
            return
        }
        logSpeech("system finish accepted speechID=\(speechID) didFinish=\(didFinish) providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        let machineCompletionTime = Date().addingTimeInterval(PickyVoiceInteractionMachine.minimumDisplayDuration + 0.01)
        reduceVoiceInteraction(didFinish ? .speechFinished(speechID: speechID, now: machineCompletionTime) : .speechFailed(speechID: speechID, now: machineCompletionTime))
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        scheduleTransientHideIfNeeded()
    }

    func runSpeakEffect(speechID: UUID, text: String, contextID: String?) {
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        // Convert Markdown to visible prose and strip speech-hostile supplementary
        // detail immediately before synthesis. The queued reply keeps the original
        // text so cursor and conversation UI still render full Markdown.
        let spoken = sanitizedTextForSpeech(text)
        guard !spoken.isEmpty else {
            logSpeech("interaction skipped empty sanitized speechID=\(speechID) context=\(contextID ?? "none")")
            interactionCoordinator.effectCompleted(
                .speechFinished(speechID: speechID),
                correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
            )
            return
        }
        startOrDeferInteractionSpeech(speechID: speechID, text: spoken, contextID: contextID, requestedAt: Date())
    }

    func runPrefetchSpeechEffect(text: String) {
        // Apply the same speech transform runSpeakEffect uses so the warmed
        // audio is keyed by the exact string the provider will later synthesize.
        let spoken = sanitizedTextForSpeech(text)
        guard !spoken.isEmpty else { return }
        speechPlaybackProvider.prefetch(spoken)
    }

    func startOrDeferInteractionSpeech(speechID: UUID, text: String, contextID: String?, requestedAt: Date) {
        guard isCurrentInteractionSpeechOutput(speechID) else {
            logSpeech("interaction start skipped stale projection speechID=\(speechID) context=\(contextID ?? "none")")
            return
        }
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            let elapsed = Date().timeIntervalSince(requestedAt)
            guard elapsed < Self.deferredSpeechMaximumWait else {
                logSpeech("interaction start failed deferred audio suppression timeout speechID=\(speechID) elapsedMs=\(Int(elapsed * 1000)) context=\(contextID ?? "none")")
                interactionCoordinator.effectCompleted(
                    .speechFailed(speechID: speechID),
                    correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
                )
                return
            }

            logSpeech("interaction start deferred by active voice input speechID=\(speechID) elapsedMs=\(Int(elapsed * 1000)) context=\(contextID ?? "none")")
            deferredInteractionSpeechTask?.cancel()
            deferredInteractionSpeechTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.deferredSpeechRetryInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.startOrDeferInteractionSpeech(speechID: speechID, text: text, contextID: contextID, requestedAt: requestedAt)
                }
            }
            return
        }

        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        // Queue transitions already completed the preceding utterance. Do not
        // call stopSpeaking here: Edge's explicit stop clears its warmed-audio
        // cache before speak() can reclaim the next sentence's prefetch.
        // Providers own replacement inside speak(), while reducer preemption
        // continues to use the explicit .stopSpeech effect.
        responseStateTask?.cancel()
        responseStateTask = nil
        activeSpeechID = speechID
        interactionSpeechID = speechID
        reduceVoiceInteraction(.agentReply(text: text, shouldSpeak: true, speechID: speechID, timerID: speechID, inputID: interactionVoiceInputID, now: Date()))

        logSpeech("interaction start speechID=\(speechID) provider=\(speechPlaybackProvider.displayName) chars=\(text.count) context=\(contextID ?? "none")")
        guard speechPlaybackProvider.speak(text, onFinish: { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.logSpeech("interaction provider callback speechID=\(speechID) didFinish=\(didFinish) context=\(contextID ?? "none")")
                self?.handleInteractionSpeechFinished(speechID: speechID, didFinish: didFinish, contextID: contextID)
            }
        }) else {
            logSpeech("interaction provider refused start speechID=\(speechID) context=\(contextID ?? "none")")
            handleInteractionSpeechFinished(speechID: speechID, didFinish: false, contextID: contextID)
            return
        }
        // `speak` has accepted the utterance and scheduled any provider preroll;
        // this is the earliest reliable app-side "about to speak" boundary.
        interactionCoordinator.effectCompleted(
            .speechStarted(text: text, speechID: speechID, sourceContextID: contextID),
            correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
        )

        let startedAt = Date()
        let watchdogDeadline = Date().addingTimeInterval(speechWatchdogTimeout(for: text))
        responseStateTask = Task { [weak self] in
            var lastLoggedSecond = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let pollResult = await MainActor.run { [weak self] in
                    guard let self, self.activeSpeechID == speechID else { return PickySpeechPollResult.inactive }
                    let isSpeaking = self.speechPlaybackProvider.isSpeaking
                    let elapsedSecond = Int(Date().timeIntervalSince(startedAt))
                    if elapsedSecond != lastLoggedSecond {
                        lastLoggedSecond = elapsedSecond
                        self.logSpeech("interaction poll speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) providerSpeaking=\(isSpeaking) voiceState=\(self.voiceState) context=\(contextID ?? "none")")
                    }
                    if !isSpeaking { return .finished }
                    if Date() >= watchdogDeadline { return .timedOut }
                    return .speaking
                }
                switch pollResult {
                case .speaking:
                    continue
                case .inactive:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("interaction poll inactive speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                    }
                    return
                case .finished:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("interaction poll detected provider finished speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self?.handleInteractionSpeechFinished(speechID: speechID, didFinish: true, contextID: contextID)
                    }
                    return
                case .timedOut:
                    await MainActor.run { [weak self] in
                        guard let self, self.activeSpeechID == speechID else { return }
                        self.logSpeech("interaction poll timed out speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self.speechPlaybackProvider.stopSpeaking()
                        self.handleInteractionSpeechFinished(speechID: speechID, didFinish: false, contextID: contextID)
                    }
                    return
                }
            }
        }
    }

    func isCurrentInteractionSpeechOutput(_ speechID: UUID) -> Bool {
        if case .speaking(_, let currentSpeechID, _, _, _, _) = interactionCoordinator.projection.state.output {
            return currentSpeechID == speechID
        }
        return false
    }

    func handleInteractionSpeechFinished(speechID: UUID, didFinish: Bool, contextID: String?) {
        guard activeSpeechID == speechID else {
            logSpeech("interaction finish ignored stale speechID=\(speechID) active=\(activeSpeechID?.uuidString ?? "none") didFinish=\(didFinish) context=\(contextID ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
            return
        }
        logSpeech("interaction finish accepted speechID=\(speechID) didFinish=\(didFinish) context=\(contextID ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        reduceVoiceInteraction(didFinish ? .speechFinished(speechID: speechID, now: Date()) : .speechFailed(speechID: speechID, now: Date()))
        activeSpeechID = nil
        if interactionSpeechID == speechID {
            interactionSpeechID = nil
        }
        responseStateTask?.cancel()
        responseStateTask = nil
        interactionCoordinator.effectCompleted(
            didFinish ? .speechFinished(speechID: speechID) : .speechFailed(speechID: speechID),
            correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
        )
    }
}

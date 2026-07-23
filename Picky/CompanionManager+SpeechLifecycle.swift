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

    func stopCurrentSpeech() {
        logSpeech("stop current speech active=\(activeSpeechID?.uuidString ?? "none") interaction=\(interactionSpeechID?.uuidString ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        reduceVoiceInteraction(.reset)
        activeSpeechID = nil
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechPlaybackProvider.stopSpeaking()
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

}

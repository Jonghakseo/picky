//
//  BuddyDictationManagerTests.swift
//  PickyTests
//

import Combine
import Foundation
import Testing
@testable import Picky

private actor FirstStartPreparationGate {
    private var invocationCount = 0
    private var firstEntered = false
    private var firstEnteredContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    func waitIfFirstInvocation() async {
        invocationCount += 1
        guard invocationCount == 1 else { return }
        firstEntered = true
        firstEnteredContinuation?.resume()
        firstEnteredContinuation = nil
        await withCheckedContinuation { firstReleaseContinuation = $0 }
    }

    func waitUntilFirstEntered() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { firstEnteredContinuation = $0 }
    }

    func releaseFirst() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }
}

private enum BuddyDictationTestError: Error {
    case unsupported
}

private struct BuddyDictationTestProvider: BuddyTranscriptionProvider {
    let displayName = "Test"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        throw BuddyDictationTestError.unsupported
    }
}

struct BuddyDictationManagerTests {
    @Test func recordingShorterThanMinimumDurationIsIgnored() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let stoppedAt = startedAt.addingTimeInterval(
            BuddyDictationManager.minimumSubmittedRecordingDurationSeconds - 0.01
        )

        #expect(BuddyDictationManager.shouldIgnoreRecording(startedAt: startedAt, stoppedAt: stoppedAt))
    }

    @Test func recordingAtMinimumDurationIsSubmitted() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let stoppedAt = startedAt.addingTimeInterval(
            BuddyDictationManager.minimumSubmittedRecordingDurationSeconds
        )

        #expect(!BuddyDictationManager.shouldIgnoreRecording(startedAt: startedAt, stoppedAt: stoppedAt))
    }

    @Test func recordingWithoutStartTimestampIsIgnored() {
        #expect(BuddyDictationManager.shouldIgnoreRecording(startedAt: nil, stoppedAt: Date()))
    }

    @MainActor
    @Test func staleCancelledStartupCannotResetNewerSession() async {
        let gate = FirstStartPreparationGate()
        let manager = BuddyDictationManager(
            transcriptionProvider: BuddyDictationTestProvider(),
            startPreparation: { await gate.waitIfFirstInvocation() }
        )
        let inputA = UUID()
        let inputB = UUID()
        var events: [BuddyDictationSessionEvent] = []
        let eventCancellable = manager.sessionEventPublisher.sink { events.append($0) }

        let startA = Task { @MainActor in
            await manager.startPushToTalkFromKeyboardShortcut(
                inputID: inputA,
                currentDraftText: "",
                updateDraftText: { _ in },
                submitDraftText: { _ in }
            )
        }
        await gate.waitUntilFirstEntered()
        manager.stopPushToTalkFromKeyboardShortcut()

        await manager.startPushToTalkFromKeyboardShortcut(
            inputID: inputB,
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { _ in }
        )
        #expect(manager.isRecordingFromKeyboardShortcut)

        await gate.releaseFirst()
        await startA.value

        #expect(manager.isRecordingFromKeyboardShortcut)
        #expect(events.contains(.discarded(inputID: inputA)))
        #expect(!events.contains(.discarded(inputID: inputB)))
        manager.cancelCurrentDictation(preserveDraftText: false)
        _ = eventCancellable
    }
}

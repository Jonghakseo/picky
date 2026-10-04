//
//  PickyComposerDictationControllerTests.swift
//  PickyTests
//
//  Composer mic contract: dictation fills the Pickle's own draft for review and
//  never sends; empty or failed results leave the draft untouched.
//

import Combine
import Foundation
import Testing
@testable import Picky

@MainActor
private final class FakeComposerDictationDriver: PickyComposerDictationDriving {
    var isDictationInProgress = false
    var hasDictationPermissionProblem = false
    let recordingStarted = CurrentValueSubject<Date?, Never>(nil)
    let events = PassthroughSubject<BuddyDictationSessionEvent, Never>()
    private(set) var startedInputIDs: [UUID] = []
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private var onTranscript: ((String) -> Void)?

    var composerRecordingStartedPublisher: AnyPublisher<Date?, Never> { recordingStarted.eraseToAnyPublisher() }
    var composerSessionEventPublisher: AnyPublisher<BuddyDictationSessionEvent, Never> { events.eraseToAnyPublisher() }

    func startComposerDictation(inputID: UUID, onTranscript: @escaping (String) -> Void) async {
        startedInputIDs.append(inputID)
        self.onTranscript = onTranscript
        isDictationInProgress = true
        recordingStarted.send(Date(timeIntervalSince1970: 1_800_000_000))
    }

    func stopComposerDictation() { stopCount += 1 }

    func cancelComposerDictation() {
        cancelCount += 1
        isDictationInProgress = false
        events.send(.discarded(inputID: startedInputIDs.last))
    }

    func finish(transcript: String) {
        isDictationInProgress = false
        recordingStarted.send(nil)
        onTranscript?(transcript)
    }

    func finishEmpty() {
        isDictationInProgress = false
        recordingStarted.send(nil)
        events.send(.discarded(inputID: startedInputIDs.last))
    }
}

@MainActor
struct PickyComposerDictationControllerTests {
    private func startListening(
        _ controller: PickyComposerDictationController,
        sessionID: String
    ) async throws {
        controller.toggle(sessionID: sessionID)
        try await waitUntil {
            if case .listening(sessionID, _) = controller.phase { return true }
            return false
        }
    }

    @Test func secondPressTranscribesIntoThatPickleDraftWithoutSending() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)

        try await startListening(controller, sessionID: "pickle-a")
        controller.toggle(sessionID: "pickle-a")
        #expect(controller.phase == .transcribing(sessionID: "pickle-a"))
        #expect(driver.stopCount == 1)

        driver.finish(transcript: "  타임아웃 난 요청만 정리해줘 ")

        let transcript = try #require(controller.pendingTranscript)
        #expect(transcript.sessionID == "pickle-a")
        #expect(transcript.text == "타임아웃 난 요청만 정리해줘")
        #expect(controller.phase == .idle)
        controller.consumeTranscript(id: transcript.id)
        #expect(controller.pendingTranscript == nil)
    }

    @Test func emptyResultShowsNoticeAndProducesNoTranscript() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver, failureDisplayDuration: .seconds(60))

        try await startListening(controller, sessionID: "pickle-a")
        controller.toggle(sessionID: "pickle-a")
        driver.finishEmpty()

        #expect(controller.phase == .failed(sessionID: "pickle-a", .noSpeech))
        #expect(controller.pendingTranscript == nil)
    }

    @Test func permissionFailureIsReportedSeparately() async throws {
        let driver = FakeComposerDictationDriver()
        driver.hasDictationPermissionProblem = true
        let controller = PickyComposerDictationController(driver: driver, failureDisplayDuration: .seconds(60))

        try await startListening(controller, sessionID: "pickle-a")
        driver.events.send(.failed(inputID: driver.startedInputIDs.last, message: "permission"))

        #expect(controller.phase == .failed(sessionID: "pickle-a", .permissionRequired))
    }

    @Test func cancelDiscardsLateTranscript() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)

        try await startListening(controller, sessionID: "pickle-a")
        controller.cancel(sessionID: "pickle-a")
        driver.finish(transcript: "보내면 안 되는 말")

        #expect(driver.cancelCount == 1)
        #expect(controller.phase == .idle)
        #expect(controller.pendingTranscript == nil)
    }

    @Test func otherPickleCannotStartWhileOneIsRecording() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)

        try await startListening(controller, sessionID: "pickle-a")
        controller.toggle(sessionID: "pickle-b")

        #expect(driver.startedInputIDs.count == 1)
        #expect(controller.phase.sessionID == "pickle-a")
        #expect(PickyComposerMicPresentation(phase: controller.phase, sessionID: "pickle-b").isEnabled == false)
    }

    /// The global voice pipeline must ignore composer sessions, including the
    /// late `discarded` event a cancel produces after the session has ended.
    @Test func issuedInputIDsStayOwnedAfterTheSessionEnds() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)

        try await startListening(controller, sessionID: "pickle-a")
        let inputID = try #require(driver.startedInputIDs.last)
        controller.cancel(sessionID: "pickle-a")

        #expect(controller.owns(inputID: inputID))
        #expect(controller.owns(inputID: UUID()) == false)
        #expect(controller.owns(inputID: nil) == false)
    }

    @Test(arguments: [
        ("", "새 문장", "새 문장"),
        ("로그도 같이 확인해줘", "새 문장", "로그도 같이 확인해줘 새 문장"),
        ("첫 줄\n", "새 문장", "첫 줄\n새 문장"),
        ("끝에 공백 ", "새 문장", "끝에 공백 새 문장"),
        ("그대로", "   ", "그대로"),
    ])
    func transcriptAppendsToTheEndOfTheDraft(draft: String, transcript: String, expected: String) {
        #expect(PickyComposerDictationDraftPolicy.draft(draft, appending: transcript) == expected)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for condition")
    }
}

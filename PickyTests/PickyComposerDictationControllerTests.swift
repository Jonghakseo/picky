//
//  PickyComposerDictationControllerTests.swift
//  PickyTests
//
//  Composer mic contract: dictation fills the Pickle's own draft for review and
//  never sends; empty or failed results leave the draft untouched.
//

import AppKit
import Combine
import Foundation
import SwiftUI
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

    @Test func composerCommandDAppendsAndPersistsOnlyItsOwnDraftWithoutSending() async throws {
        let suite = "PickyComposerCommandD-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = PickyUserDefaultsComposerDraftStore(defaults: defaults)
        drafts.setDraft("기존 초안", for: "pickle-a")
        drafts.setDraft("다른 초안", for: "pickle-b")
        let client = FakePickyAgentClient()
        let model = PickySessionListViewModel(client: client,
            notificationCenter: PickyNoopNotificationCenter(), composerDraftStore: drafts,
            composerAttachmentDraftStore: PickyUserDefaultsComposerAttachmentDraftStore(defaults: defaults))
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let session = PickyConversationSessionCard.fromAgentSession(PickyAgentSession(
            id: "pickle-a", title: "Shortcut test", status: .completed, cwd: "/tmp/picky",
            createdAt: date, updatedAt: date, logs: [], tools: [], artifacts: [], changedFiles: []))
        let host = NSHostingView(rootView: AnyView(
            PickyConversationComposerView(session: session, viewModel: model)
                .environment(\.pickyComposerDictation, controller)))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        host.layoutSubtreeIfNeeded()
        defer { host.rootView = AnyView(EmptyView()) }

        func editor(in view: NSView) -> PickyIMENSTextView? {
            if let editor = view as? PickyIMENSTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        try await waitUntil { editor(in: host)?.string == "기존 초안" }
        let nativeEditor = try #require(editor(in: host))
        let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        nativeEditor.keyDown(with: shortcut)
        try await waitUntil {
            if case .listening("pickle-a", _) = controller.phase { return true }
            return false
        }
        nativeEditor.keyDown(with: shortcut)
        #expect(controller.phase == .transcribing(sessionID: "pickle-a"))
        driver.finish(transcript: "새 문장")
        try await waitUntil { drafts.draft(for: "pickle-a") == "기존 초안 새 문장" }

        #expect(nativeEditor.string == "기존 초안 새 문장")
        #expect(drafts.draft(for: "pickle-b") == "다른 초안")
        #expect(client.submitted.isEmpty)
        #expect(!client.sentCommands.contains { $0.type == .followUp || $0.type == .steer })
    }

    @Test func secondPressTranscribesIntoThatPickleDraftWithoutSending() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)
        var delivered: [PickyComposerDictationTranscript] = []
        let subscription = controller.transcripts.sink { delivered.append($0) }
        defer { subscription.cancel() }

        try await startListening(controller, sessionID: "pickle-a")
        controller.toggle(sessionID: "pickle-a")
        #expect(controller.phase == .transcribing(sessionID: "pickle-a"))
        #expect(driver.stopCount == 1)

        driver.finish(transcript: "  타임아웃 난 요청만 정리해줘 ")

        #expect(delivered.map(\.sessionID) == ["pickle-a"])
        #expect(delivered.map(\.text) == ["타임아웃 난 요청만 정리해줘"])
        #expect(controller.phase == .idle)
    }

    /// Regression: one utterance ("밥은 먹거리죠?") was appended twice because the
    /// composer re-subscribes after its draft changes and the old publisher
    /// replayed the last transcript. A later subscriber must receive nothing.
    @Test func finishedTranscriptIsDeliveredOnceAndNeverReplayed() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver)
        var firstSubscriber: [String] = []
        let first = controller.transcripts.sink { firstSubscriber.append($0.text) }

        try await startListening(controller, sessionID: "pickle-a")
        controller.toggle(sessionID: "pickle-a")
        driver.finish(transcript: "밥은 먹거리죠?")
        first.cancel()

        var resubscribed: [String] = []
        let second = controller.transcripts.sink { resubscribed.append($0.text) }
        defer { second.cancel() }

        #expect(firstSubscriber == ["밥은 먹거리죠?"])
        #expect(resubscribed.isEmpty)
    }

    @Test func emptyResultShowsNoticeAndProducesNoTranscript() async throws {
        let driver = FakeComposerDictationDriver()
        let controller = PickyComposerDictationController(driver: driver, failureDisplayDuration: .seconds(60))
        var delivered: [PickyComposerDictationTranscript] = []
        let subscription = controller.transcripts.sink { delivered.append($0) }
        defer { subscription.cancel() }

        try await startListening(controller, sessionID: "pickle-a")
        controller.toggle(sessionID: "pickle-a")
        driver.finishEmpty()

        #expect(controller.phase == .failed(sessionID: "pickle-a", .noSpeech))
        #expect(delivered.isEmpty)
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
        var delivered: [PickyComposerDictationTranscript] = []
        let subscription = controller.transcripts.sink { delivered.append($0) }
        defer { subscription.cancel() }

        try await startListening(controller, sessionID: "pickle-a")
        controller.cancel(sessionID: "pickle-a")
        driver.finish(transcript: "보내면 안 되는 말")

        #expect(driver.cancelCount == 1)
        #expect(controller.phase == .idle)
        #expect(delivered.isEmpty)
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

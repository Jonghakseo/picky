//
//  PickyComposerDictationController.swift
//  Picky
//
//  Click-to-toggle dictation owned by one Pickle composer. The transcript is
//  appended to that composer's draft for review; it is never sent directly.
//

import Combine
import Foundation
import SwiftUI

/// The dictation engine the composer drives. `BuddyDictationManager` is the
/// production engine; tests substitute a fake so no microphone is opened.
@MainActor
protocol PickyComposerDictationDriving: AnyObject {
    var isDictationInProgress: Bool { get }
    var hasDictationPermissionProblem: Bool { get }
    /// Emits the recording start time once audio is flowing, nil otherwise.
    var composerRecordingStartedPublisher: AnyPublisher<Date?, Never> { get }
    var composerSessionEventPublisher: AnyPublisher<BuddyDictationSessionEvent, Never> { get }
    func startComposerDictation(inputID: UUID, onTranscript: @escaping (String) -> Void) async
    func stopComposerDictation()
    func cancelComposerDictation()
}

extension BuddyDictationManager: PickyComposerDictationDriving {
    var hasDictationPermissionProblem: Bool { currentPermissionProblem != nil }

    var composerRecordingStartedPublisher: AnyPublisher<Date?, Never> {
        $microphoneButtonRecordingStartedAt.eraseToAnyPublisher()
    }

    var composerSessionEventPublisher: AnyPublisher<BuddyDictationSessionEvent, Never> {
        sessionEventPublisher.eraseToAnyPublisher()
    }

    func startComposerDictation(inputID: UUID, onTranscript: @escaping (String) -> Void) async {
        await startPersistentDictationFromMicrophoneButton(
            inputID: inputID,
            currentDraftText: "",
            updateDraftText: onTranscript,
            submitDraftText: { _ in }
        )
    }

    func stopComposerDictation() {
        stopPersistentDictationFromMicrophoneButton()
    }

    func cancelComposerDictation() {
        cancelCurrentDictation(preserveDraftText: false)
    }
}

enum PickyComposerDictationFailure: Equatable {
    /// Nothing was recognized, or the recording was too short to keep.
    case noSpeech
    case permissionRequired
    case failed
}

enum PickyComposerDictationPhase: Equatable {
    case idle
    case preparing(sessionID: String)
    case listening(sessionID: String, startedAt: Date)
    case transcribing(sessionID: String)
    case failed(sessionID: String, PickyComposerDictationFailure)

    var sessionID: String? {
        switch self {
        case .idle: nil
        case .preparing(let id), .listening(let id, _), .transcribing(let id), .failed(let id, _): id
        }
    }

    /// True while the microphone or transcription is in use.
    var isActive: Bool {
        switch self {
        case .preparing, .listening, .transcribing: true
        case .idle, .failed: false
        }
    }
}

struct PickyComposerDictationTranscript: Equatable {
    let id: UUID
    let sessionID: String
    let text: String
}

enum PickyComposerDictationDraftPolicy {
    /// Appends a transcript to the end of the draft, separated by one space
    /// unless the draft is empty or already ends in whitespace.
    static func draft(_ draft: String, appending transcript: String) -> String {
        let incoming = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return draft }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return incoming }
        if let last = draft.last, last.isWhitespace || last.isNewline {
            return draft + incoming
        }
        return draft + " " + incoming
    }
}

@MainActor
final class PickyComposerDictationController: ObservableObject {
    @Published private(set) var phase: PickyComposerDictationPhase = .idle
    /// The latest finished transcript. The owning composer appends it to its
    /// draft and calls `consumeTranscript(id:)`.
    @Published private(set) var pendingTranscript: PickyComposerDictationTranscript?

    private let driver: any PickyComposerDictationDriving
    private let failureDisplayDuration: Duration
    private var activeInputID: UUID?
    /// Every ID this controller issued. Late `failed`/`discarded` events for a
    /// finished composer session must still be kept out of the global voice
    /// pipeline, so the set is not cleared when a session ends.
    private var issuedInputIDs: Set<UUID> = []
    private var cancelRequested = false
    private var failureResetTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        driver: any PickyComposerDictationDriving,
        failureDisplayDuration: Duration = .seconds(4)
    ) {
        self.driver = driver
        self.failureDisplayDuration = failureDisplayDuration
        driver.composerRecordingStartedPublisher
            .sink { [weak self] startedAt in self?.handleRecordingStarted(startedAt) }
            .store(in: &cancellables)
        driver.composerSessionEventPublisher
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    /// True when the dictation event belongs to a composer session, so the
    /// global voice pipeline must ignore it.
    func owns(inputID: UUID?) -> Bool {
        guard let inputID else { return false }
        return issuedInputIDs.contains(inputID)
    }

    /// Whether `sessionID`'s mic button can start a new recording right now.
    func canStart(sessionID: String) -> Bool {
        if phase.isActive { return false }
        return !driver.isDictationInProgress
    }

    /// First press starts recording for `sessionID`; the next press stops it
    /// and transcribes into that Pickle's draft.
    func toggle(sessionID: String) {
        switch phase {
        case .preparing(let owner) where owner == sessionID:
            cancel(sessionID: sessionID)
        case .listening(let owner, _) where owner == sessionID:
            phase = .transcribing(sessionID: sessionID)
            driver.stopComposerDictation()
        case .transcribing, .preparing, .listening:
            return
        case .idle, .failed:
            start(sessionID: sessionID)
        }
    }

    /// Abandons the recording without touching the draft.
    func cancel(sessionID: String) {
        guard phase.isActive, phase.sessionID == sessionID else { return }
        cancelRequested = true
        driver.cancelComposerDictation()
        finish(.idle)
    }

    func consumeTranscript(id: UUID) {
        guard pendingTranscript?.id == id else { return }
        pendingTranscript = nil
    }

    private func start(sessionID: String) {
        guard !driver.isDictationInProgress else { return }
        failureResetTask?.cancel()
        let inputID = UUID()
        activeInputID = inputID
        issuedInputIDs.insert(inputID)
        cancelRequested = false
        phase = .preparing(sessionID: sessionID)
        Task { @MainActor [weak self, driver] in
            await driver.startComposerDictation(inputID: inputID) { transcript in
                self?.deliver(transcript, inputID: inputID)
            }
        }
    }

    private func handleRecordingStarted(_ startedAt: Date?) {
        guard let startedAt, case .preparing(let sessionID) = phase else { return }
        phase = .listening(sessionID: sessionID, startedAt: startedAt)
    }

    private func deliver(_ transcript: String, inputID: UUID) {
        guard inputID == activeInputID, let sessionID = phase.sessionID, !cancelRequested else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finish(.failed(sessionID: sessionID, .noSpeech))
            return
        }
        pendingTranscript = PickyComposerDictationTranscript(id: UUID(), sessionID: sessionID, text: text)
        finish(.idle)
    }

    private func handle(_ event: BuddyDictationSessionEvent) {
        switch event {
        case .failed(let inputID, _):
            guard let inputID, inputID == activeInputID, let sessionID = phase.sessionID else { return }
            let failure: PickyComposerDictationFailure = driver.hasDictationPermissionProblem ? .permissionRequired : .failed
            finish(.failed(sessionID: sessionID, failure))
        case .discarded(let inputID):
            guard let inputID, inputID == activeInputID, let sessionID = phase.sessionID else { return }
            finish(cancelRequested ? .idle : .failed(sessionID: sessionID, .noSpeech))
        }
    }

    private func finish(_ next: PickyComposerDictationPhase) {
        activeInputID = nil
        phase = next
        guard case .failed(let sessionID, _) = next else { return }
        let duration = failureDisplayDuration
        failureResetTask?.cancel()
        failureResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, case .failed(let current, _) = self.phase, current == sessionID else { return }
            self.phase = .idle
        }
    }
}

private struct PickyComposerDictationKey: EnvironmentKey {
    static let defaultValue: PickyComposerDictationController? = nil
}

extension EnvironmentValues {
    /// Nil outside the live HUD (previews, galleries, tests): the composer then
    /// hides its mic button.
    var pickyComposerDictation: PickyComposerDictationController? {
        get { self[PickyComposerDictationKey.self] }
        set { self[PickyComposerDictationKey.self] = newValue }
    }
}

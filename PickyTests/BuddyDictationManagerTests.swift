//
//  BuddyDictationManagerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

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
}

import Testing
@testable import Picky

struct PickySettingsTerminationDrainTests {
    @MainActor
    @Test func onlyActiveTerminationTokenMayReply() {
        let drain = PickySettingsTerminationDrain()
        guard let first = drain.begin() else {
            Issue.record("Expected an initial termination token")
            return
        }
        #expect(drain.begin() == nil)
        #expect(drain.settle(token: first))
        #expect(!drain.settle(token: first))

        let second = drain.begin()
        #expect(second != nil)
        #expect(second != first)
    }

    @MainActor
    @Test func timeoutSettlesImmediatelyWhenDrainCompletesLate() {
        let drain = PickySettingsTerminationDrain()
        var drainCompletion: (@MainActor (Bool) -> Void)?
        var timeoutCompletion: (@MainActor () -> Void)?
        var replies: [Bool] = []

        #expect(drain.beginRace(
            drain: { drainCompletion = $0 },
            scheduleTimeout: { timeoutCompletion = $0 },
            onSettled: { replies.append($0) }
        ))
        guard let timeoutCompletion, let drainCompletion else {
            Issue.record("Expected deterministic drain and timeout callbacks")
            return
        }

        timeoutCompletion()
        #expect(replies == [false])
        drainCompletion(true)
        #expect(replies == [false])
    }

    @MainActor
    @Test func successfulDrainWinsWhenItCompletesBeforeTimeout() {
        let drain = PickySettingsTerminationDrain()
        var drainCompletion: (@MainActor (Bool) -> Void)?
        var timeoutCompletion: (@MainActor () -> Void)?
        var replies: [Bool] = []

        #expect(drain.beginRace(
            drain: { drainCompletion = $0 },
            scheduleTimeout: { timeoutCompletion = $0 },
            onSettled: { replies.append($0) }
        ))
        guard let timeoutCompletion, let drainCompletion else {
            Issue.record("Expected deterministic drain and timeout callbacks")
            return
        }

        drainCompletion(true)
        #expect(replies == [true])
        timeoutCompletion()
        #expect(replies == [true])
    }

    @MainActor
    @Test func failedDrainCancelsTerminationBeforeTimeout() {
        let drain = PickySettingsTerminationDrain()
        var drainCompletion: (@MainActor (Bool) -> Void)?
        var timeoutCompletion: (@MainActor () -> Void)?
        var replies: [Bool] = []

        #expect(drain.beginRace(
            drain: { drainCompletion = $0 },
            scheduleTimeout: { timeoutCompletion = $0 },
            onSettled: { replies.append($0) }
        ))
        guard let timeoutCompletion, let drainCompletion else {
            Issue.record("Expected deterministic drain and timeout callbacks")
            return
        }

        drainCompletion(false)
        #expect(replies == [false])
        timeoutCompletion()
        #expect(replies == [false])
    }
}

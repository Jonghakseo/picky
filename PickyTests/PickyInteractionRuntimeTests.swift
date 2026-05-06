import Foundation
import Testing
@testable import Picky

struct PickyInteractionRuntimeTests {
    private let inputA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let eventA = UUID(uuidString: "10000000-0000-0000-0000-00000000000A")!
    private let eventB = UUID(uuidString: "10000000-0000-0000-0000-00000000000B")!
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dispatchIncrementsSequenceMonotonically() async {
        let runtime = PickyInteractionRuntime()

        let first = await runtime.dispatch(envelope(id: eventA, event: .textSubmitted(text: "hello", inputID: inputA)))
        let second = await runtime.dispatch(envelope(id: eventB, event: .textSubmissionFailed(message: "boom", inputID: inputA)))

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(first.journalRecords.allSatisfy { $0.sequence == 1 })
        #expect(second.journalRecords.allSatisfy { $0.sequence == 2 })
    }

    @Test func dispatchAppliesTransitionsInEnvelopeOrder() async {
        let runtime = PickyInteractionRuntime()

        _ = await runtime.dispatch(envelope(id: eventA, event: .textSubmitted(text: "hello", inputID: inputA)))
        let second = await runtime.dispatch(envelope(id: eventB, event: .textSubmissionFailed(message: "boom", inputID: inputA)))

        #expect(second.state.input == .idle)
        #expect(second.state.pendingTextInputs[inputA] == nil)
    }

    @Test func dispatchCriticalPathReturnsTransitionWithoutAsyncEffectWork() async {
        let runtime = PickyInteractionRuntime()
        let result = await runtime.dispatch(envelope(id: eventA, event: .textSubmitted(text: "hello", inputID: inputA)))

        #expect(result.effects == [.captureTextContext(inputID: inputA, text: "hello")])
        #expect(result.state.pendingTextInputs[inputA] == PickyTextInputState(text: "hello"))
    }

    @Test func callerCanDetectStaleProjectionSequence() async {
        let runtime = PickyInteractionRuntime()
        let first = await runtime.dispatch(envelope(id: eventA, event: .appStarted))
        let second = await runtime.dispatch(envelope(id: eventB, event: .appStarted))

        var lastPublishedSequence = second.sequence
        let shouldPublishFirst = first.sequence > lastPublishedSequence
        let shouldPublishSecondAgain = second.sequence > lastPublishedSequence
        lastPublishedSequence = max(lastPublishedSequence, second.sequence)

        #expect(!shouldPublishFirst)
        #expect(!shouldPublishSecondAgain)
        #expect(lastPublishedSequence == 2)
    }

    private func envelope(id: UUID, event: PickyInteractionEvent) -> PickyInteractionEnvelope {
        // Production callers always tag textSubmitted/voiceSubmitted envelopes
        // with a real source (.text, .quickInput, .voice, ...). Use .text here
        // so the reducer's source-aware branch sees realistic input.
        PickyInteractionEnvelope(id: id, occurredAt: baseDate, event: event, correlation: .init(source: .text))
    }
}

import Foundation

protocol PickyInteractionRuntimeProtocol: Actor {
    func dispatch(_ envelope: PickyInteractionEnvelope) -> PickyInteractionDispatchResult
}

struct PickyInteractionDispatchResult: Equatable {
    let sequence: UInt64
    let state: PickyInteractionState
    let effects: [PickyInteractionEffect]
    let journalRecords: [PickyInteractionJournalRecord]
}

actor PickyInteractionRuntime: PickyInteractionRuntimeProtocol {
    private var state: PickyInteractionState
    private var sequence: UInt64
    private let ringBufferLimit: Int
    private var ringBuffer: [PickyInteractionJournalRecord]

    init(initialState: PickyInteractionState = PickyInteractionState(), ringBufferLimit: Int = 500) {
        self.state = initialState
        self.sequence = 0
        self.ringBufferLimit = max(1, ringBufferLimit)
        self.ringBuffer = []
    }

    func dispatch(_ envelope: PickyInteractionEnvelope) -> PickyInteractionDispatchResult {
        sequence += 1
        let transition = PickyInteractionReducer.reduce(state: state, envelope: envelope)
        state = transition.state
        let sequencedRecords = transition.journalRecords.map { $0.withSequence(sequence) }
        ringBuffer.append(contentsOf: sequencedRecords)
        if ringBuffer.count > ringBufferLimit {
            ringBuffer.removeFirst(ringBuffer.count - ringBufferLimit)
        }
        return PickyInteractionDispatchResult(
            sequence: sequence,
            state: state,
            effects: transition.effects,
            journalRecords: sequencedRecords
        )
    }

    func currentState() -> PickyInteractionState { state }

    func recentRecords(limit: Int) -> [PickyInteractionJournalRecord] {
        guard limit < ringBuffer.count else { return ringBuffer }
        return Array(ringBuffer.suffix(max(0, limit)))
    }
}

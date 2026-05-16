import Foundation

@MainActor
protocol PickyInteractionEnvelopeMaking: AnyObject {
    func makeEnvelope(event: PickyInteractionEvent, correlation: PickyInteractionCorrelation) -> PickyInteractionEnvelope
}

@MainActor
protocol PickyInteractionEffectRunning: AnyObject {
    func run(_ effects: [PickyInteractionEffect])
}

@MainActor
final class PickyInteractionCoordinator {
    typealias EffectCompletionHandler = @MainActor (_ event: PickyInteractionEvent, _ correlation: PickyInteractionCorrelation) -> Void

    private struct QueuedInteractionEvent {
        let event: PickyInteractionEvent
        let correlation: PickyInteractionCorrelation
    }

    private let runtime: any PickyInteractionRuntimeProtocol
    private let journal: PickyInteractionJournal?
    private let envelopeMaker: PickyInteractionEnvelopeMaking
    private let effectRunner: PickyInteractionEffectRunning
    private var eventQueue: [QueuedInteractionEvent] = []
    private var isDraining = false
    private var lastPublishedSequence: UInt64 = 0

    private(set) var projection: PickyInteractionProjection
    var onProjectionPublished: ((UInt64, PickyInteractionProjection) -> Void)?
    var onStaleProjectionDropped: ((UInt64, UInt64) -> Void)?

    init(
        runtime: any PickyInteractionRuntimeProtocol = PickyInteractionRuntime(),
        journal: PickyInteractionJournal? = nil,
        envelopeMaker: PickyInteractionEnvelopeMaking,
        effectRunner: PickyInteractionEffectRunning? = nil,
        initialProjection: PickyInteractionProjection = PickyInteractionProjection(state: PickyInteractionState())
    ) {
        self.runtime = runtime
        self.journal = journal
        self.envelopeMaker = envelopeMaker
        self.effectRunner = effectRunner ?? PickyInteractionNoopEffectRunner()
        self.projection = initialProjection
    }

    func accept(_ event: PickyInteractionEvent, correlation: PickyInteractionCorrelation = .init(source: .unknown)) {
        eventQueue.append(QueuedInteractionEvent(event: event, correlation: correlation))
        drainQueueIfNeeded()
    }

    func effectCompleted(_ event: PickyInteractionEvent, correlation: PickyInteractionCorrelation = .init(source: .unknown)) {
        accept(event, correlation: correlation)
    }

    private func drainQueueIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor in
            defer {
                isDraining = false
                if !eventQueue.isEmpty {
                    drainQueueIfNeeded()
                }
            }
            while !eventQueue.isEmpty {
                let next = eventQueue.removeFirst()
                let envelope = envelopeMaker.makeEnvelope(event: next.event, correlation: next.correlation)
                let result = await runtime.dispatch(envelope)
                guard result.sequence > lastPublishedSequence else {
                    onStaleProjectionDropped?(result.sequence, lastPublishedSequence)
                    continue
                }
                lastPublishedSequence = result.sequence
                projection = PickyInteractionProjection(state: result.state)
                onProjectionPublished?(result.sequence, projection)
                effectRunner.run(result.effects)
                if let journal {
                    let records = result.journalRecords
                    Task { await journal.append(records) }
                }
            }
        }
    }
}

final class PickyInteractionNoopEffectRunner: PickyInteractionEffectRunning {
    func run(_ effects: [PickyInteractionEffect]) {}
}

final class PickyInteractionStaticEnvelopeMaker: PickyInteractionEnvelopeMaking {
    private let clock: () -> Date
    private let idGenerator: () -> UUID

    init(clock: @escaping () -> Date = Date.init, idGenerator: @escaping () -> UUID = UUID.init) {
        self.clock = clock
        self.idGenerator = idGenerator
    }

    func makeEnvelope(event: PickyInteractionEvent, correlation: PickyInteractionCorrelation) -> PickyInteractionEnvelope {
        PickyInteractionEnvelope(id: idGenerator(), occurredAt: clock(), event: event, correlation: correlation)
    }
}

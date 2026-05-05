import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyInteractionCoordinatorTests {
    private let inputA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let eventA = UUID(uuidString: "10000000-0000-0000-0000-00000000000A")!
    private let eventB = UUID(uuidString: "10000000-0000-0000-0000-00000000000B")!
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func acceptEnqueuesEventsFIFO() async throws {
        let envelopeMaker = FakeEnvelopeMaker(ids: [eventA, eventB], occurredAt: baseDate)
        let effectRunner = FakeEffectRunner()
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: envelopeMaker,
            effectRunner: effectRunner
        )
        var published: [(UInt64, PickyInputPhase)] = []
        coordinator.onProjectionPublished = { sequence, projection in
            published.append((sequence, projection.state.input))
        }

        coordinator.accept(.textSubmitted(text: "first", inputID: inputA), correlation: .init(inputID: inputA, source: .text))
        coordinator.accept(.textSubmissionFailed(message: "boom", inputID: inputA), correlation: .init(inputID: inputA, source: .text))

        try await waitUntil { published.count == 2 }

        #expect(envelopeMaker.events == [
            .textSubmitted(text: "first", inputID: inputA),
            .textSubmissionFailed(message: "boom", inputID: inputA)
        ])
        #expect(published.map(\.0) == [1, 2])
        #expect(published[0].1 == .textSubmitting(inputID: inputA, text: "first"))
        #expect(published[1].1 == .idle)
    }

    @Test func synchronousEffectCallbackIsProcessedAfterCurrentProjectionAndEffects() async throws {
        let context = context(id: "text-context", source: "text", transcript: "hello")
        let envelopeMaker = FakeEnvelopeMaker(ids: [eventA, eventB], occurredAt: baseDate)
        let effectRunner = FakeEffectRunner()
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: envelopeMaker,
            effectRunner: effectRunner
        )
        effectRunner.onRun = { effects in
            if effects.contains(.captureTextContext(inputID: self.inputA, text: "hello")) {
                coordinator.effectCompleted(
                    .textContextCaptured(inputID: self.inputA, context: context),
                    correlation: .init(inputID: self.inputA, contextID: "text-context", source: .text)
                )
            }
        }
        var published: [(UInt64, PickyOutputPhase)] = []
        var submitEffectObservedAfterSequence: [UInt64] = []
        coordinator.onProjectionPublished = { sequence, projection in
            published.append((sequence, projection.state.output))
        }
        effectRunner.onRun = { effects in
            if effects.contains(.captureTextContext(inputID: self.inputA, text: "hello")) {
                coordinator.effectCompleted(
                    .textContextCaptured(inputID: self.inputA, context: context),
                    correlation: .init(inputID: self.inputA, contextID: "text-context", source: .text)
                )
            }
            if effects.contains(.submitText(inputID: self.inputA, context: context, text: "hello")) {
                submitEffectObservedAfterSequence.append(published.last?.0 ?? 0)
            }
        }

        coordinator.accept(.textSubmitted(text: "hello", inputID: inputA), correlation: .init(inputID: inputA, source: .text))

        try await waitUntil { published.count == 2 && submitEffectObservedAfterSequence.count == 1 }

        #expect(published.map(\.0) == [1, 2])
        #expect(published[0].1 == .idle)
        #expect(published[1].1 == .waitingForAgent(inputID: inputA, contextID: "text-context", promptPreview: "hello"))
        #expect(submitEffectObservedAfterSequence == [2])
    }

    @Test func effectRunnerReceivesEffectsAfterProjectionUpdate() async throws {
        let envelopeMaker = FakeEnvelopeMaker(ids: [eventA], occurredAt: baseDate)
        let effectRunner = FakeEffectRunner()
        let coordinator = PickyInteractionCoordinator(
            runtime: PickyInteractionRuntime(),
            envelopeMaker: envelopeMaker,
            effectRunner: effectRunner
        )
        var publishedCountAtEffectRun = -1
        var published: [UInt64] = []
        coordinator.onProjectionPublished = { sequence, _ in
            published.append(sequence)
        }
        effectRunner.onRun = { _ in
            publishedCountAtEffectRun = published.count
        }

        coordinator.accept(.textSubmitted(text: "hello", inputID: inputA), correlation: .init(inputID: inputA, source: .text))

        try await waitUntil { publishedCountAtEffectRun == 1 }

        #expect(published == [1])
        #expect(publishedCountAtEffectRun == 1)
    }

    @Test func projectionSequenceNeverMovesBackwards() async throws {
        let coordinator = PickyInteractionCoordinator(
            runtime: NonMonotonicRuntimeAdapter(),
            envelopeMaker: FakeEnvelopeMaker(ids: [eventA, eventB], occurredAt: baseDate),
            effectRunner: FakeEffectRunner()
        )
        var published: [UInt64] = []
        var dropped: [(UInt64, UInt64)] = []
        coordinator.onProjectionPublished = { sequence, _ in published.append(sequence) }
        coordinator.onStaleProjectionDropped = { stale, last in dropped.append((stale, last)) }

        coordinator.accept(.appStarted)
        coordinator.accept(.appStarted)

        try await waitUntil { dropped.count == 1 }

        #expect(published == [2])
        #expect(dropped.first?.0 == 1)
        #expect(dropped.first?.1 == 2)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }

    private func context(id: String, source: String, transcript: String?) -> PickyContextPacket {
        PickyContextPacket(
            id: id,
            source: source,
            capturedAt: baseDate,
            transcript: transcript,
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }
}

@MainActor
private final class FakeEnvelopeMaker: PickyInteractionEnvelopeMaking {
    private var ids: [UUID]
    private let occurredAt: Date
    private(set) var events: [PickyInteractionEvent] = []

    init(ids: [UUID], occurredAt: Date) {
        self.ids = ids
        self.occurredAt = occurredAt
    }

    func makeEnvelope(event: PickyInteractionEvent, correlation: PickyInteractionCorrelation) -> PickyInteractionEnvelope {
        events.append(event)
        return PickyInteractionEnvelope(id: ids.removeFirst(), occurredAt: occurredAt, event: event, correlation: correlation)
    }
}

@MainActor
private final class FakeEffectRunner: PickyInteractionEffectRunning {
    private(set) var runs: [[PickyInteractionEffect]] = []
    var onRun: (([PickyInteractionEffect]) -> Void)?

    func run(_ effects: [PickyInteractionEffect]) {
        runs.append(effects)
        onRun?(effects)
    }
}

private actor NonMonotonicRuntimeAdapter: PickyInteractionRuntimeProtocol {
    private var callCount = 0

    func dispatch(_ envelope: PickyInteractionEnvelope) -> PickyInteractionDispatchResult {
        callCount += 1
        let sequence: UInt64 = callCount == 1 ? 2 : 1
        return PickyInteractionDispatchResult(
            sequence: sequence,
            state: PickyInteractionState(),
            effects: [],
            journalRecords: []
        )
    }
}

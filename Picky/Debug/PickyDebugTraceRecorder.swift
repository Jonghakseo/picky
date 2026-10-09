//
//  PickyDebugTraceRecorder.swift
//  Picky
//
//  Always-on, bounded, metadata-only trace buffer for `picky-debug`.
//
//  The recorder owns two things: a bounded outbound queue with exactly one
//  in-flight publish, and the correlation map that links a CLI-injected command
//  to the `inputId` / `contextId` the production input path actually used.
//  Correlation is by identity, never by timestamp adjacency.
//
//  Trace delivery is best effort and must never slow or block real input. When
//  the socket stalls, records are dropped here and the loss is counted, because
//  a publish that never reached the daemon leaves no daemon sequence gap for a
//  reader to notice.
//

import Foundation

@MainActor
final class PickyDebugTraceRecorder {
    struct Configuration {
        /// Records held while a publish is pending. Oldest records are dropped
        /// first so a stalled socket cannot grow memory without bound.
        var pendingCapacity: Int = 500
        /// Protocol cap for one `publishDebugTrace` message.
        var batchLimit: Int = 100
        /// Correlation entries retained per key space.
        var correlationCapacity: Int = 64
        /// Quiet period after a failed publish. Without it a dead socket would
        /// be retried once per recorded transition.
        var failureBackoffMs: Double = 1_000

        init(
            pendingCapacity: Int = 500,
            batchLimit: Int = 100,
            correlationCapacity: Int = 64,
            failureBackoffMs: Double = 1_000
        ) {
            self.pendingCapacity = max(1, pendingCapacity)
            self.batchLimit = max(1, min(100, batchLimit))
            self.correlationCapacity = max(1, correlationCapacity)
            self.failureBackoffMs = max(0, failureBackoffMs)
        }
    }

    /// One outbound message: the records plus how much previously lost history
    /// its leading notice claims to account for.
    private struct OutboundBatch {
        var records: [PickyDebugTraceRecord]
        var reportedLoss: Int
        var payloadCount: Int
    }

    private let configuration: Configuration
    private let publish: ([PickyDebugTraceRecord]) async -> Bool
    private let clock: () -> Date
    private let monotonic: () -> Double

    private var pending: [PickyDebugTraceRecord] = []
    private var drainTask: Task<Void, Never>?
    private var backoffUntilMs: Double = 0
    private var unreportedLoss = 0
    private var commandIdByInputId: [String: String] = [:]
    private var inputIdOrder: [String] = []
    private var commandIdByContextId: [String: String] = [:]
    private var contextIdOrder: [String] = []

    /// Total records accepted since launch, including dropped ones. Reported in
    /// the debug snapshot so a reader can tell a quiet app from a lost socket.
    private(set) var recordedCount = 0
    /// Records that never reached the daemon, by queue eviction or by a failed
    /// publish. Both are real gaps in the trace.
    private(set) var droppedCount = 0
    /// Publish attempts the transport refused. Separate from `droppedCount` so
    /// a single stalled batch is distinguishable from sustained socket loss.
    private(set) var transportFailureCount = 0

    var pendingCount: Int { pending.count }
    var pendingCapacity: Int { configuration.pendingCapacity }
    var hasInFlightPublish: Bool { drainTask != nil }

    init(
        configuration: Configuration = Configuration(),
        clock: @escaping () -> Date = Date.init,
        monotonic: @escaping () -> Double = { PickyDebugTraceClock.monotonicMs() },
        publish: @escaping ([PickyDebugTraceRecord]) async -> Bool
    ) {
        self.configuration = configuration
        self.clock = clock
        self.monotonic = monotonic
        self.publish = publish
    }

    // MARK: - Correlation

    /// Declares that `commandId` owns the input the app is about to start.
    /// Called with the exact `inputId` handed to the production input path, so
    /// every later record carrying that input (and the context it captures)
    /// inherits the command id.
    func bindInjection(commandId: String, inputID: UUID) {
        remember(key: inputID.uuidString, commandId: commandId, in: &commandIdByInputId, order: &inputIdOrder)
    }

    // MARK: - Recording

    func recordInteraction(_ sample: PickyInteractionTraceSample) {
        record(PickyInteractionTraceMapper.record(sample, now: clock(), monotonicMs: monotonic()))
    }

    /// Records an app-owned transition that does not come from the interaction
    /// reducer, such as the debug command boundary itself.
    func recordAppEvent(
        name: String,
        commandId: String? = nil,
        inputID: UUID? = nil,
        contextID: String? = nil,
        sessionID: String? = nil,
        outcome: String? = nil,
        modality: PickyDebugTraceModality? = nil,
        textLength: Int? = nil
    ) {
        record(PickyDebugTraceRecord(
            source: .app,
            name: name,
            timestamp: clock(),
            monotonicMs: monotonic(),
            inputId: inputID?.uuidString,
            contextId: contextID,
            sessionId: sessionID,
            commandId: commandId,
            outcome: outcome,
            modality: modality,
            textLength: textLength
        ))
    }

    func record(_ record: PickyDebugTraceRecord) {
        recordedCount += 1
        enqueue(correlated(record))
        scheduleDrain()
    }

    /// Publishes everything buffered right now and waits for the result,
    /// ignoring the failure backoff. Ordinary recording never waits on the
    /// socket, so this exists for tests and for a caller that needs the buffer
    /// settled before asserting on it.
    func flush() async {
        scheduleDrain(ignoringBackoff: true)
        await drainTask?.value
    }

    // MARK: - Private

    private func enqueue(_ record: PickyDebugTraceRecord) {
        pending.append(record)
        guard pending.count > configuration.pendingCapacity else { return }
        let excess = pending.count - configuration.pendingCapacity
        pending.removeFirst(excess)
        noteLoss(excess)
    }

    private func noteLoss(_ count: Int) {
        guard count > 0 else { return }
        droppedCount += count
        unreportedLoss += count
    }

    private func scheduleDrain(ignoringBackoff: Bool = false) {
        guard drainTask == nil else { return }
        guard ignoringBackoff || monotonic() >= backoffUntilMs else { return }
        guard !pending.isEmpty || unreportedLoss > 0 else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    /// Exactly one of these runs at a time, so a stalled socket holds one
    /// in-flight batch instead of a task per recorded transition.
    private func drain() async {
        defer { drainTask = nil }
        while let batch = nextBatch() {
            guard await publish(batch.records) else {
                transportFailureCount += 1
                // The batch never reached the daemon, which assigns sequences
                // on receipt, so nothing downstream can infer this gap.
                droppedCount += batch.payloadCount
                unreportedLoss += batch.payloadCount + batch.reportedLoss
                backoffUntilMs = monotonic() + configuration.failureBackoffMs
                return
            }
            // The socket took it, so stop holding the quiet period open.
            backoffUntilMs = 0
        }
    }

    private func nextBatch() -> OutboundBatch? {
        guard !pending.isEmpty || unreportedLoss > 0 else { return nil }
        var records: [PickyDebugTraceRecord] = []
        let reportedLoss = unreportedLoss
        // The loss notice is minted at send time, not at drop time, so a buffer
        // trim can never evict the one record that explains the gap.
        if reportedLoss > 0 {
            records.append(lossNotice(dropped: reportedLoss))
            unreportedLoss = 0
        }
        let payload = Array(pending.prefix(configuration.batchLimit - records.count))
        pending.removeFirst(payload.count)
        records.append(contentsOf: payload)
        return OutboundBatch(records: records, reportedLoss: reportedLoss, payloadCount: payload.count)
    }

    /// Surfaces trace loss in the trace itself rather than letting a gap look
    /// like the app went silent.
    private func lossNotice(dropped: Int) -> PickyDebugTraceRecord {
        PickyDebugTraceRecord(
            source: .app,
            name: "debug.traceDropped",
            timestamp: clock(),
            monotonicMs: monotonic(),
            outcome: "dropped=\(dropped)"
        )
    }

    private func correlated(_ record: PickyDebugTraceRecord) -> PickyDebugTraceRecord {
        guard record.commandId == nil else {
            learn(from: record)
            return record
        }
        var resolved: String?
        if let inputId = record.inputId { resolved = commandIdByInputId[inputId] }
        if resolved == nil, let contextId = record.contextId { resolved = commandIdByContextId[contextId] }
        let updated = record.adoptingCommandId(resolved)
        learn(from: updated)
        return updated
    }

    /// Propagates a known command id onto the other identifiers that appear
    /// alongside it, so `commandId -> inputId -> contextId` stays linked once
    /// the context packet is created. The first command to claim an identifier
    /// keeps it: a later command that touches the same input (a `ptt release`
    /// after its `ptt press`) must not rewrite who started it.
    private func learn(from record: PickyDebugTraceRecord) {
        guard let commandId = record.commandId else { return }
        if let inputId = record.inputId, commandIdByInputId[inputId] == nil {
            remember(key: inputId, commandId: commandId, in: &commandIdByInputId, order: &inputIdOrder)
        }
        if let contextId = record.contextId, commandIdByContextId[contextId] == nil {
            remember(key: contextId, commandId: commandId, in: &commandIdByContextId, order: &contextIdOrder)
        }
    }

    private func remember(
        key: String,
        commandId: String,
        in map: inout [String: String],
        order: inout [String]
    ) {
        if map[key] == nil { order.append(key) }
        map[key] = commandId
        while order.count > configuration.correlationCapacity {
            let evicted = order.removeFirst()
            map.removeValue(forKey: evicted)
        }
    }
}

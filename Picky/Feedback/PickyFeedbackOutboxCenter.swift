//
//  PickyFeedbackOutboxCenter.swift
//  Picky
//
//  App-owned delivery worker for the feedback outbox. The form hands a
//  submission over and closes; this object owns everything after that —
//  sequential delivery, failure states, retries, and resuming jobs that were
//  still queued when the app last quit.
//
//  The ordering rule everything else follows: the disk record is changed
//  *before* the action it describes. An attempt is marked in flight before a
//  byte can reach Slack, and a delivery is marked sent before its directory is
//  deleted. A crash between the two is then read conservatively — the job is
//  surfaced to the user instead of being replayed behind their back.
//

import Combine
import Foundation

/// The external boundary: everything that leaves the machine happens here.
protocol PickyFeedbackOutboxDelivering: Sendable {
    nonisolated func deliver(_ item: PickyFeedbackOutboxItem, attachmentDirectory: URL) async throws
}

/// Pure decisions about which queued jobs may move on their own.
enum PickyFeedbackOutboxPolicy {
    /// Jobs the worker may pick up without asking. Only `.pending` qualifies:
    /// an attempt that was already started may have reached Slack, so it waits
    /// for the user instead of being resent.
    static func resumable(_ items: [PickyFeedbackOutboxItem]) -> [PickyFeedbackOutboxItem] {
        items
            .filter { $0.state.isPending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// How a set of records read from disk is presented after a launch.
    struct Recovery: Equatable {
        /// Jobs to show and (where allowed) deliver.
        var visible: [PickyFeedbackOutboxItem] = []
        /// Jobs whose state was rewritten during recovery.
        var repairedIDs: Set<UUID> = []
        /// Finished jobs whose directory still needs deleting.
        var finished: [PickyFeedbackOutboxItem] = []
    }

    /// Reads persisted records the careful way. An attempt that was running
    /// when the process died becomes "unconfirmed", never "queued": Slack may
    /// have published it before the crash.
    static func recover(
        _ items: [PickyFeedbackOutboxItem],
        interruptedReason: String = L10n.t("feedback.outbox.interrupted.reason")
    ) -> Recovery {
        var recovery = Recovery()
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            if item.state.isTerminal {
                recovery.finished.append(item)
                continue
            }
            guard item.state.isInFlight else {
                recovery.visible.append(item)
                continue
            }
            var repaired = item
            repaired.state = .deliveryUncertain(reason: interruptedReason)
            recovery.visible.append(repaired)
            recovery.repairedIDs.insert(item.id)
        }
        return recovery
    }

    static func state(for error: Error) -> PickyFeedbackOutboxState {
        let reason = PickyFeedbackSendErrorDescription.userMessage(error)
        if error is PickyFeedbackDeliveryUncertainError {
            return .deliveryUncertain(reason: L10n.t("feedback.outbox.uncertain.reason"))
        }
        return .failed(reason: reason)
    }

    /// Whether retrying is known to be free of duplicate risk. Uncertain jobs
    /// can still be retried, but only through an explicit, informed action.
    static func retryIsDuplicateSafe(_ state: PickyFeedbackOutboxState) -> Bool {
        switch state {
        case .failed: return true
        case .storageBlocked(_, let duplicateRisk): return !duplicateRisk
        case .pending, .inFlight, .deliveryUncertain, .sent, .discarded: return false
        }
    }

    /// State to show when a change could not be persisted. The job keeps the
    /// duplicate risk it already carried, so a disk problem can never turn an
    /// unconfirmed publish into a "safe to resend" one.
    static func storageBlocked(after state: PickyFeedbackOutboxState, reason: String) -> PickyFeedbackOutboxState {
        .storageBlocked(reason: reason, duplicateRisk: state.hasDuplicateRisk || state.isInFlight)
    }
}

@MainActor
final class PickyFeedbackOutboxCenter: ObservableObject {
    static let shared = PickyFeedbackOutboxCenter()

    @Published private(set) var items: [PickyFeedbackOutboxItem] = []

    private let store: PickyFeedbackOutboxStore
    private let delivery: PickyFeedbackOutboxDelivering
    private var drainTask: Task<Void, Never>?
    /// Snapshots in progress, keyed by submission. A repeated Send for the
    /// same submission joins the running copy instead of starting a second.
    private var enqueueTasks: [UUID: Task<PickyFeedbackOutboxItem, Error>] = [:]

    init(
        store: PickyFeedbackOutboxStore = PickyFeedbackOutboxStore(),
        delivery: PickyFeedbackOutboxDelivering = PickyFeedbackSlackOutboxDelivery()
    ) {
        self.store = store
        self.delivery = delivery
    }

    /// Jobs that still need the user's attention: a failure to retry, or an
    /// attempt whose outcome Slack never confirmed.
    var needsAttentionCount: Int {
        items.filter { $0.state.needsAttention }.count
    }

    var hasQueuedWork: Bool { !items.isEmpty }

    /// Reads persisted jobs and starts delivering the ones that are safe to
    /// resume. Called once at launch.
    func resumePendingJobs() {
        let recovery = PickyFeedbackOutboxPolicy.recover(store.loadAll())
        items = recovery.visible

        // Private attachment copies from an enqueue that never finished. No
        // snapshot can be running yet at launch, so nothing in use is at risk.
        store.removeOrphanedStaging(activeIDs: Set(enqueueTasks.keys))

        for item in recovery.finished {
            removeDirectory(for: item)
        }
        // Re-labelling an interrupted attempt is a courtesy for the next
        // launch. If the write fails, recovery derives the same state again.
        for item in recovery.visible where recovery.repairedIDs.contains(item.id) {
            try? store.save(item)
        }
        scheduleDrain()
    }

    /// Persists the submission before returning. The caller may close the form
    /// only when this succeeds; a throw means nothing was stored and the draft
    /// must stay on screen.
    ///
    /// Copying attachments can mean hundreds of megabytes, so the whole
    /// snapshot runs off the main actor.
    @discardableResult
    func enqueue(_ draft: PickyFeedbackOutboxDraft) async throws -> PickyFeedbackOutboxItem {
        if let existing = items.first(where: { $0.id == draft.submissionID }) {
            return existing
        }
        if let running = enqueueTasks[draft.submissionID] {
            return try await running.value
        }

        let startedAt = Date()
        let store = self.store
        let task = Task.detached(priority: .userInitiated) {
            try store.enqueue(draft)
        }
        enqueueTasks[draft.submissionID] = task
        defer { enqueueTasks[draft.submissionID] = nil }

        do {
            let item = try await task.value
            PickyFeedbackStageLog.record(
                correlationID: item.id.uuidString,
                stage: "outbox.enqueue",
                startedAt: startedAt,
                byteCount: item.attachments.reduce(0) { $0 + $1.byteCount },
                outcome: .succeeded
            )
            guard !items.contains(where: { $0.id == item.id }) else { return item }
            items.append(item)
            items.sort { $0.createdAt < $1.createdAt }
            scheduleDrain()
            return item
        } catch {
            let code = (error as? PickyFeedbackOutboxError).map { outboxError -> String in
                switch outboxError {
                case .storageUnavailable: return "storage"
                case .attachmentSnapshotFailed: return "attachment"
                }
            } ?? "unknown"
            PickyFeedbackStageLog.record(
                correlationID: draft.submissionID.uuidString,
                stage: "outbox.enqueue",
                startedAt: startedAt,
                outcome: .failed(code)
            )
            throw error
        }
    }

    /// Puts a stopped job back in line. `acceptingDuplicateRisk` must be true
    /// for a job whose publish outcome is unknown; the call is ignored
    /// otherwise so an accidental tap cannot post the same feedback twice.
    func retry(id: UUID, acceptingDuplicateRisk: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let state = items[index].state
        guard !state.isPending, !state.isInFlight else { return }
        guard PickyFeedbackOutboxPolicy.retryIsDuplicateSafe(state) || acceptingDuplicateRisk else { return }

        var queued = items[index]
        queued.state = .pending
        do {
            try store.save(queued)
        } catch {
            // Queuing it only in memory would make the retry invisible to the
            // next launch; keep the job where the user can see it instead.
            markStorageFailure(at: index, error: error, stage: "outbox.retry")
            return
        }
        items[index] = queued
        scheduleDrain()
    }

    /// Removes a job at the user's request. A tombstone goes down first so a
    /// failed deletion cannot bring the job back and deliver it later.
    func discard(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var tombstoned = items[index]
        tombstoned.state = .discarded
        do {
            try store.save(tombstoned)
        } catch {
            markStorageFailure(at: index, error: error, stage: "outbox.discard")
            return
        }
        items.remove(at: index)
        removeDirectory(for: tombstoned)
    }

    /// Test seam: completes when no delivery is in flight.
    func waitForDeliveries() async {
        while let task = drainTask {
            await task.value
        }
    }

    // MARK: - Delivery loop

    private func scheduleDrain() {
        guard drainTask == nil else { return }
        guard !PickyFeedbackOutboxPolicy.resumable(items).isEmpty else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let next = PickyFeedbackOutboxPolicy.resumable(items).first {
            await attemptDelivery(of: next)
        }
        // Runs without suspending after the last loop check, so a job enqueued
        // from the main actor either is seen by the loop or schedules a new one.
        drainTask = nil
    }

    private func attemptDelivery(of item: PickyFeedbackOutboxItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var attempt = items[index]
        attempt.attemptCount += 1
        attempt.lastAttemptAt = Date()
        attempt.state = .inFlight

        // Nothing may be published until this marker is on disk. Without it a
        // crash mid-publish would come back as `.pending` and be resent.
        do {
            try store.save(attempt)
        } catch {
            markStorageFailure(at: index, error: error, stage: "outbox.markInFlight")
            return
        }
        items[index] = attempt

        let startedAt = Date()
        do {
            try await delivery.deliver(attempt, attachmentDirectory: store.directory(for: attempt.id))
            PickyFeedbackStageLog.record(
                correlationID: attempt.id.uuidString,
                stage: "outbox.deliver",
                startedAt: startedAt,
                outcome: .succeeded
            )
            finishDelivered(attempt)
        } catch {
            let state = PickyFeedbackOutboxPolicy.state(for: error)
            PickyFeedbackStageLog.record(
                correlationID: attempt.id.uuidString,
                stage: "outbox.deliver",
                startedAt: startedAt,
                outcome: .failed(state.isUncertain ? "unconfirmed" : "error")
            )
            NSLog("Picky feedback delivery failed: \(PickyFeedbackSendErrorDescription.technicalDescription(error))")
            guard let current = items.firstIndex(where: { $0.id == attempt.id }) else { return }
            var stopped = items[current]
            stopped.state = state
            items[current] = stopped
            do {
                try store.save(stopped)
            } catch {
                // The disk still says `.inFlight`, which recovery reads as
                // unconfirmed — never as something to resend.
                PickyFeedbackStageLog.record(
                    correlationID: attempt.id.uuidString,
                    stage: "outbox.persistFailure",
                    startedAt: Date(),
                    outcome: .failed("storage")
                )
            }
        }
    }

    /// Slack confirmed the message. The job is recorded as sent before its
    /// directory goes away, so a failed deletion cannot cause a second post.
    private func finishDelivered(_ item: PickyFeedbackOutboxItem) {
        var delivered = item
        delivered.state = .sent
        do {
            try store.save(delivered)
        } catch {
            // The record stays `.inFlight`, which recovery surfaces as
            // unconfirmed. Conservative: the user may resend, nothing does it
            // automatically.
            PickyFeedbackStageLog.record(
                correlationID: item.id.uuidString,
                stage: "outbox.markSent",
                startedAt: Date(),
                outcome: .failed("storage")
            )
        }
        items.removeAll { $0.id == item.id }
        removeDirectory(for: delivered)
    }

    private func removeDirectory(for item: PickyFeedbackOutboxItem) {
        do {
            try store.remove(item)
        } catch {
            // A terminal record is left behind; the next launch cleans it up
            // and never delivers it.
            PickyFeedbackStageLog.record(
                correlationID: item.id.uuidString,
                stage: "outbox.cleanup",
                startedAt: Date(),
                outcome: .failed("storage")
            )
        }
    }

    /// A state change that could not be persisted stops the job where the user
    /// can act on it, instead of letting delivery run on memory-only state.
    private func markStorageFailure(at index: Int, error: Error, stage: String) {
        PickyFeedbackStageLog.record(
            correlationID: items[index].id.uuidString,
            stage: stage,
            startedAt: Date(),
            outcome: .failed("storage")
        )
        NSLog("Picky feedback outbox storage failed: \(PickyFeedbackSendErrorDescription.technicalDescription(error))")
        items[index].state = PickyFeedbackOutboxPolicy.storageBlocked(
            after: items[index].state,
            reason: L10n.t("feedback.outbox.storageFailed")
        )
    }
}

/// Builds the diagnostics bundle, resolves the snapshotted attachments, and
/// posts to Slack. Runs off the main actor; every step is timed.
struct PickyFeedbackSlackOutboxDelivery: PickyFeedbackOutboxDelivering {
    var makeSender: @Sendable (String) -> PickyFeedbackSender = { correlationID in
        PickyFeedbackSender(correlationID: correlationID)
    }

    nonisolated func deliver(_ item: PickyFeedbackOutboxItem, attachmentDirectory: URL) async throws {
        let correlationID = item.id.uuidString
        let payload = item.payload
        var attachments: [PickyFeedbackAttachment] = []
        var diagnosticsCleanup: URL?
        defer {
            if let diagnosticsCleanup {
                try? FileManager.default.removeItem(at: diagnosticsCleanup)
            }
        }

        if let scope = item.diagnosticsScope {
            let startedAt = Date()
            do {
                let built = try await Self.buildBundleOffCooperativePool {
                    let metadata = PickyDiagnosticsBundleMetadata(
                        appVersion: payload.appVersion,
                        appBuild: payload.appBuild,
                        osVersion: payload.osVersion,
                        generatedAt: payload.sentAt
                    )
                    let bundle = try PickyDiagnosticsBundleBuilder.build(
                        scope: scope,
                        metadata: metadata,
                        oslogAnchor: payload.sentAt,
                        correlationID: correlationID
                    )
                    let readStartedAt = Date()
                    let data = try Data(contentsOf: bundle.zipURL)
                    PickyFeedbackStageLog.record(
                        correlationID: correlationID,
                        stage: "diagnostics.read",
                        startedAt: readStartedAt,
                        byteCount: data.count,
                        outcome: .succeeded
                    )
                    return (bundle, data)
                }
                diagnosticsCleanup = built.0.zipURL.deletingLastPathComponent()
                attachments.append(PickyFeedbackAttachment(
                    filename: built.0.filename,
                    data: built.1,
                    kind: .diagnostics
                ))
                PickyFeedbackStageLog.record(
                    correlationID: correlationID,
                    stage: "diagnostics.bundle",
                    startedAt: startedAt,
                    byteCount: built.1.count,
                    outcome: .succeeded
                )
            } catch {
                PickyFeedbackStageLog.record(
                    correlationID: correlationID,
                    stage: "diagnostics.bundle",
                    startedAt: startedAt,
                    outcome: .failed("build")
                )
                throw error
            }
        }

        for attachment in item.attachments {
            let url = attachmentDirectory.appendingPathComponent(attachment.relativePath)
            attachments.append(PickyFeedbackAttachment(
                filename: attachment.filename,
                fileURL: url,
                byteCount: attachment.byteCount,
                kind: .media
            ))
        }

        try await makeSender(correlationID).send(payload, attachments: attachments)
    }

    /// Escape hatch per docs/swift-concurrency.md. The bundle builder is
    /// synchronous and blocks: it waits on an OSLog semaphore for up to the
    /// collector's budget, then zips. Running it on the cooperative pool would
    /// park one of its few threads for seconds, so it gets a dedicated utility
    /// queue and the async caller waits on a continuation instead.
    private static let bundleQueue = DispatchQueue(
        label: "com.jonghakseo.picky.feedback-diagnostics",
        qos: .utility
    )

    private static func buildBundleOffCooperativePool(
        _ work: @escaping @Sendable () throws -> (PickyDiagnosticsBundle, Data)
    ) async throws -> (PickyDiagnosticsBundle, Data) {
        try await withCheckedThrowingContinuation { continuation in
            bundleQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

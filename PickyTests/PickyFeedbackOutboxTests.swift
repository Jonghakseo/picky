//
//  PickyFeedbackOutboxTests.swift
//  PickyTests
//
//  Behavior of the durable feedback outbox: what survives a restart, what the
//  worker is allowed to resend on its own, and when the form may close.
//

import Foundation
import Testing
@testable import Picky

@MainActor
private final class RecordingDelivery: PickyFeedbackOutboxDelivering {
    struct Attempt {
        var itemID: UUID
        var message: String
        var attachmentFilenames: [String]
        var attachmentContents: [String]
        /// What the on-disk record said at the moment delivery started. This
        /// is what a crash mid-publish would leave behind.
        var persistedState: PickyFeedbackOutboxState?
    }

    private(set) var attempts: [Attempt] = []
    /// Popped per attempt; an empty queue means "succeed".
    var outcomes: [Error?] = []
    /// Set to read back the persisted record while an attempt is running.
    var observedStore: PickyFeedbackOutboxStore?

    nonisolated func deliver(_ item: PickyFeedbackOutboxItem, attachmentDirectory: URL) async throws {
        let contents = item.attachments.map { attachment -> String in
            let url = attachmentDirectory.appendingPathComponent(attachment.relativePath)
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
        }
        let persistedState = await MainActor.run {
            observedStore?.loadAll().first { $0.id == item.id }?.state
        }
        try await MainActor.run {
            attempts.append(Attempt(
                itemID: item.id,
                message: item.message,
                attachmentFilenames: item.attachments.map(\.filename),
                attachmentContents: contents,
                persistedState: persistedState
            ))
            guard !outcomes.isEmpty, let error = outcomes.removeFirst() else { return }
            throw error
        }
    }
}

/// Records the order of main-actor work, to show that an await really gave
/// the actor up.
@MainActor
private final class MainActorOrderLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

/// Slack transport double. Not main-actor bound: the delivery adapter runs
/// off the main actor, like it does in the app.
private final class StubSlackTransport: PickyFeedbackTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestPaths: [String] = []
    private var _uploadedPayloads: [Data] = []

    var requestPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestPaths
    }

    var uploadedPayloads: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _uploadedPayloads
    }

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/unknown")
        let path = url.lastPathComponent
        lock.lock()
        _requestPaths.append(path)
        lock.unlock()
        let body: [String: Any] = path == "files.getUploadURLExternal"
            ? ["ok": true, "upload_url": "https://files.slack.com/upload/1", "file_id": "F1"]
            : ["ok": true]
        return (try JSONSerialization.data(withJSONObject: body), try Self.ok(url))
    }

    func upload(data: Data, to url: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        _uploadedPayloads.append(data)
        lock.unlock()
        return (Data(), try Self.ok(url))
    }

    private struct ResponseUnavailable: Error {}

    private static func ok(_ url: URL) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw ResponseUnavailable()
        }
        return response
    }
}

@MainActor
@Suite
struct PickyFeedbackOutboxTests {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-outbox-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDraft(
        submissionID: UUID = UUID(),
        message: String = "Pickle hangs on send.",
        attachmentSources: [URL] = [],
        diagnosticsScope: PickyDiagnosticsBundleScope? = nil
    ) -> PickyFeedbackOutboxDraft {
        PickyFeedbackOutboxDraft(
            submissionID: submissionID,
            category: .bug,
            message: message,
            appVersion: "0.14.0",
            appBuild: "1936",
            osVersion: "26.5.2",
            requestedAt: Date(timeIntervalSince1970: 1_800_000_000),
            diagnosticsScope: diagnosticsScope,
            attachmentSources: attachmentSources
        )
    }

    private func writeTemporaryFile(named name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-outbox-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fileURL = url.appendingPathComponent(name)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Durability

    /// The form closes on Send, so everything needed to deliver later has to
    /// be on disk before `enqueue` returns.
    @Test func enqueuePersistsSubmissionBeforeReturning() throws {
        let root = makeRoot()
        let store = PickyFeedbackOutboxStore(root: root)

        let item = try store.enqueue(makeDraft(message: "Spinner never stops."))

        let reread = PickyFeedbackOutboxStore(root: root).loadAll()
        #expect(reread.count == 1)
        #expect(reread.first?.id == item.id)
        #expect(reread.first?.message == "Spinner never stops.")
        #expect(reread.first?.state == .pending)
        #expect(reread.first?.requestedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// A retry hours later must still upload what the user picked, even if the
    /// original file was moved, renamed, or deleted in the meantime.
    @Test func attachmentSnapshotSurvivesOriginalFileDeletion() async throws {
        let root = makeRoot()
        let source = try writeTemporaryFile(named: "screen recording.mov", contents: "original-bytes")
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackSendError.transport("offline")]
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        let item = try await center.enqueue(makeDraft(attachmentSources: [source]))
        await center.waitForDeliveries()
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())

        center.retry(id: item.id)
        await center.waitForDeliveries()

        #expect(delivery.attempts.count == 2)
        #expect(delivery.attempts.last?.attachmentFilenames == ["screen recording.mov"])
        #expect(delivery.attempts.last?.attachmentContents == ["original-bytes"])
    }

    /// If the submission cannot be stored, the user must keep their draft: the
    /// enqueue has to fail loudly instead of silently dropping it.
    @Test func enqueueFailsWhenStorageIsUnavailable() throws {
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-outbox-blocked-\(UUID().uuidString)")
        // A regular file where the outbox directory should be makes every
        // write underneath it fail.
        try Data("not a directory".utf8).write(to: blocked)
        let store = PickyFeedbackOutboxStore(root: blocked.appendingPathComponent("Outbox", isDirectory: true))

        #expect(throws: PickyFeedbackOutboxError.self) {
            try store.enqueue(self.makeDraft())
        }
        #expect(store.loadAll().isEmpty)
    }

    // MARK: - Delivery lifecycle

    @Test func confirmedSuccessRemovesTheQueuedSubmission() async throws {
        let root = makeRoot()
        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        try await center.enqueue(makeDraft())
        await center.waitForDeliveries()

        #expect(delivery.attempts.count == 1)
        #expect(center.items.isEmpty)
        #expect(PickyFeedbackOutboxStore(root: root).loadAll().isEmpty)
    }

    @Test func failedSubmissionStaysRetriableAndKeepsItsContent() async throws {
        let root = makeRoot()
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackSendError.transport("offline")]
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        try await center.enqueue(makeDraft(message: "Dock lags after wake."))
        await center.waitForDeliveries()

        #expect(center.items.count == 1)
        #expect(center.items[0].state.isPending == false)
        #expect(center.items[0].state.isUncertain == false)
        #expect(center.needsAttentionCount == 1)

        center.retry(id: center.items[0].id)
        await center.waitForDeliveries()

        #expect(delivery.attempts.map(\.message) == ["Dock lags after wake.", "Dock lags after wake."])
        #expect(center.items.isEmpty)
    }

    /// A publish request that never got an answer may already be in Slack.
    /// Nothing may resend it without the user saying so.
    @Test func unconfirmedDeliveryIsNeverResentAutomatically() async throws {
        let root = makeRoot()
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackDeliveryUncertainError(underlying: .transport("timed out"))]
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        let item = try await center.enqueue(makeDraft())
        await center.waitForDeliveries()
        #expect(center.items.first?.state.isUncertain == true)

        // Neither a plain retry nor a restart may publish a second copy.
        center.retry(id: item.id)
        await center.waitForDeliveries()
        center.resumePendingJobs()
        await center.waitForDeliveries()
        #expect(delivery.attempts.count == 1)

        let restarted = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )
        restarted.resumePendingJobs()
        await restarted.waitForDeliveries()
        #expect(delivery.attempts.count == 1)
        #expect(restarted.items.first?.state.isUncertain == true)

        // Explicitly accepting the duplicate risk does send it again.
        restarted.retry(id: item.id, acceptingDuplicateRisk: true)
        await restarted.waitForDeliveries()
        #expect(delivery.attempts.count == 2)
    }

    @Test func restartResumesQueuedSubmissions() async throws {
        let root = makeRoot()
        try PickyFeedbackOutboxStore(root: root).enqueue(makeDraft(message: "Queued before quit."))

        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )
        center.resumePendingJobs()
        await center.waitForDeliveries()

        #expect(delivery.attempts.map(\.message) == ["Queued before quit."])
        #expect(center.items.isEmpty)
    }

    @Test func submissionsAreDeliveredOneAtATimeInSubmissionOrder() async throws {
        let root = makeRoot()
        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        try await center.enqueue(makeDraft(message: "first"))
        try await center.enqueue(makeDraft(message: "second"))
        try await center.enqueue(makeDraft(message: "third"))
        await center.waitForDeliveries()

        #expect(delivery.attempts.map(\.message) == ["first", "second", "third"])
    }

    @Test func discardRemovesTheSubmissionAndItsStoredAttachments() async throws {
        let root = makeRoot()
        let source = try writeTemporaryFile(named: "log.txt", contents: "x")
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackSendError.slackError("invalid_auth")]
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        let item = try await center.enqueue(makeDraft(attachmentSources: [source]))
        await center.waitForDeliveries()
        let directory = PickyFeedbackOutboxStore(root: root).directory(for: item.id)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        center.discard(id: item.id)

        #expect(center.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// End-to-end through the production delivery adapter: the bytes Slack
    /// receives come from the outbox snapshot, not the original file.
    @Test func productionDeliveryUploadsTheSnapshottedAttachment() async throws {
        let root = makeRoot()
        let source = try writeTemporaryFile(named: "evidence.png", contents: "snapshot-bytes")
        let transport = StubSlackTransport()
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: PickyFeedbackSlackOutboxDelivery(makeSender: { correlationID in
                PickyFeedbackSender(
                    botToken: "xoxb-test",
                    channelID: "C1",
                    transport: transport,
                    correlationID: correlationID
                )
            })
        )

        try await center.enqueue(makeDraft(attachmentSources: [source]))
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        await center.waitForDeliveries()

        #expect(transport.requestPaths == [
            "files.getUploadURLExternal",
            "files.completeUploadExternal"
        ])
        #expect(transport.uploadedPayloads.map { String(decoding: $0, as: UTF8.self) } == ["snapshot-bytes"])
        #expect(center.items.isEmpty)
    }

    // MARK: - Crash safety

    /// A crash mid-publish must look like "we already tried this" on disk, not
    /// like "never started". Whatever the record says while the request is in
    /// the air is exactly what the next launch will read.
    @Test func theAttemptIsRecordedOnDiskBeforeAnythingCanReachSlack() async throws {
        let root = makeRoot()
        let delivery = RecordingDelivery()
        delivery.observedStore = PickyFeedbackOutboxStore(root: root)
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        try await center.enqueue(makeDraft())
        await center.waitForDeliveries()

        #expect(delivery.attempts.count == 1)
        #expect(delivery.attempts.first?.persistedState == .inFlight)
    }

    /// Picky quit while a publish request was in the air. Slack may already
    /// have the message, so the next launch must surface it instead of
    /// quietly sending a second copy.
    @Test func anAttemptInterruptedByAQuitIsNeverReplayed() async throws {
        let root = makeRoot()
        let store = PickyFeedbackOutboxStore(root: root)
        var interrupted = try store.enqueue(makeDraft(message: "Sent right before the crash."))
        interrupted.state = .inFlight
        interrupted.attemptCount = 1
        try store.save(interrupted)

        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(store: store, delivery: delivery)
        center.resumePendingJobs()
        await center.waitForDeliveries()

        #expect(delivery.attempts.isEmpty)
        #expect(center.items.count == 1)
        #expect(center.items.first?.state.isUncertain == true)
        #expect(center.needsAttentionCount == 1)
        // The repaired state is persisted, so a second launch reads the same
        // thing rather than re-deriving it from a stale marker.
        #expect(store.loadAll().first?.state.isUncertain == true)

        // A plain retry still refuses; only an informed one sends.
        center.retry(id: interrupted.id)
        await center.waitForDeliveries()
        #expect(delivery.attempts.isEmpty)

        center.retry(id: interrupted.id, acceptingDuplicateRisk: true)
        await center.waitForDeliveries()
        #expect(delivery.attempts.count == 1)
    }

    /// If the "an attempt is starting" marker cannot be written, delivery must
    /// not happen at all: a crash would otherwise replay it from `.pending`.
    @Test func deliveryIsSkippedWhenTheAttemptCannotBeRecorded() async throws {
        let root = makeRoot()
        let store = PickyFeedbackOutboxStore(root: root)
        let item = try store.enqueue(makeDraft(message: "Disk went read-only."))
        let jobDirectory = store.directory(for: item.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: jobDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jobDirectory.path)
        }

        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(store: store, delivery: delivery)
        center.resumePendingJobs()
        await center.waitForDeliveries()

        #expect(delivery.attempts.isEmpty)
        #expect(center.items.count == 1)
        #expect(center.items.first?.state.needsAttention == true)
        #expect(center.items.first?.state.reason?.isEmpty == false)
        // Nothing was published, so retrying this one is still duplicate-safe.
        #expect(center.items.first?.state.hasDuplicateRisk == false)
        // The submission itself is untouched, so the user can retry it later.
        #expect(store.loadAll().first?.message == "Disk went read-only.")
    }

    /// A disk problem must not launder an unconfirmed publish into a
    /// "safe to retry" failure: the duplicate risk has to survive it.
    @Test func aStorageErrorKeepsTheDuplicateRiskOfAnUnconfirmedSubmission() async throws {
        let root = makeRoot()
        let store = PickyFeedbackOutboxStore(root: root)
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackDeliveryUncertainError(underlying: .transport("timed out"))]
        let center = PickyFeedbackOutboxCenter(store: store, delivery: delivery)

        let item = try await center.enqueue(makeDraft(message: "Maybe already in Slack."))
        await center.waitForDeliveries()
        #expect(center.items.first?.state.isUncertain == true)

        // The job directory turns read-only, so re-queuing cannot be written.
        let jobDirectory = store.directory(for: item.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: jobDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jobDirectory.path)
        }

        center.retry(id: item.id, acceptingDuplicateRisk: true)
        await center.waitForDeliveries()

        #expect(delivery.attempts.count == 1)
        #expect(center.items.first?.state.needsAttention == true)
        #expect(center.items.first?.state.hasDuplicateRisk == true)
        // A plain retry afterwards is still refused, exactly as before.
        center.retry(id: item.id)
        await center.waitForDeliveries()
        #expect(delivery.attempts.count == 1)
    }

    /// Slack confirmed the message but the job directory could not be deleted.
    /// The leftover record must never turn into a second post.
    @Test func aDeliveredSubmissionIsNotResentWhenCleanupFails() async throws {
        let root = makeRoot()
        let store = PickyFeedbackOutboxStore(root: root)
        try store.enqueue(makeDraft(message: "Delivered once."))
        // Read-only parent: the record inside the job directory can still be
        // rewritten, but the directory itself cannot be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            }
        }

        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(store: store, delivery: delivery)
        center.resumePendingJobs()
        await center.waitForDeliveries()

        #expect(delivery.attempts.count == 1)
        #expect(center.items.isEmpty)
        // The tombstone survives the failed deletion: a partial delete must
        // not take `job.json` with it and leave an unexplained directory.
        #expect(store.loadAll().first?.state == .sent)

        let restarted = PickyFeedbackOutboxCenter(store: store, delivery: delivery)
        restarted.resumePendingJobs()
        await restarted.waitForDeliveries()

        #expect(delivery.attempts.count == 1)
        #expect(restarted.items.isEmpty)

        // Once the directory is writable again, the leftover is cleaned up.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        restored = true
        let afterRepair = PickyFeedbackOutboxCenter(store: store, delivery: delivery)
        afterRepair.resumePendingJobs()
        await afterRepair.waitForDeliveries()

        #expect(delivery.attempts.count == 1)
        #expect(store.loadAll().isEmpty)
    }

    /// One press of Send is one job, even if the button is hit twice before
    /// the snapshot finishes.
    @Test func repeatingTheSameSubmissionQueuesOneJob() async throws {
        let root = makeRoot()
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackSendError.transport("offline")]
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )
        let draft = makeDraft(message: "Double-tapped Send.")

        async let first = center.enqueue(draft)
        async let second = center.enqueue(draft)
        let queued = try await [first, second]
        await center.waitForDeliveries()

        #expect(queued[0].id == queued[1].id)
        #expect(center.items.count == 1)
        #expect(delivery.attempts.count == 1)
        #expect(PickyFeedbackOutboxStore(root: root).loadAll().count == 1)
    }

    /// Snapshotting attachments can be hundreds of megabytes. The main actor
    /// has to stay free while it happens, or the HUD freezes on Send.
    @Test func enqueueLeavesTheMainActorFreeWhileCopyingAttachments() async throws {
        let root = makeRoot()
        let source = try writeTemporaryFile(
            named: "recording.mov",
            contents: String(repeating: "x", count: 2 * 1_024 * 1_024)
        )
        let delivery = RecordingDelivery()
        delivery.outcomes = [PickyFeedbackSendError.transport("offline")]
        let center = PickyFeedbackOutboxCenter(
            store: PickyFeedbackOutboxStore(root: root),
            delivery: delivery
        )

        // Queued on the main actor before the copy starts. It can only run if
        // `enqueue` gives the main actor up while the bytes are written.
        let order = MainActorOrderLog()
        Task { @MainActor in order.append("other main-actor work") }

        try await center.enqueue(makeDraft(attachmentSources: [source]))
        order.append("enqueue returned")
        await center.waitForDeliveries()

        #expect(order.events == ["other main-actor work", "enqueue returned"])
    }

    // MARK: - Policy

    @Test func interruptedAttemptsRecoverAsUnconfirmedAndFinishedOnesAreCleanedUp() {
        let template = PickyFeedbackOutboxItem(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            requestedAt: Date(timeIntervalSince1970: 10),
            category: .bug,
            message: "m",
            appVersion: "1",
            appBuild: "1",
            osVersion: "1",
            diagnosticsScope: nil,
            attachments: [],
            state: .inFlight,
            attemptCount: 1,
            lastAttemptAt: nil
        )
        var sent = template
        sent.id = UUID()
        sent.state = .sent
        var discarded = template
        discarded.id = UUID()
        discarded.state = .discarded
        var queued = template
        queued.id = UUID()
        queued.state = .pending

        let recovery = PickyFeedbackOutboxPolicy.recover(
            [template, sent, discarded, queued],
            interruptedReason: "interrupted"
        )

        #expect(recovery.visible.map(\.id) == [template.id, queued.id])
        #expect(recovery.visible.first?.state == .deliveryUncertain(reason: "interrupted"))
        #expect(recovery.repairedIDs == [template.id])
        #expect(Set(recovery.finished.map(\.id)) == [sent.id, discarded.id])
        #expect(PickyFeedbackOutboxPolicy.resumable(recovery.visible).map(\.id) == [queued.id])
    }

    @Test func onlyPendingSubmissionsAreResumable() {
        let base = PickyFeedbackOutboxItem(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            requestedAt: Date(timeIntervalSince1970: 100),
            category: .bug,
            message: "m",
            appVersion: "1",
            appBuild: "1",
            osVersion: "1",
            diagnosticsScope: nil,
            attachments: [],
            state: .pending,
            attemptCount: 0,
            lastAttemptAt: nil
        )
        var failed = base
        failed.id = UUID()
        failed.createdAt = Date(timeIntervalSince1970: 50)
        failed.state = .failed(reason: "nope")
        var uncertain = base
        uncertain.id = UUID()
        uncertain.createdAt = Date(timeIntervalSince1970: 10)
        uncertain.state = .deliveryUncertain(reason: "unknown")

        let resumable = PickyFeedbackOutboxPolicy.resumable([uncertain, failed, base])

        #expect(resumable.map(\.id) == [base.id])
    }

    /// Stage lines are the evidence the next "stuck on sending" report will
    /// carry, so they must stay scalar: no message text, tokens, or paths.
    @Test func stageLogLineCarriesTimingWithoutContent() {
        let line = PickyFeedbackStageLog.renderLine(
            correlationID: "7F1B",
            stage: "diagnostics.bundle",
            elapsedMs: 31_402,
            byteCount: 1_048_576,
            outcome: .failed("transport /Users/someone/Secret.mov xoxb-token")
        )

        #expect(line.contains("stage=diagnostics.bundle"))
        #expect(line.contains("job=7F1B"))
        #expect(line.contains("elapsedMs=31402"))
        #expect(line.contains("bytes=1048576"))
        #expect(!line.contains("/Users/"))
        #expect(!line.contains("Secret.mov"))
        #expect(!line.contains("xoxb"))
    }

    /// Attachments copied for a submission that never finished enqueuing are
    /// private user files. They must not survive the next launch.
    @Test func orphanedAttachmentSnapshotsAreRemovedAtLaunch() async throws {
        let root = makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("private bytes".utf8).write(to: orphan.appendingPathComponent("0-secret.mov"))

        let store = PickyFeedbackOutboxStore(root: root)
        try store.enqueue(makeDraft(message: "Still queued."))

        let delivery = RecordingDelivery()
        let center = PickyFeedbackOutboxCenter(store: store, delivery: delivery)
        center.resumePendingJobs()
        await center.waitForDeliveries()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(delivery.attempts.map(\.message) == ["Still queued."])
    }

    @Test func publishFailuresWithoutAnAnswerAreClassifiedAsUncertain() {
        let uncertain = PickyFeedbackOutboxPolicy.state(
            for: PickyFeedbackDeliveryUncertainError(underlying: .transport("timed out"))
        )
        let failed = PickyFeedbackOutboxPolicy.state(for: PickyFeedbackSendError.slackError("invalid_auth"))

        #expect(uncertain.isUncertain)
        #expect(!PickyFeedbackOutboxPolicy.retryIsDuplicateSafe(uncertain))
        #expect(!failed.isUncertain)
        #expect(PickyFeedbackOutboxPolicy.retryIsDuplicateSafe(failed))
    }
}

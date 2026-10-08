//
//  PickyFeedbackOutboxStore.swift
//  Picky
//
//  Durable storage for feedback the user already pressed Send on. The form
//  closes as soon as a submission lands here, so everything the delivery
//  worker needs — message, category, metadata, and a private copy of each
//  attached file — has to survive app restarts and the original files moving
//  or being deleted.
//
//  Layout under Application Support:
//    Feedback/Outbox/<job-id>/job.json
//    Feedback/Outbox/<job-id>/attachments/<index>-<filename>
//

import Foundation

/// What the user confirmed, before anything is uploaded.
struct PickyFeedbackOutboxDraft: Sendable {
    /// Identity of this submission, decided before the snapshot starts. It
    /// becomes the job id, so repeating the same submission writes the same
    /// record instead of queueing a second copy of one press of Send.
    var submissionID: UUID = UUID()
    var category: PickyFeedbackCategory
    var message: String
    var appVersion: String
    var appBuild: String
    var osVersion: String
    /// When the user pressed Send. Diagnostics anchor their log window here so
    /// a queued job still reports the moment the problem was observed.
    var requestedAt: Date
    var diagnosticsScope: PickyDiagnosticsBundleScope?
    var attachmentSources: [URL]
}

struct PickyFeedbackOutboxAttachment: Codable, Equatable, Sendable {
    var filename: String
    /// Path relative to the job directory, so the record stays valid if the
    /// Application Support tree is moved.
    var relativePath: String
    var byteCount: Int
}

/// Delivery state of one queued submission.
enum PickyFeedbackOutboxState: Codable, Equatable, Sendable {
    /// Queued, with no attempt started. The only state the worker may pick up
    /// on its own.
    case pending
    /// An attempt is running right now. Written to disk *before* anything can
    /// reach Slack, so a crash mid-publish is never mistaken for "never
    /// tried" on the next launch.
    case inFlight
    /// The attempt stopped before Slack could have published anything.
    /// Retrying cannot duplicate the message.
    case failed(reason: String)
    /// The publish request was sent but its outcome is unknown. Retrying may
    /// post the message twice, so this never auto-resumes.
    case deliveryUncertain(reason: String)
    /// A state change could not be written to disk, so the job was stopped
    /// where the user can see it. `duplicateRisk` carries over whatever risk
    /// the job already had: a storage error must never make an unconfirmed
    /// publish look safe to resend.
    case storageBlocked(reason: String, duplicateRisk: Bool)
    /// Slack confirmed the message. Written before the job directory is
    /// deleted, so a cleanup that fails cannot resurrect a delivered job.
    case sent
    /// The user removed the job. Written before deletion for the same reason.
    case discarded

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    var isInFlight: Bool {
        if case .inFlight = self { return true }
        return false
    }

    var isUncertain: Bool {
        if case .deliveryUncertain = self { return true }
        return false
    }

    /// Sending this again might post the same feedback twice.
    var hasDuplicateRisk: Bool {
        switch self {
        case .deliveryUncertain: return true
        case .storageBlocked(_, let duplicateRisk): return duplicateRisk
        case .pending, .inFlight, .failed, .sent, .discarded: return false
        }
    }

    /// Finished for good. Nothing may be delivered, and the record exists only
    /// until its directory is cleaned up.
    var isTerminal: Bool {
        switch self {
        case .sent, .discarded: return true
        case .pending, .inFlight, .failed, .deliveryUncertain, .storageBlocked: return false
        }
    }

    /// Stopped in a way only the user can resolve.
    var needsAttention: Bool {
        switch self {
        case .failed, .deliveryUncertain, .storageBlocked: return true
        case .pending, .inFlight, .sent, .discarded: return false
        }
    }

    var reason: String? {
        switch self {
        case .pending, .inFlight, .sent, .discarded: return nil
        case .failed(let reason), .deliveryUncertain(let reason), .storageBlocked(let reason, _): return reason
        }
    }
}

struct PickyFeedbackOutboxItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var createdAt: Date
    var requestedAt: Date
    var category: PickyFeedbackCategory
    var message: String
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var diagnosticsScope: PickyDiagnosticsBundleScope?
    var attachments: [PickyFeedbackOutboxAttachment]
    var state: PickyFeedbackOutboxState
    var attemptCount: Int
    var lastAttemptAt: Date?

    var payload: PickyFeedbackPayload {
        PickyFeedbackPayload(
            category: category,
            message: message,
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: osVersion,
            sentAt: requestedAt
        )
    }
}

enum PickyFeedbackOutboxError: LocalizedError, Equatable {
    case storageUnavailable(String)
    case attachmentSnapshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable, .attachmentSnapshotFailed:
            return L10n.t("feedback.outbox.enqueueFailed")
        }
    }

    /// Developer-facing detail; kept out of the user-visible string.
    var technicalDescription: String {
        switch self {
        case .storageUnavailable(let detail): return "outbox storage unavailable: \(detail)"
        case .attachmentSnapshotFailed(let detail): return "attachment snapshot failed: \(detail)"
        }
    }
}

/// File-backed outbox. Every mutation is a whole-record write so a crash
/// mid-write cannot leave a half-parsed job behind.
struct PickyFeedbackOutboxStore: Sendable {
    let root: URL

    init(root: URL = PickyFeedbackOutboxStore.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot(appSupportRoot: URL = PickyAppSupport.defaultRoot()) -> URL {
        appSupportRoot
            .appendingPathComponent("Feedback", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    // MARK: - Reading

    func loadAll() -> [PickyFeedbackOutboxItem] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children
            .compactMap { directory -> PickyFeedbackOutboxItem? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.recordName)) else {
                    return nil
                }
                return try? Self.decoder.decode(PickyFeedbackOutboxItem.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func attachmentURL(for attachment: PickyFeedbackOutboxAttachment, itemID: UUID) -> URL {
        directory(for: itemID).appendingPathComponent(attachment.relativePath)
    }

    // MARK: - Writing

    /// Copies every attachment and writes the record into a staging directory,
    /// then moves it into place with a single rename. The job becomes visible
    /// only once all of its bytes are already on disk.
    @discardableResult
    func enqueue(_ draft: PickyFeedbackOutboxDraft) throws -> PickyFeedbackOutboxItem {
        let id = draft.submissionID
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw PickyFeedbackOutboxError.storageUnavailable(error.localizedDescription)
        }

        let staging = root.appendingPathComponent(Self.stagingName(for: id), isDirectory: true)
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw PickyFeedbackOutboxError.storageUnavailable(error.localizedDescription)
        }

        do {
            let attachments = try snapshotAttachments(draft.attachmentSources, into: staging)
            let item = PickyFeedbackOutboxItem(
                id: id,
                createdAt: Date(),
                requestedAt: draft.requestedAt,
                category: draft.category,
                message: draft.message,
                appVersion: draft.appVersion,
                appBuild: draft.appBuild,
                osVersion: draft.osVersion,
                diagnosticsScope: draft.diagnosticsScope,
                attachments: attachments,
                state: .pending,
                attemptCount: 0,
                lastAttemptAt: nil
            )
            let data = try Self.encoder.encode(item)
            try data.write(to: staging.appendingPathComponent(Self.recordName), options: .atomic)

            let destination = directory(for: id)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return item
        } catch let error as PickyFeedbackOutboxError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw PickyFeedbackOutboxError.storageUnavailable(error.localizedDescription)
        }
    }

    /// Rewrites a job record. Throws instead of reporting success on a failed
    /// write: callers use a successful save as proof that the state change
    /// — "an attempt is running", "this was delivered" — will survive a crash,
    /// and must not proceed when it is only in memory.
    func save(_ item: PickyFeedbackOutboxItem) throws {
        let directory = directory(for: item.id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw PickyFeedbackOutboxError.storageUnavailable("job directory is missing")
        }
        do {
            let data = try Self.encoder.encode(item)
            try data.write(to: directory.appendingPathComponent(Self.recordName), options: .atomic)
        } catch {
            throw PickyFeedbackOutboxError.storageUnavailable(error.localizedDescription)
        }
    }

    /// Deletes a finished job's directory. Throws so a failed cleanup is
    /// visible; the record it leaves behind must already be a terminal one.
    ///
    /// `removeItem` deletes children first, so a parent directory that refuses
    /// the final unlink can leave the job directory in place *without*
    /// `job.json`. That would erase the "already delivered" tombstone and turn
    /// a leftover into an unexplained empty directory, so the record is put
    /// back before the failure is reported.
    func remove(_ item: PickyFeedbackOutboxItem) throws {
        let directory = directory(for: item.id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            restoreRecordIfMissing(item, in: directory)
            throw PickyFeedbackOutboxError.storageUnavailable(error.localizedDescription)
        }
    }

    /// Deletes staging directories left behind by an enqueue that never
    /// finished — a crash or a quit mid-copy. They hold private copies of the
    /// user's attachments, so they must not sit around forever.
    ///
    /// `activeIDs` are submissions being copied right now; their staging
    /// directories are in use and are left alone.
    func removeOrphanedStaging(activeIDs: Set<UUID> = []) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        let activeNames = Set(activeIDs.map { Self.stagingName(for: $0) })
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(Self.stagingPrefix), !activeNames.contains(name) else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    private func restoreRecordIfMissing(_ item: PickyFeedbackOutboxItem, in directory: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let record = directory.appendingPathComponent(Self.recordName)
        guard !fileManager.fileExists(atPath: record.path) else { return }
        guard let data = try? Self.encoder.encode(item) else { return }
        try? data.write(to: record, options: .atomic)
    }

    // MARK: - Internals

    private func snapshotAttachments(_ sources: [URL], into staging: URL) throws -> [PickyFeedbackOutboxAttachment] {
        guard !sources.isEmpty else { return [] }
        let fileManager = FileManager.default
        let attachmentsDirectory = staging.appendingPathComponent("attachments", isDirectory: true)
        do {
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        } catch {
            throw PickyFeedbackOutboxError.storageUnavailable(error.localizedDescription)
        }

        var attachments: [PickyFeedbackOutboxAttachment] = []
        for (index, source) in sources.enumerated() {
            let filename = source.lastPathComponent
            let storedName = "\(index)-\(Self.sanitized(filename))"
            let destination = attachmentsDirectory.appendingPathComponent(storedName)
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw PickyFeedbackOutboxError.attachmentSnapshotFailed("\(filename): \(error.localizedDescription)")
            }
            let byteCount = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            attachments.append(PickyFeedbackOutboxAttachment(
                filename: filename,
                relativePath: "attachments/\(storedName)",
                byteCount: byteCount
            ))
        }
        return attachments
    }

    private static func sanitized(_ filename: String) -> String {
        let allowed = filename.map { character -> Character in
            character == "/" || character == ":" ? "_" : character
        }
        let name = String(allowed)
        return name.isEmpty ? "attachment" : name
    }

    private static let recordName = "job.json"
    private static let stagingPrefix = ".staging-"

    private static func stagingName(for id: UUID) -> String {
        "\(stagingPrefix)\(id.uuidString)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

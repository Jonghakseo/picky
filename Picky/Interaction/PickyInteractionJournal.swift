import Foundation

struct PickyInteractionJournalRecord: Equatable, Codable, Identifiable {
    enum Kind: String, Equatable, Codable {
        case accepted
        case stateChanged
        case staleEvent
        case ignored
        case warning
    }

    let id: UUID
    let sequence: UInt64?
    let envelopeID: UUID
    let occurredAt: Date
    let event: PickyInteractionEvent
    let kind: Kind
    let message: String

    init(
        id: UUID,
        sequence: UInt64? = nil,
        envelopeID: UUID,
        occurredAt: Date,
        event: PickyInteractionEvent,
        kind: Kind,
        message: String
    ) {
        self.id = id
        self.sequence = sequence
        self.envelopeID = envelopeID
        self.occurredAt = occurredAt
        self.event = event
        self.kind = kind
        self.message = message
    }

    func withSequence(_ sequence: UInt64) -> Self {
        Self(
            id: id,
            sequence: sequence,
            envelopeID: envelopeID,
            occurredAt: occurredAt,
            event: event,
            kind: kind,
            message: message
        )
    }
}

actor PickyInteractionJournal {
    private let limit: Int
    private let fileURL: URL?
    private var records: [PickyInteractionJournalRecord] = []

    init(limit: Int = 500, fileURL: URL? = nil) {
        self.limit = max(1, limit)
        self.fileURL = fileURL
    }

    func append(_ newRecords: [PickyInteractionJournalRecord]) async {
        guard !newRecords.isEmpty else { return }
        records.append(contentsOf: newRecords)
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
    }

    func recent(limit requestedLimit: Int) async -> [PickyInteractionJournalRecord] {
        let boundedLimit = max(0, requestedLimit)
        guard boundedLimit < records.count else { return records }
        return Array(records.suffix(boundedLimit))
    }

    func exportJSONL() async throws -> URL {
        let destination = try resolvedFileURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sortedRecords = records.sorted { lhs, rhs in
            switch (lhs.sequence, rhs.sequence) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.occurredAt < rhs.occurredAt
            }
        }
        let lines = try sortedRecords.map { record in
            String(decoding: try encoder.encode(record), as: UTF8.self)
        }.joined(separator: "\n")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.appending(lines.isEmpty ? "" : "\n").write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURL { return fileURL }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Picky", isDirectory: true)
            .appendingPathComponent("interaction-events.jsonl")
    }
}

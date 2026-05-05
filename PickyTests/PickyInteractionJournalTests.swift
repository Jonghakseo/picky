import Foundation
import Testing
@testable import Picky

struct PickyInteractionJournalTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func journalKeepsRecentRecordsWithinLimit() async {
        let journal = PickyInteractionJournal(limit: 2)
        let records = [record(sequence: 1), record(sequence: 2), record(sequence: 3)]

        await journal.append(records)
        let recent = await journal.recent(limit: 10)

        #expect(recent.map(\.sequence) == [2, 3])
    }

    @Test func journalExportWritesJsonlSortedBySequence() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-interaction-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("events.jsonl")
        let journal = PickyInteractionJournal(limit: 10, fileURL: fileURL)
        await journal.append([record(sequence: 2), record(sequence: 1)])

        let exportedURL = try await journal.exportJSONL()
        let contents = try String(contentsOf: exportedURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")

        #expect(exportedURL == fileURL)
        #expect(lines.count == 2)
        #expect(lines[0].contains(#""sequence":1"#))
        #expect(lines[1].contains(#""sequence":2"#))
    }

    private func record(sequence: UInt64) -> PickyInteractionJournalRecord {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llu", sequence))!
        return PickyInteractionJournalRecord(
            id: id,
            sequence: sequence,
            envelopeID: id,
            occurredAt: baseDate.addingTimeInterval(TimeInterval(sequence)),
            event: .appStarted,
            kind: .accepted,
            message: "record \(sequence)"
        )
    }
}

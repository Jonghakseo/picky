//
//  PickyIPSCollectorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyIPSCollectorTests {
    @Test func collectorSelectsTwoNewestRecentPickyReportsAndRedactsBoundedExcerpts() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeReport(named: "Picky-newest.ips", modifiedAt: now.addingTimeInterval(-10), in: root, bytes: 260 * 1024)
        try writeReport(named: "Picky-second.ips", modifiedAt: now.addingTimeInterval(-20), in: root, bytes: 260 * 1024)
        try writeReport(named: "Picky-third.ips", modifiedAt: now.addingTimeInterval(-30), in: root, bytes: 260 * 1024)
        try writeReport(named: "Picky-old.ips", modifiedAt: now.addingTimeInterval(-PickyIPSCollector.maximumAge - 1), in: root, bytes: 100)
        try writeReport(named: "OtherProcess.ips", modifiedAt: now.addingTimeInterval(-5), in: root, bytes: 100)

        let result = PickyIPSCollector.collect(reportsRoot: root, now: now)
        let entries = try decodeManifest(result.manifestText)

        let everyExcerptFitsPerFileCap = entries.allSatisfy { $0.includedBytes <= PickyIPSCollector.maximumBytesPerFile }
        let everyExcerptIsTruncated = entries.allSatisfy { $0.truncated }
        #expect(entries.map(\.filename) == ["Picky-newest.ips", "Picky-second.ips"])
        #expect(everyExcerptFitsPerFileCap)
        #expect(everyExcerptIsTruncated)
        #expect(result.excerptsText.lengthOfBytes(using: .utf8) <= PickyIPSCollector.maximumTotalExcerptBytes)
        #expect(!result.excerptsText.contains("super-secret-value"))
        #expect(result.excerptsText.contains("<redacted>"))
        #expect(!result.excerptsText.contains("Picky-third.ips"))
        #expect(!result.manifestText.contains("Picky-old.ips"))
        #expect(!result.manifestText.contains("OtherProcess.ips"))
    }

    @Test func collectorRejectsSymlinksAndNonRegularFiles() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = root.appendingPathComponent("target.ips")
        try "apiKey=super-secret-value".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Picky-linked.ips"),
            withDestinationURL: target
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Picky-directory.ips"),
            withIntermediateDirectories: true
        )

        let result = PickyIPSCollector.collect(reportsRoot: root, now: now)
        let entries = try decodeManifest(result.manifestText)

        #expect(entries.isEmpty)
        #expect(!result.excerptsText.contains("super-secret-value"))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-ips-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeReport(named name: String, modifiedAt: Date, in root: URL, bytes: Int) throws {
        let report = "apiKey=super-secret-value\n" + String(repeating: "crash frame\n", count: max(1, bytes / 12))
        let url = root.appendingPathComponent(name)
        try report.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func decodeManifest(_ text: String) throws -> [PickyIPSCollector.ManifestEntry] {
        let json = text.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? "[]"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PickyIPSCollector.ManifestEntry].self, from: Data(json.utf8))
    }
}

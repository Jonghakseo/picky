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
        #expect(result.excerptsText.contains("useful-crash-field"))
        #expect(!result.excerptsText.contains("Picky-third.ips"))
        #expect(!result.manifestText.contains("Picky-old.ips"))
        #expect(!result.manifestText.contains("OtherProcess.ips"))
    }

    @Test func collectorRejectsMalformedAndWrongBundlePickyNamedReports() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRawReport(
            named: "Picky-wrong-bundle.ips",
            text: #"{"app_name":"Picky","bundleID":"com.example.other"}"# + "\nwrong bundle",
            modifiedAt: now.addingTimeInterval(-1),
            in: root
        )
        try writeRawReport(
            named: "Picky-malformed.ips",
            text: "not a JSON IPS header\nbody",
            modifiedAt: now.addingTimeInterval(-2),
            in: root
        )
        try writeReport(named: "Picky-valid.ips", modifiedAt: now.addingTimeInterval(-3), in: root, bytes: 100)

        let result = PickyIPSCollector.collect(reportsRoot: root, now: now)
        let entries = try decodeManifest(result.manifestText)

        #expect(entries.map(\.filename) == ["Picky-valid.ips"])
        #expect(!result.excerptsText.contains("wrong bundle"))
        #expect(!result.excerptsText.contains("not a JSON IPS header"))
    }

    @Test func collectorRetainsValidPrefixBeforeUnicodeScalarAtByteCap() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let header = #"{"app_name":"Picky","bundleID":"com.jonghakseo.picky","incident":"unicode-boundary"}"#
        let evidence = "preceding-unicode-evidence="
        let fillerBytes = PickyIPSCollector.maximumBytesPerFile
            - header.lengthOfBytes(using: .utf8)
            - 1
            - evidence.lengthOfBytes(using: .utf8)
            - 2
        let report = header + "\n" + evidence + String(repeating: "x", count: fillerBytes) + "💥tail"
        try writeRawReport(named: "Picky-unicode.ips", text: report, modifiedAt: now, in: root)

        let result = PickyIPSCollector.collect(reportsRoot: root, now: now)

        #expect(result.excerptsText.contains(evidence))
        #expect(!result.excerptsText.contains("bytes omitted"))
        #expect(result.excerptsText.lengthOfBytes(using: .utf8) <= PickyIPSCollector.maximumTotalExcerptBytes)
    }

    @Test func collectorRejectsSymlinksAndNonRegularFiles() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = root.appendingPathComponent("target.ips")
        try validReport(bytes: 100).write(to: target, atomically: true, encoding: .utf8)
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
        try writeRawReport(named: name, text: validReport(bytes: bytes), modifiedAt: modifiedAt, in: root)
    }

    private func validReport(bytes: Int) -> String {
        let header = #"{"app_name":"Picky","bundleID":"com.jonghakseo.picky","incident":"useful-crash-field","nested":{"apiKey":"super-secret-value"}}"#
        return header + "\n" + String(repeating: "crash frame\n", count: max(1, bytes / 12))
    }

    private func writeRawReport(named name: String, text: String, modifiedAt: Date, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func decodeManifest(_ text: String) throws -> [PickyIPSCollector.ManifestEntry] {
        let json = text.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? "[]"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PickyIPSCollector.ManifestEntry].self, from: Data(json.utf8))
    }
}

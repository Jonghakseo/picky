//
//  PickyIPSCollector.swift
//  Picky
//
//  Collects only recent Picky crash reports from DiagnosticReports. It never
//  copies raw reports: all text is redacted and bounded before staging.
//

import Foundation

enum PickyIPSCollector {
    static let maximumFileCount = 2
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumBytesPerFile = 192 * 1024
    static let maximumTotalExcerptBytes = 384 * 1024
    static let maximumHeaderBytes = 64 * 1024

    struct ManifestEntry: Codable, Equatable {
        let filename: String
        let modifiedAt: Date
        let originalBytes: UInt64
        let includedBytes: Int
        let truncated: Bool
    }

    struct CollectionResult {
        let manifestText: String
        let excerptsText: String
    }

    private struct Candidate {
        let url: URL
        let modifiedAt: Date
        let originalBytes: UInt64
    }

    /// The default root is intentionally isolated here so tests supply a
    /// temporary directory and never read the developer machine's reports.
    static func defaultReportsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    static func collect(
        reportsRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> CollectionResult {
        let candidates = recentPickyReports(
            in: reportsRoot,
            now: now,
            fileManager: fileManager
        )
        let heading = [
            "# Recent Picky macOS crash report excerpts",
            "# Reports are redacted before inclusion; raw .ips files are never bundled."
        ].joined(separator: "\n")
        var remainingBytes = maximumTotalExcerptBytes - heading.lengthOfBytes(using: .utf8)
        var entries: [ManifestEntry] = []
        var excerpts = heading

        for candidate in candidates {
            let sectionPrefix = "\n\n"
            let sectionHeader = "# \(candidate.url.lastPathComponent)\noriginalBytes=\(candidate.originalBytes)\n"
            // Reserve enough space for the included-byte and truncation fields
            // before reading the report body, so the aggregate cap is exact.
            let metadataReservation = 64
            let headerBytes = sectionPrefix.lengthOfBytes(using: .utf8)
                + sectionHeader.lengthOfBytes(using: .utf8)
                + metadataReservation
            guard remainingBytes > headerBytes else { break }
            let availableForText = min(maximumBytesPerFile, remainingBytes - headerBytes)
            let data = prefixData(
                from: candidate.url,
                maxBytes: availableForText,
                fileManager: fileManager
            ) ?? Data()
            let text: String
            if let decoded = validUTF8Prefix(from: data) {
                text = PickyDiagnosticTextRedactor.truncateUTF8(
                    PickyDiagnosticTextRedactor.redact(decoded),
                    maxBytes: availableForText,
                    keepingNewest: false
                )
            } else {
                text = PickyDiagnosticTextRedactor.truncateUTF8(
                    "(report excerpt was not valid UTF-8; bytes omitted)",
                    maxBytes: availableForText,
                    keepingNewest: false
                )
            }
            let includedBytes = text.lengthOfBytes(using: .utf8)
            let truncated = UInt64(data.count) < candidate.originalBytes
                || UInt64(includedBytes) < candidate.originalBytes
            let bodyMetadata = "includedBytes=\(includedBytes)\ntruncated=\(truncated)\n"
            excerpts += sectionPrefix + sectionHeader + bodyMetadata + text
            remainingBytes -= sectionPrefix.lengthOfBytes(using: .utf8)
                + sectionHeader.lengthOfBytes(using: .utf8)
                + bodyMetadata.lengthOfBytes(using: .utf8)
                + includedBytes
            entries.append(ManifestEntry(
                filename: candidate.url.lastPathComponent,
                modifiedAt: candidate.modifiedAt,
                originalBytes: candidate.originalBytes,
                includedBytes: includedBytes,
                truncated: truncated
            ))
        }

        let manifestText = renderManifest(entries)
        let boundedExcerpts = PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(excerpts),
            maxBytes: maximumTotalExcerptBytes,
            keepingNewest: false
        )
        return CollectionResult(manifestText: manifestText, excerptsText: boundedExcerpts)
    }

    private static func recentPickyReports(
        in root: URL,
        now: Date,
        fileManager: FileManager
    ) -> [Candidate] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff = now.addingTimeInterval(-maximumAge)
        return urls.compactMap { url -> Candidate? in
            let name = url.lastPathComponent
            guard name.hasPrefix("Picky-"), url.pathExtension.lowercased() == "ips",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff,
                  modifiedAt <= now,
                  hasPickyIdentityHeader(at: url, fileManager: fileManager) else { return nil }
            return Candidate(
                url: url,
                modifiedAt: modifiedAt,
                originalBytes: UInt64(values.fileSize ?? 0)
            )
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        .prefix(maximumFileCount)
        .map { $0 }
    }

    /// IPS reports start with a JSON header. Filename matching alone is not an
    /// identity boundary: only reports emitted for this app and bundle qualify.
    private static func hasPickyIdentityHeader(at url: URL, fileManager: FileManager) -> Bool {
        guard let data = prefixData(from: url, maxBytes: maximumHeaderBytes, fileManager: fileManager),
              let newline = data.firstIndex(of: 0x0A),
              let header = String(data: data.prefix(upTo: newline), encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(header.utf8)),
              let fields = object as? [String: Any],
              fields["app_name"] as? String == "Picky",
              fields["bundleID"] as? String == PickyLog.subsystem else { return false }
        return true
    }

    private static func prefixData(from url: URL, maxBytes: Int, fileManager: FileManager) -> Data? {
        guard maxBytes > 0, fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: maxBytes)
    }

    /// A bounded prefix of otherwise-valid UTF-8 can end partway through a
    /// scalar. Discard only those trailing bytes, retaining preceding evidence.
    private static func validUTF8Prefix(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        for bytesToDrop in 1...min(3, data.count) {
            if let text = String(data: data.dropLast(bytesToDrop), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func renderManifest(_ entries: [ManifestEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let rendered = (try? String(data: encoder.encode(entries), encoding: .utf8)) ?? "[]"
        return PickyDiagnosticTextRedactor.redact("# Picky IPS manifest\n\(rendered)\n")
    }
}

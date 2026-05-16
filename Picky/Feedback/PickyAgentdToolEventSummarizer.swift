//
//  PickyAgentdToolEventSummarizer.swift
//  Picky
//
//  Produces a privacy-preserving tool activity summary from agentd stdout.
//  The raw stdout log is never attached because it can contain user chat,
//  prompts, tool arguments, and tool results. We parse only Picky's structured
//  `picky-agentd tool activity ... tool="name" status=...` lifecycle lines and
//  write timestamp + tool name + status. Session IDs, previews, args, and
//  results are intentionally discarded.
//

import Foundation

struct PickyAgentdToolEvent: Equatable {
    var timestamp: String
    var toolName: String
    var status: String
}

enum PickyAgentdToolEventSummarizer {
    static let defaultMaxSourceBytes = 5_000_000
    static let defaultMaxEvents = 300

    static func summarize(
        from stdoutURL: URL,
        maxSourceBytes: Int = defaultMaxSourceBytes,
        maxEvents: Int = defaultMaxEvents,
        fileManager: FileManager = .default
    ) -> String {
        guard fileManager.fileExists(atPath: stdoutURL.path) else {
            return header + "\n(no agentd stdout log present)"
        }
        guard let text = readTailText(from: stdoutURL, maxBytes: maxSourceBytes) else {
            return header + "\n(agentd stdout log could not be read)"
        }
        let events = parseToolEvents(from: text).suffix(max(1, maxEvents))
        guard !events.isEmpty else {
            return header + "\n(no tool activity lines found in the recent agentd stdout tail)"
        }

        var lines: [String] = [header, ""]
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.toolName, default: 0] += 1
            lines.append("\(event.timestamp) tool=\(event.toolName) status=\(event.status)")
        }
        if !counts.isEmpty {
            lines.append("")
            lines.append("Counts by tool:")
            for (tool, count) in counts.sorted(by: { $0.key < $1.key }) {
                lines.append("\(tool): \(count)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func parseToolEvents(from text: String) -> [PickyAgentdToolEvent] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { rawLine in
            parseToolEventLine(String(rawLine))
        }
    }

    static func parseToolEventLine(_ line: String) -> PickyAgentdToolEvent? {
        guard line.contains(" picky-agentd tool activity") else { return nil }
        guard let timestamp = line.split(separator: " ").first.map(String.init) else { return nil }
        guard let toolName = fieldValue(named: "tool", in: line) else { return nil }
        guard let status = fieldValue(named: "status", in: line) else { return nil }
        return PickyAgentdToolEvent(timestamp: timestamp, toolName: toolName, status: status)
    }

    private static var header: String {
        "# Tool activity summary (privacy-preserving)\n# Raw stdout is NOT attached. User chat, tool arguments, and tool results are excluded."
    }

    private static func readTailText(from url: URL, maxBytes: Int) -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            let bytesToRead = min(fileSize, UInt64(max(1, maxBytes)))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if fileSize > bytesToRead {
                try handle.seek(toOffset: fileSize - bytesToRead)
            }
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func fieldValue(named field: String, in line: String) -> String? {
        let pattern = #"\b\#(field)=(?:"([^"]*)"|([^\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            let r = match.range(at: index)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: line) else { continue }
            let value = String(line[swiftRange])
            if !value.isEmpty { return value }
        }
        return nil
    }
}

//
//  PickyAgentdSessionIdentitySummarizer.swift
//  Picky
//
//  Produces a privacy-preserving session identity & title timeline from agentd
//  stdout. The raw stdout log is never attached because it can contain user
//  chat, prompts, tool arguments, and tool results. We parse only Picky's
//  structured `picky-agentd <event> sessionId="..." ...` lifecycle lines and
//  extract the few fields needed to triage "a Pickle's messages/title moved to
//  another Pickle" reports: session id, cwd, Pickle title changes, and the Pi
//  session file *basename*. Previews, args, and results are discarded, and the
//  rendered text is run through `PickyDiagnosticTextRedactor`.
//

import Foundation

struct PickyAgentdSessionIdentityEvent: Equatable {
    var timestamp: String
    var sessionId: String
    var event: String
    var cwd: String?
    var title: String?
    var previousTitle: String?
    var name: String?
    /// Basenames of any Pi session file referenced on this line. Full paths are
    /// reduced to their last path component so the cwd-encoded session
    /// directory (which embeds the macOS username) never reaches the bundle.
    var sessionFiles: [String]
}

enum PickyAgentdSessionIdentitySummarizer {
    static let defaultMaxSourceBytes = 5_000_000
    static let defaultMaxEvents = 400

    private static let fileFieldNames = ["sessionFilePath", "piSessionFilePath", "sourceSessionFilePath", "newFilePath"]

    static func summarize(
        from stdoutURL: URL,
        maxSourceBytes: Int = defaultMaxSourceBytes,
        maxEvents: Int = defaultMaxEvents,
        fileManager: FileManager = .default
    ) -> String {
        guard fileManager.fileExists(atPath: stdoutURL.path) else {
            return PickyDiagnosticTextRedactor.redact(header + "\n(no agentd stdout log present)")
        }
        guard let text = readTailText(from: stdoutURL, maxBytes: maxSourceBytes, fileManager: fileManager) else {
            return PickyDiagnosticTextRedactor.redact(header + "\n(agentd stdout log could not be read)")
        }
        let events = Array(parseEvents(from: text).suffix(max(1, maxEvents)))
        guard !events.isEmpty else {
            return PickyDiagnosticTextRedactor.redact(header + "\n(no session identity lines found in the recent agentd stdout tail)")
        }
        return PickyDiagnosticTextRedactor.redact(render(events: events))
    }

    static func parseEvents(from text: String) -> [PickyAgentdSessionIdentityEvent] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { rawLine in
            parseLine(String(rawLine))
        }
    }

    static func parseLine(_ line: String) -> PickyAgentdSessionIdentityEvent? {
        guard let markerRange = line.range(of: " picky-agentd ") else { return nil }
        guard let timestamp = line.split(separator: " ").first.map(String.init) else { return nil }
        guard let sessionId = fieldValue(named: "sessionId", in: line) else { return nil }

        let cwd = fieldValue(named: "cwd", in: line)
        let title = fieldValue(named: "title", in: line)
        let previousTitle = fieldValue(named: "previousTitle", in: line)
        let name = fieldValue(named: "name", in: line)
        let sessionFiles = fileFieldNames
            .compactMap { fieldValue(named: $0, in: line) }
            .map { ($0 as NSString).lastPathComponent }
            .filter { !$0.isEmpty }

        // Only keep lines that actually carry identity-relevant context beyond
        // the session id; everything else is noise for this summary.
        guard cwd != nil || title != nil || previousTitle != nil || name != nil || !sessionFiles.isEmpty else {
            return nil
        }

        let event = eventName(after: markerRange.upperBound, in: line)
        return PickyAgentdSessionIdentityEvent(
            timestamp: timestamp,
            sessionId: sessionId,
            event: event,
            cwd: cwd,
            title: title,
            previousTitle: previousTitle,
            name: name,
            sessionFiles: sessionFiles
        )
    }

    static func render(events: [PickyAgentdSessionIdentityEvent]) -> String {
        var lines: [String] = [header, "", "## Timeline"]
        for event in events {
            var parts = ["\(event.timestamp) session=\(event.sessionId) event=\"\(event.event)\""]
            if let cwd = event.cwd { parts.append("cwd=\(cwd)") }
            if let title = event.title { parts.append("title=\"\(title)\"") }
            if let previousTitle = event.previousTitle, let name = event.name {
                parts.append("previousTitle=\"\(previousTitle)\" -> name=\"\(name)\"")
            } else if let previousTitle = event.previousTitle {
                parts.append("previousTitle=\"\(previousTitle)\"")
            } else if let name = event.name {
                parts.append("name=\"\(name)\"")
            }
            if !event.sessionFiles.isEmpty {
                parts.append("sessionFile=\(event.sessionFiles.joined(separator: ","))")
            }
            lines.append(parts.joined(separator: " "))
        }

        lines.append("")
        lines.append("## Per-session summary")
        var fileToSessions: [String: Set<String>] = [:]
        for sessionId in orderedSessionIds(in: events) {
            let sessionEvents = events.filter { $0.sessionId == sessionId }
            let cwd = sessionEvents.compactMap(\.cwd).last
            let titleTimeline = titleTimeline(for: sessionEvents)
            let files = orderedUnique(sessionEvents.flatMap(\.sessionFiles))
            for file in files { fileToSessions[file, default: []].insert(sessionId) }
            lines.append("session=\(sessionId)\(cwd.map { " cwd=\($0)" } ?? "")")
            if !titleTimeline.isEmpty {
                lines.append("  titleTimeline: \(titleTimeline.map { "\"\($0)\"" }.joined(separator: " -> "))")
            }
            if !files.isEmpty {
                lines.append("  sessionFiles: \(files.joined(separator: ", "))")
            }
        }

        lines.append("")
        lines.append("## Shared Pi session files (possible cross-load)")
        let shared = fileToSessions.filter { $0.value.count > 1 }
        if shared.isEmpty {
            lines.append("(none detected — each Pi session file basename maps to a single session)")
        } else {
            for (file, sessions) in shared.sorted(by: { $0.key < $1.key }) {
                lines.append("\(file) <- \(sessions.sorted().map { "session=\($0)" }.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Builds the ordered list of distinct titles a session passed through, so a
    /// late "title flip" (e.g. `New Pickle · cwd` -> a Pi-generated name) is
    /// visible at a glance.
    private static func titleTimeline(for events: [PickyAgentdSessionIdentityEvent]) -> [String] {
        var timeline: [String] = []
        func push(_ value: String?) {
            guard let value, !value.isEmpty, timeline.last != value else { return }
            timeline.append(value)
        }
        for event in events {
            push(event.previousTitle)
            push(event.name)
            push(event.title)
        }
        return timeline
    }

    private static func orderedSessionIds(in events: [PickyAgentdSessionIdentityEvent]) -> [String] {
        orderedUnique(events.map(\.sessionId))
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static var header: String {
        """
        # Session identity & title timeline (privacy-preserving)
        # Raw stdout is NOT attached. Only session lifecycle fields are extracted:
        # session id, cwd, Pickle title changes, and the Pi session file basename.
        # User chat, tool arguments, and tool results are excluded. Home paths and
        # token-shaped values are redacted.
        """
    }

    private static func eventName(after start: String.Index, in line: String) -> String {
        let remainder = String(line[start...])
        guard let regex = try? NSRegularExpression(pattern: #"\s[A-Za-z][A-Za-z0-9_]*="#) else {
            return remainder
        }
        let range = NSRange(remainder.startIndex..<remainder.endIndex, in: remainder)
        guard let match = regex.firstMatch(in: remainder, range: range),
              let swiftRange = Range(match.range, in: remainder) else {
            return remainder.trimmingCharacters(in: .whitespaces)
        }
        return String(remainder[remainder.startIndex..<swiftRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func readTailText(from url: URL, maxBytes: Int, fileManager: FileManager) -> String? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
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

import Foundation

struct UnifiedDiffParser {
    func parse(_ diff: String, title: String, repoRoot: String, subtitle: String) -> DiffReviewSnapshot {
        var files: [DiffFile] = []
        var current: FileBuilder?
        let lines = diff.components(separatedBy: .newlines)

        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let file = current?.build() { files.append(file) }
                current = FileBuilder(diffHeader: line, sequence: files.count)
            } else if current != nil {
                current?.consume(line)
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current = FileBuilder.synthetic(sequence: files.count)
                current?.consume(line)
            }
        }

        if let file = current?.build() { files.append(file) }

        return DiffReviewSnapshot(
            title: title,
            repoRoot: repoRoot,
            subtitle: subtitle,
            files: files.filter { !$0.hunks.isEmpty || !$0.metadataLines.isEmpty || $0.isBinary }
        )
    }
}

private struct FileBuilder {
    var sequence: Int
    var status: DiffFileStatus = .modified
    var oldPath: String?
    var newPath: String?
    var displayPath: String
    var metadataLines: [String] = []
    var hunks: [HunkBuilder] = []
    var isBinary = false
    private var nextLineSequence = 0

    init(diffHeader: String, sequence: Int) {
        self.sequence = sequence
        let parsed = Self.parseDiffHeader(diffHeader)
        self.oldPath = parsed.oldPath
        self.newPath = parsed.newPath
        self.displayPath = parsed.newPath ?? parsed.oldPath ?? "unified.diff"
        self.metadataLines = [diffHeader]
    }

    private init(sequence: Int) {
        self.sequence = sequence
        self.displayPath = "unified.diff"
    }

    static func synthetic(sequence: Int) -> FileBuilder {
        FileBuilder(sequence: sequence)
    }

    mutating func consume(_ line: String) {
        if line.hasPrefix("new file mode") {
            status = .added
            oldPath = nil
            metadataLines.append(line)
            return
        }
        if line.hasPrefix("deleted file mode") {
            status = .deleted
            newPath = nil
            metadataLines.append(line)
            return
        }
        if line.hasPrefix("rename from ") {
            status = .renamed
            oldPath = String(line.dropFirst("rename from ".count))
            metadataLines.append(line)
            refreshDisplayPath()
            return
        }
        if line.hasPrefix("rename to ") {
            status = .renamed
            newPath = String(line.dropFirst("rename to ".count))
            metadataLines.append(line)
            refreshDisplayPath()
            return
        }
        if line.hasPrefix("copy from ") {
            status = .copied
            oldPath = String(line.dropFirst("copy from ".count))
            metadataLines.append(line)
            refreshDisplayPath()
            return
        }
        if line.hasPrefix("copy to ") {
            status = .copied
            newPath = String(line.dropFirst("copy to ".count))
            metadataLines.append(line)
            refreshDisplayPath()
            return
        }
        if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            isBinary = true
            metadataLines.append(line)
            return
        }
        if line.hasPrefix("--- ") {
            if line == "--- /dev/null" { oldPath = nil }
            metadataLines.append(line)
            return
        }
        if line.hasPrefix("+++ ") {
            if line == "+++ /dev/null" { newPath = nil }
            metadataLines.append(line)
            refreshStatusFromPaths()
            return
        }
        if line.hasPrefix("@@") {
            hunks.append(HunkBuilder(header: line, fileSequence: sequence, hunkSequence: hunks.count))
            return
        }

        guard !hunks.isEmpty else {
            if !line.isEmpty { metadataLines.append(line) }
            return
        }
        nextLineSequence += 1
        hunks[hunks.count - 1].consume(line, lineSequence: nextLineSequence)
    }

    mutating private func refreshDisplayPath() {
        if status == .renamed || status == .copied {
            displayPath = "\(oldPath ?? "(unknown)") → \(newPath ?? "(unknown)")"
        } else {
            displayPath = newPath ?? oldPath ?? displayPath
        }
    }

    mutating private func refreshStatusFromPaths() {
        if status == .modified {
            if oldPath == nil { status = .added }
            if newPath == nil { status = .deleted }
        }
        refreshDisplayPath()
    }

    func build() -> DiffFile? {
        let builtHunks = hunks.map { $0.build() }
        guard !displayPath.isEmpty else { return nil }
        return DiffFile(
            id: "file-\(sequence)-\(displayPath)",
            status: status,
            oldPath: oldPath,
            newPath: newPath,
            displayPath: displayPath,
            hunks: builtHunks,
            metadataLines: metadataLines,
            isBinary: isBinary
        )
    }

    private static func parseDiffHeader(_ header: String) -> (oldPath: String?, newPath: String?) {
        let parts = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else { return (nil, nil) }
        return (stripGitPrefix(parts[2], prefix: "a/"), stripGitPrefix(parts[3], prefix: "b/"))
    }

    private static func stripGitPrefix(_ path: String, prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private struct HunkBuilder {
    var header: String
    var fileSequence: Int
    var hunkSequence: Int
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var section: String
    var lines: [DiffLine] = []
    private var oldCursor: Int
    private var newCursor: Int

    init(header: String, fileSequence: Int, hunkSequence: Int) {
        self.header = header
        self.fileSequence = fileSequence
        self.hunkSequence = hunkSequence
        let parsed = Self.parseHeader(header)
        self.oldStart = parsed.oldStart
        self.oldCount = parsed.oldCount
        self.newStart = parsed.newStart
        self.newCount = parsed.newCount
        self.section = parsed.section
        self.oldCursor = parsed.oldStart
        self.newCursor = parsed.newStart
    }

    mutating func consume(_ line: String, lineSequence: Int) {
        guard let marker = line.first else {
            append(kind: .context, oldNumber: oldCursor, newNumber: newCursor, text: "", lineSequence: lineSequence)
            oldCursor += 1
            newCursor += 1
            return
        }

        let body = String(line.dropFirst())
        switch marker {
        case "+":
            append(kind: .addition, oldNumber: nil, newNumber: newCursor, text: body, lineSequence: lineSequence)
            newCursor += 1
        case "-":
            append(kind: .deletion, oldNumber: oldCursor, newNumber: nil, text: body, lineSequence: lineSequence)
            oldCursor += 1
        case " ":
            append(kind: .context, oldNumber: oldCursor, newNumber: newCursor, text: body, lineSequence: lineSequence)
            oldCursor += 1
            newCursor += 1
        case "\\":
            append(kind: .metadata, oldNumber: nil, newNumber: nil, text: line, lineSequence: lineSequence)
        default:
            append(kind: .metadata, oldNumber: nil, newNumber: nil, text: line, lineSequence: lineSequence)
        }
    }

    private mutating func append(kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, text: String, lineSequence: Int) {
        lines.append(DiffLine(
            id: "line-\(fileSequence)-\(hunkSequence)-\(lineSequence)",
            kind: kind,
            oldNumber: oldNumber,
            newNumber: newNumber,
            text: text
        ))
    }

    func build() -> DiffHunk {
        DiffHunk(
            id: "hunk-\(fileSequence)-\(hunkSequence)",
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            section: section,
            lines: lines
        )
    }

    private static func parseHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String) {
        let pattern = #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
            return (1, 1, 1, 1, "")
        }
        func value(_ index: Int, default fallback: Int) -> Int {
            guard let range = Range(match.range(at: index), in: header) else { return fallback }
            return Int(header[range]) ?? fallback
        }
        let section: String = {
            guard let range = Range(match.range(at: 5), in: header) else { return "" }
            return String(header[range]).trimmingCharacters(in: .whitespaces)
        }()
        return (value(1, default: 1), value(2, default: 1), value(3, default: 1), value(4, default: 1), section)
    }
}

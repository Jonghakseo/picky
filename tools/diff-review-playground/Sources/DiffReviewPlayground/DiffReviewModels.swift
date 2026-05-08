import Foundation

struct DiffReviewSnapshot: Equatable {
    var title: String
    var repoRoot: String
    var subtitle: String
    var files: [DiffFile]

    var insertions: Int { files.reduce(0) { $0 + $1.insertions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    var isEmpty: Bool { files.isEmpty }
}

struct DiffFile: Equatable, Identifiable {
    var id: String
    var status: DiffFileStatus
    var oldPath: String?
    var newPath: String?
    var displayPath: String
    var hunks: [DiffHunk]
    var metadataLines: [String]
    var isBinary: Bool

    var insertions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
}

enum DiffFileStatus: String, Equatable, CaseIterable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unknown = "?"

    var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .unknown: "Changed"
        }
    }
}

struct DiffHunk: Equatable, Identifiable {
    var id: String
    var header: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var section: String
    var lines: [DiffLine]
}

struct DiffLine: Equatable, Identifiable {
    var id: String
    var kind: DiffLineKind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}

enum DiffLineKind: Equatable {
    case context
    case addition
    case deletion
    case metadata
}

enum DiffViewMode: String, CaseIterable, Equatable {
    case unified = "Unified"
    case split = "Split"
}

struct SplitDiffRow: Equatable, Identifiable {
    var id: String
    var oldLine: DiffLine?
    var newLine: DiffLine?
}

extension DiffHunk {
    var splitRows: [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .deletion {
                var deletions: [DiffLine] = []
                while index < lines.count, lines[index].kind == .deletion {
                    deletions.append(lines[index])
                    index += 1
                }
                var additions: [DiffLine] = []
                while index < lines.count, lines[index].kind == .addition {
                    additions.append(lines[index])
                    index += 1
                }
                let count = max(deletions.count, additions.count)
                for pairIndex in 0..<count {
                    rows.append(SplitDiffRow(
                        id: "split-\(id)-\(rows.count)",
                        oldLine: pairIndex < deletions.count ? deletions[pairIndex] : nil,
                        newLine: pairIndex < additions.count ? additions[pairIndex] : nil
                    ))
                }
                continue
            }
            if line.kind == .addition {
                rows.append(SplitDiffRow(id: "split-\(id)-\(rows.count)", oldLine: nil, newLine: line))
            } else {
                rows.append(SplitDiffRow(id: "split-\(id)-\(rows.count)", oldLine: line, newLine: line))
            }
            index += 1
        }
        return rows
    }
}

struct DiffReviewComment: Equatable, Identifiable {
    var id = UUID()
    var target: DiffCommentTarget
    var body: String
    var createdAt = Date()
}

struct DiffCommentTarget: Equatable, Hashable, Identifiable {
    enum Side: String, Equatable {
        case original
        case modified
        case file
    }

    var id: String {
        [fileID, side.rawValue, oldLine.map(String.init) ?? "", newLine.map(String.init) ?? ""].joined(separator: ":")
    }

    var fileID: String
    var side: Side
    var oldLine: Int?
    var newLine: Int?

    static func file(fileID: String) -> DiffCommentTarget {
        DiffCommentTarget(fileID: fileID, side: .file, oldLine: nil, newLine: nil)
    }

    static func line(fileID: String, line: DiffLine) -> DiffCommentTarget {
        let side: Side = line.kind == .deletion ? .original : .modified
        return DiffCommentTarget(fileID: fileID, side: side, oldLine: line.oldNumber, newLine: line.newNumber)
    }

    var displayLine: Int? {
        side == .original ? oldLine : newLine
    }
}

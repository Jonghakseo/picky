//
//  PickyDiffReviewPrompt.swift
//  Picky
//
//  Swift port of the diff-review composeReviewPrompt implementation.
//

import Foundation

enum PickyDiffReviewPrompt {
    struct SubmitPayload: Decodable, Equatable {
        let overallComment: String
        let comments: [DiffReviewComment]
    }

    static func compose(files: [ReviewFile], payload: SubmitPayload) -> String {
        let fileMap = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        var lines: [String] = []

        lines.append("Please address the following feedback")
        lines.append("")

        let overallComment = payload.overallComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overallComment.isEmpty {
            lines.append(overallComment)
            lines.append("")
        }

        for (index, comment) in payload.comments.enumerated() {
            let file = fileMap[comment.fileId]
            lines.append("\(index + 1). \(formatLocation(comment, file: file))")
            lines.append("   \(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasFeedback(_ payload: SubmitPayload) -> Bool {
        payload.overallComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            payload.comments.contains { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    private static func formatScopeLabel(_ comment: DiffReviewComment) -> String {
        switch comment.scope {
        case .branch:
            return "branch diff"
        case .commits:
            if comment.commitKind == .workingTree {
                return "working tree changes"
            }
            if let commitShort = comment.commitShort, !commitShort.isEmpty {
                return "commit \(commitShort)"
            }
            return "commit"
        case .all:
            return "all files"
        }
    }

    private static func getCommentFilePath(_ file: ReviewFile?) -> String {
        guard let file else { return "(unknown file)" }
        return file.gitDiff?.displayPath ?? file.path
    }

    private static func formatLocation(_ comment: DiffReviewComment, file: ReviewFile?) -> String {
        let filePath = getCommentFilePath(file)
        let scopePrefix = "[\(formatScopeLabel(comment))] "

        if comment.side == .file || comment.startLine == nil {
            return "\(scopePrefix)\(filePath)"
        }

        let startLine = comment.startLine ?? 0
        let range: String
        if let endLine = comment.endLine, endLine != startLine {
            range = "\(startLine)-\(endLine)"
        } else {
            range = "\(startLine)"
        }

        if comment.scope == .all {
            return "\(scopePrefix)\(filePath):\(range)"
        }

        let suffix = comment.side == .original ? " (old)" : " (new)"
        return "\(scopePrefix)\(filePath):\(range)\(suffix)"
    }
}

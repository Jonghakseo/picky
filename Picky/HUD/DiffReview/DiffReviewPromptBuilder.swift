import Foundation

struct DiffReviewPromptBuilder {
    func build(snapshot: DiffReviewSnapshot, overallComment: String, comments: [DiffReviewComment]) -> String {
        var lines: [String] = []
        lines.append("Please address the following review feedback.")
        lines.append("")
        lines.append("Repository: \(snapshot.repoRoot)")
        lines.append("Diff: \(snapshot.subtitle)")
        lines.append("")

        let overall = overallComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overall.isEmpty {
            lines.append("Overall:")
            lines.append(overall)
            lines.append("")
        }

        for (index, comment) in comments.enumerated() where !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("\(index + 1). \(location(for: comment, in: snapshot))")
            lines.append("   \(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func location(for comment: DiffReviewComment, in snapshot: DiffReviewSnapshot) -> String {
        let file = snapshot.files.first { $0.id == comment.target.fileID }
        let filePath = file?.displayPath ?? "(unknown file)"
        guard comment.target.side != .file, let line = comment.target.displayLine else {
            return filePath
        }
        let side = comment.target.side == .original ? "old" : "new"
        return "\(filePath):\(line) (\(side))"
    }
}

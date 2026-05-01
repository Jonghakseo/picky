//
//  PickyArtifactReporter.swift
//  Picky
//
//  Local report/artifact helpers for safe HUD opening and tests.
//

import Foundation

struct PickyArtifactReportBuilder {
    func markdown(for session: PickyAgentSession) -> String {
        var lines: [String] = ["# \(session.title)", "", "Status: `\(session.status.rawValue)`", ""]
        if let cwd = session.cwd { lines.append("CWD: `\(cwd)`"); lines.append("") }
        if let summary = session.lastSummary, !summary.isEmpty {
            lines.append("## Final answer")
            lines.append(summary)
            lines.append("")
        }
        if !session.tools.isEmpty {
            lines.append("## Tool summary")
            for tool in session.tools {
                let preview = tool.preview.map { " — \($0)" } ?? ""
                lines.append("- `\(tool.name)` \(tool.status)\(preview)")
            }
            lines.append("")
        }
        if !session.artifacts.isEmpty {
            lines.append("## Artifacts")
            for artifact in session.artifacts {
                if let url = artifact.url {
                    lines.append("- [\(artifact.title)](\(url.absoluteString))")
                } else if let path = artifact.path {
                    lines.append("- \(artifact.title): `\(path)`")
                } else {
                    lines.append("- \(artifact.title)")
                }
            }
            lines.append("")
        }
        let prURLs = PickyArtifactReportBuilder.githubPullRequestURLs(in: [session.lastSummary, session.logs.joined(separator: "\n")].compactMap { $0 }.joined(separator: "\n"))
        if !prURLs.isEmpty {
            lines.append("## Pull requests")
            lines.append(contentsOf: prURLs.map { "- \($0.absoluteString)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func githubPullRequestURLs(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let value = String(text[matchRange])
            guard seen.insert(value).inserted else { return nil }
            return URL(string: value)
        }
    }
}

enum PickyArtifactOpeningError: LocalizedError, Equatable {
    case missingPath
    case escapedAppSupportRoot(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .missingPath: "Artifact has no local path."
        case .escapedAppSupportRoot(let path): "Artifact path is outside Picky app support: \(path)"
        case .missingFile(let path): "Artifact file is missing: \(path)"
        }
    }
}

struct PickyArtifactPathValidator {
    let appSupportRoot: URL
    var fileManager: FileManager = .default

    func validateReadableFile(path: String) throws -> URL {
        let root = appSupportRoot.standardizedFileURL.path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == root || url.path.hasPrefix(root + "/") else {
            throw PickyArtifactOpeningError.escapedAppSupportRoot(path)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw PickyArtifactOpeningError.missingFile(path)
        }
        return url
    }
}

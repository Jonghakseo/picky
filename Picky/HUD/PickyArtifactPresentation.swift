import Foundation

enum PickyLinkBadgeKind: Equatable {
    case github, slack, notion, jira, sentry, linear, figma, googleDocs, googleSheets, googleSlides, googleDrive
}

extension PickyArtifact {
    var isHUDLinkBadge: Bool { linkBadgeKind != nil }

    var linkBadgeKind: PickyLinkBadgeKind? {
        if kind == "github" || kind == "pr" { return .github }
        if kind == "slack" { return .slack }
        if kind == "notion" { return .notion }
        if kind == "jira" { return .jira }
        if kind == "sentry" { return .sentry }
        if kind == "linear" { return .linear }
        if kind == "figma" { return .figma }
        if kind == "googleDocs" { return .googleDocs }
        if kind == "googleSheets" { return .googleSheets }
        if kind == "googleSlides" { return .googleSlides }
        if kind == "googleDrive" { return .googleDrive }
        guard let url else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host == "github.com", githubIssueOrPullRequestNumber != nil { return .github }
        if host.hasSuffix(".slack.com"), url.pathComponents.contains("archives") { return .slack }
        if ["notion.so", "www.notion.so", "app.notion.com"].contains(host) { return .notion }
        if host.hasSuffix(".atlassian.net"), jiraIssueKey != nil { return .jira }
        if host.hasSuffix(".sentry.io"), url.pathComponents.contains("issues") { return .sentry }
        if host == "linear.app", linearIssueKey != nil { return .linear }
        if host == "figma.com" || host.hasSuffix(".figma.com"), let fileType = url.pathComponents.dropFirst().first, ["file", "design", "proto", "board"].contains(fileType) { return .figma }
        if host == "docs.google.com", url.pathComponents.contains("document") { return .googleDocs }
        if host == "docs.google.com", url.pathComponents.contains("spreadsheets") { return .googleSheets }
        if host == "docs.google.com", url.pathComponents.contains("presentation") { return .googleSlides }
        if host == "drive.google.com", url.pathComponents.contains("file") || url.pathComponents.contains("drive") { return .googleDrive }
        return nil
    }

    var githubIssueOrPullRequestNumber: String? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let markerIndex = components.firstIndex(where: { $0 == "pull" || $0 == "issues" }) else { return nil }
        let numberIndex = components.index(after: markerIndex)
        guard components.indices.contains(numberIndex) else { return nil }
        let number = components[numberIndex]
        return number.allSatisfy(\.isNumber) ? number : nil
    }

    var jiraIssueKey: String? {
        issueKey(after: "browse")
    }

    var linearIssueKey: String? {
        issueKey(after: "issue")
    }

    private func issueKey(after marker: String) -> String? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let markerIndex = components.firstIndex(of: marker) else { return nil }
        let keyIndex = components.index(after: markerIndex)
        guard components.indices.contains(keyIndex) else { return nil }
        let key = components[keyIndex]
        guard key.range(of: #"^[A-Z][A-Z0-9]+-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return key
    }
}

extension PickyToolActivity {
    var isActive: Bool { status == "started" || status == "running" }

    var didFail: Bool { status == "failed" || status == "error" }

    var riskLevel: PickyToolRiskLevel {
        let lowercasedName = name.lowercased()
        if ["bash", "shell", "edit", "write"].contains(where: lowercasedName.contains) {
            return .elevated
        }
        if ["mcp", "db", "slack", "external"].contains(where: lowercasedName.contains) {
            return .external
        }
        return .normal
    }
}

enum PickyToolRiskLevel: Equatable {
    case normal, elevated, external
}

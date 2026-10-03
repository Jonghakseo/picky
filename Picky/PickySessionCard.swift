//
//  PickySessionCard.swift
//  Picky
//
//  HUD session projection value model plus its merge, parsing, and ordering
//  policies. This keeps daemon event orchestration out of the value model.
//

import Foundation

struct PickySessionCard: Equatable, Identifiable {
    let id: String
    var title: String
    var status: PickySessionStatus
    var cwd: String?
    var createdAt: Date
    var updatedAt: Date
    var lastSummary: String
    var thinkingPreview: String?
    /// Live-only: true while the daemon reports the model streaming reply text
    /// (`sessionReplyWritingUpdated`). It has no projection owner, so it is
    /// never hydrated from a snapshot and older daemons simply leave it false.
    var isWritingReply: Bool = false
    /// Live-only: true while the daemon reports the model streaming a tool
    /// call's arguments (`sessionToolCallPreparingUpdated`). Same ownership as
    /// `isWritingReply`.
    var isPreparingToolCall: Bool = false
    var logPreview: String
    var lastRequestText: String?
    // When the latest REQUEST row content was observed/sent locally. Used to render the
    // "X ago" stamp on that row independent of session.createdAt or session.updatedAt;
    // updatedAt is bumped by every tool/log event so it cannot stand in.
    var lastRequestAt: Date?
    var tools: [PickyToolActivity]
    var todoState: PickyTodoState? = nil
    var subagentRuns: [PickySubagentRun] = []
    var agentCycle: PickyAgentCycle? = nil
    var asyncWorkSummary: PickyAsyncWorkSummary? = nil
    var asyncTasks: [PickyAsyncTask]? = nil
    var completionTickets: [PickyCompletionTicket]? = nil
    var asyncControl: PickyAsyncControlState? = nil
    var artifacts: [PickyArtifact]
    var changedFiles: [PickyChangedFile]
    var messages: [PickySessionMessage]
    var queuedSteers: [PickyQueueItem]
    var queuedFollowUps: [PickyQueueItem]
    var scheduledMessages: [PickyScheduledMessage] = []
    var steeringMode: PickyQueueMode
    var followUpMode: PickyQueueMode
    var activitySummary: PickyActivitySummary
    var lastTerminalSyncOutcome: PickyTerminalSessionSyncOutcome? = nil
    var contextUsage: PickyContextUsage? = nil
    var currentAssistantRun: PickyAssistantRunMetadata? = nil
    var pendingExtensionUiRequest: PickyExtensionUiRequest?
    var piSessionFilePath: String?
    var notifyMainOnCompletion: Bool?
    var notifyMacOSOnCompletion: Bool? = nil
    var pinned: Bool
    /// Daemon-side archive flag mirrored from `PickyAgentSession.archived`.
    /// Snapshot hydration hoists this into the local `manuallyArchivedSessionIDs`
    /// UserDefaults so a Picky restart with cleared local state still partitions
    /// archived Pickles correctly. Live projection transactions keep using the
    /// local intent set to avoid mid-flight unarchive flicker.
    var archived: Bool
    /// When the session was archived. Orders the archived list (most recently
    /// archived first); nil for active sessions and legacy archives.
    var archivedAt: Date? = nil

    var activeTool: PickyToolActivity? {
        tools.last { $0.isActive }
    }

    var compactCwdDescription: String? {
        Self.compactCwd(cwd)
    }

    var toolCount: Int { tools.count }

    var isTerminal: Bool { status.isTerminal }

    var linkBadgeArtifacts: [PickyArtifact] {
        artifacts.filter(\.isHUDLinkBadge)
    }

    var prArtifacts: [PickyArtifact] {
        linkBadgeArtifacts.filter { $0.linkBadgeKind == .github }
    }

    var latestAgentResponseReportMessageID: String? {
        messages.last { message in
            message.kind == .agentText && message.openAsReportMarkdown != nil
        }?.id
    }

    var hasLatestAgentResponseReport: Bool {
        latestAgentResponseReportMessageID != nil
    }

    /// Filtered link badges for the HUD: drop any GitHub artifact whose URL points to
    /// the PR we already render as a dedicated PR badge, so the same pull request does
    /// not show up twice in the row.
    func linkBadgeArtifacts(suppressingPullRequest pullRequest: PickyGitHubPullRequestStatus?) -> [PickyArtifact] {
        guard let pullRequest else { return linkBadgeArtifacts }
        let prRepoPath = Self.githubRepositoryPath(of: pullRequest.url)
        let prNumber = String(pullRequest.number)
        return linkBadgeArtifacts.filter { artifact in
            guard artifact.linkBadgeKind == .github,
                  let url = artifact.url,
                  // Only suppress PR-shaped URLs; an issue with the same number must stay visible.
                  url.pathComponents.contains("pull"),
                  Self.githubRepositoryPath(of: url) == prRepoPath,
                  artifact.githubIssueOrPullRequestNumber == prNumber else {
                return true
            }
            return false
        }
    }

    static func githubRepositoryPath(of url: URL) -> String? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return "\(components[0])/\(components[1])".lowercased()
    }

    func linkBadgeText(for artifact: PickyArtifact) -> String? {
        guard let kind = artifact.linkBadgeKind else { return artifact.title }
        switch kind {
        case .github:
            return artifact.githubIssueOrPullRequestNumber.map { "#\($0)" } ?? artifact.title
        case .jira:
            return artifact.jiraIssueKey ?? artifact.title
        case .linear:
            return artifact.linearIssueKey ?? artifact.title
        case .slack, .notion, .sentry, .figma, .googleDocs, .googleSheets, .googleSlides, .googleDrive:
            let sameKind = linkBadgeArtifacts.filter { $0.linkBadgeKind == kind }
            guard sameKind.count > 1, let index = sameKind.firstIndex(where: { $0.id == artifact.id }) else { return nil }
            return "#\(index + 1)"
        case .generic:
            guard let host = artifact.url?.host?.lowercased() else { return nil }
            let sameHost = linkBadgeArtifacts.filter {
                $0.linkBadgeKind == .generic && $0.url?.host?.lowercased() == host
            }
            guard sameHost.count > 1, let index = sameHost.firstIndex(where: { $0.id == artifact.id }) else { return nil }
            return "#\(index + 1)"
        }
    }

    var isRuntimeDetached: Bool {
        status == .blocked
            && (lastSummary.localizedCaseInsensitiveContains("Runtime session is not attached after daemon restart")
                || lastSummary.localizedCaseInsensitiveContains("Runtime not attached after daemon restart"))
    }

    var isCompacting: Bool {
        status == .running && lastSummary.localizedCaseInsensitiveContains("compacting")
    }

    func elapsedDescription(now: Date = Date()) -> String {
        Self.formatElapsed(seconds: max(0, Int(now.timeIntervalSince(createdAt))))
    }

    func elapsedSinceUpdate(now: Date = Date()) -> String {
        Self.formatElapsed(seconds: max(0, Int(now.timeIntervalSince(updatedAt))))
    }

    func elapsedSinceLastRequest(now: Date = Date()) -> String {
        // Fall back to updatedAt when we never observed an explicit request timestamp
        // (resumed sessions reconstructed purely from logs); never to createdAt, which
        // would mis-stamp follow-ups on long-running sessions as hours-old.
        let reference = lastRequestAt ?? updatedAt
        return Self.formatElapsed(seconds: max(0, Int(now.timeIntervalSince(reference))))
    }

    private static func formatElapsed(seconds: Int) -> String {
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func compactCwd(_ cwd: String?) -> String? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardizedPath = NSString(string: trimmed).standardizingPath
        if standardizedPath == homePath { return "~" }
        if standardizedPath.hasPrefix(homePath + "/") {
            return "~" + String(standardizedPath.dropFirst(homePath.count))
        }
        return trimmed
    }
}

extension PickySessionListViewModel {
    typealias SessionCard = PickySessionCard
}

extension PickySessionNotificationPolicy.Input {
    init(card: PickySessionCard) {
        self.init(
            sessionID: card.id,
            title: card.title,
            status: card.status,
            lastSummary: card.lastSummary,
            pendingRequest: card.pendingExtensionUiRequest.map {
                PendingRequest(id: $0.id, title: $0.title, prompt: $0.prompt)
            },
            pinned: card.pinned
        )
    }
}

extension PickySessionCard {
    static func fromAgentSession(_ session: PickyAgentSession) -> Self {
        Self(session: session)
    }

    init(session: PickyAgentSession) {
        self.id = session.id
        self.title = session.title
        self.status = session.status
        self.cwd = session.cwd
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.lastSummary = session.lastSummary ?? ""
        self.thinkingPreview = session.thinkingPreview
        self.logPreview = session.logs.reversed().first(where: Self.isDisplayableLogPreview) ?? session.tools.last?.preview ?? ""
        self.lastRequestText = session.lastRequest?.text
        // The daemon's request record carries no wall-clock timestamp, so leave nil for
        // resumed sessions and let elapsedSinceLastRequest() fall back to updatedAt.
        self.lastRequestAt = nil
        self.tools = session.tools
        self.todoState = session.todoState
        self.subagentRuns = session.subagentRuns
        self.agentCycle = session.agentCycle
        self.asyncWorkSummary = session.asyncWorkSummary
        self.asyncTasks = session.asyncTasks
        self.completionTickets = session.completionTickets
        self.asyncControl = session.asyncControl
        self.artifacts = session.artifacts
        self.changedFiles = session.changedFiles
        self.messages = session.messages
        self.queuedSteers = session.queuedSteers
        self.queuedFollowUps = session.queuedFollowUps
        self.scheduledMessages = session.scheduledMessages
        self.steeringMode = session.steeringMode
        self.followUpMode = session.followUpMode
        self.activitySummary = session.activitySummary
        self.contextUsage = session.contextUsage
        self.currentAssistantRun = session.currentAssistantRun
        self.pendingExtensionUiRequest = session.pendingExtensionUiRequest
        self.piSessionFilePath = session.piSessionFilePath ?? session.logs.compactMap(Self.piSessionFilePath(fromLogLine:)).last
        self.notifyMainOnCompletion = session.notifyMainOnCompletion
        self.notifyMacOSOnCompletion = session.notifyMacOSOnCompletion
        self.pinned = session.pinned ?? false
        self.archived = session.archived ?? false
        self.archivedAt = session.archivedAt
    }

    static func piSessionFilePath(fromLogLine line: String) -> String? {
        for candidate in line.components(separatedBy: .newlines) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["pi session: ", "runtime reattached from pi session: ", "- Session file: "] {
                guard trimmed.hasPrefix(prefix) else { continue }
                let path = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if isUsablePiSessionFilePath(path) { return path }
            }
        }
        return nil
    }

    private static func isUsablePiSessionFilePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("(")
            && path != "ephemeral"
            && path != "unavailable"
    }

    /// Presentation-only filters over the daemon's human-readable log journal.
    /// Semantic state (`lastRequest`, `piSessionFilePath`) arrives as typed
    /// session fields; only preview selection still inspects log copy.
    static func isDisplayableLogPreview(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.hasPrefix("extension ui:") && !normalized.hasPrefix("extension ui answer:")
    }

    static func isRuntimeReattachLogLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("runtime reattached from pi session:")
    }
}

extension Array where Element == PickySessionCard {
    /// Time-based fallback ordering: newest first, ties broken by id. Used for
    /// archived sessions (which do not participate in manual reorder) and as
    /// the fallback for any active session ID that is not yet present in
    /// `manualOrder`.
    func sortedForHUD() -> [Element] {
        sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    /// Archived list ordering: most recently archived first. See
    /// `PickyArchivedSessionOrder`.
    func sortedForArchiveList() -> [Element] {
        sorted {
            PickyArchivedSessionOrder.precedes(
                .init(id: $0.id, archivedAt: $0.archivedAt, createdAt: $0.createdAt),
                .init(id: $1.id, archivedAt: $1.archivedAt, createdAt: $1.createdAt)
            )
        }
    }

    /// Order according to `manualOrder` (lower index = newer = visually-end
    /// slot after `sessions.reversed()`). IDs absent from `manualOrder` are
    /// appended after manually-ordered entries, sorted by `sortedForHUD()`.
    func sortedByManualOrder(_ manualOrder: [String]) -> [Element] {
        let positionByID: [String: Int] = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) })
        let manual = compactMap { card -> (Int, Element)? in
            guard let pos = positionByID[card.id] else { return nil }
            return (pos, card)
        }.sorted { $0.0 < $1.0 }.map { $0.1 }
        let leftovers = filter { positionByID[$0.id] == nil }.sortedForHUD()
        return manual + leftovers
    }
}

/// Archived Pickles are listed most recently archived first. Sessions without
/// an `archivedAt` (archived before the timestamp existed) sort after dated
/// ones, newest created first, with id as the final tie-breaker.
enum PickyArchivedSessionOrder {
    struct Key {
        let id: String
        let archivedAt: Date?
        let createdAt: Date
    }

    static func precedes(_ lhs: Key, _ rhs: Key) -> Bool {
        switch (lhs.archivedAt, rhs.archivedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            break
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }
}

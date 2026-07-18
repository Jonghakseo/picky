//
//  PickySessionCard.swift
//  Picky
//
//  HUD session projection value model plus its merge, parsing, and ordering
//  policies. This keeps daemon event orchestration out of the value model.
//

import Foundation

extension PickySessionListViewModel {
    struct SessionCard: Equatable, Identifiable {
        let id: String
        var title: String
        var status: PickySessionStatus
        var cwd: String?
        var createdAt: Date
        var updatedAt: Date
        var lastSummary: String
        var thinkingPreview: String?
        var logPreview: String
        var lastRequestText: String?
        // When the latest REQUEST row content was observed/sent locally. Used to render the
        // "X ago" stamp on that row independent of session.createdAt or session.updatedAt;
        // updatedAt is bumped by every tool/log event so it cannot stand in.
        var lastRequestAt: Date?
        var tools: [PickyToolActivity]
        var todoState: PickyTodoState? = nil
        var artifacts: [PickyArtifact]
        var changedFiles: [PickyChangedFile]
        var messages: [PickySessionMessage]
        var queuedSteers: [PickyQueueItem]
        var queuedFollowUps: [PickyQueueItem]
        var steeringMode: PickyQueueMode
        var followUpMode: PickyQueueMode
        var activitySummary: PickyActivitySummary
        var lastTerminalSyncOutcome: PickyTerminalSessionSyncOutcome? = nil
        var contextUsage: PickyContextUsage? = nil
        var currentAssistantRun: PickyAssistantRunMetadata? = nil
        var pendingExtensionUiRequest: PickyExtensionUiRequest?
        var piSessionFilePath: String?
        var notifyMainOnCompletion: Bool?
        var pinned: Bool
        /// Daemon-side archive flag mirrored from `PickyAgentSession.archived`.
        /// Snapshot hydration hoists this into the local `manuallyArchivedSessionIDs`
        /// UserDefaults so a Picky restart with cleared local state still partitions
        /// archived Pickles correctly. Live `sessionUpdated` events keep using the
        /// local intent set to avoid mid-flight unarchive flicker.
        var archived: Bool
        var hasRuntimeDetachedFollowUpRejection: Bool
        var isMainAgentHandoff: Bool

        var activeTool: PickyToolActivity? {
            tools.last { $0.isActive }
        }

        /// Active tool first, then the most recent tool started inside the given
        /// turn time-range. Used by the live tool indicator so it does not
        /// blink during the gap between successive tool calls (thinking /
        /// streaming periods carry no `isActive` tool).
        func mostRecentTool(after turnStart: Date) -> PickyToolActivity? {
            if let active = activeTool { return active }
            return tools.last { tool in
                guard let started = tool.startedAt else { return false }
                return started >= turnStart
            }
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
}

extension PickySessionListViewModel.SessionCard {
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
        self.lastRequestText = Self.lastRequestText(from: session.logs)
        // Logs do not carry per-line wall-clock timestamps, so leave nil for resumed sessions
        // and let elapsedSinceLastRequest() fall back to updatedAt.
        self.lastRequestAt = nil
        self.tools = session.tools
        self.todoState = session.todoState
        self.artifacts = session.artifacts
        self.changedFiles = session.changedFiles
        self.messages = session.messages
        self.queuedSteers = session.queuedSteers
        self.queuedFollowUps = session.queuedFollowUps
        self.steeringMode = session.steeringMode
        self.followUpMode = session.followUpMode
        self.activitySummary = session.activitySummary
        self.contextUsage = session.contextUsage
        self.currentAssistantRun = session.currentAssistantRun
        self.pendingExtensionUiRequest = session.pendingExtensionUiRequest
        self.piSessionFilePath = session.piSessionFilePath ?? session.logs.compactMap(Self.piSessionFilePath(fromLogLine:)).last
        self.notifyMainOnCompletion = session.notifyMainOnCompletion
        self.pinned = session.pinned ?? false
        self.archived = session.archived ?? false
        self.hasRuntimeDetachedFollowUpRejection = session.logs.contains(where: Self.isRuntimeDetachedFollowUpRejection)
        self.isMainAgentHandoff = session.logs.contains(where: Self.isMainAgentHandoffLogLine)
    }

    func merged(with incoming: Self, preserveConversationState: Bool = false) -> Self {
        var result = incoming
        let didReplacePiSession = incoming.piSessionFilePath != nil && incoming.piSessionFilePath != piSessionFilePath
        let didResetPiSession = incoming.representsFreshPiSessionReset(comparedTo: self)
        let shouldCarryPreviousSessionState = !didReplacePiSession && !didResetPiSession
        if shouldCarryPreviousSessionState && !status.canTransition(to: incoming.status) {
            result.status = status
        }
        if shouldCarryPreviousSessionState && result.logPreview.isEmpty { result.logPreview = logPreview }
        if shouldCarryPreviousSessionState && result.lastSummary.isEmpty { result.lastSummary = lastSummary }
        // thinkingPreview is daemon-authoritative just like pendingExtensionUiRequest: the daemon
        // explicitly drops it (`patch.thinkingPreview = undefined`) on terminal status transitions
        // and on extension UI answer, so an incoming `nil` means "thinking is over". Falling back
        // to the existing value would pin the previous "Thinking: ..." text to the card and let
        // it briefly flash again the next time the session re-enters `.running` after a follow-up.
        if shouldCarryPreviousSessionState && result.lastRequestText == nil { result.lastRequestText = lastRequestText }
        if shouldCarryPreviousSessionState && result.lastRequestAt == nil { result.lastRequestAt = lastRequestAt }
        if shouldCarryPreviousSessionState && result.tools.isEmpty { result.tools = tools }
        if shouldCarryPreviousSessionState && result.artifacts.isEmpty { result.artifacts = artifacts }
        if shouldCarryPreviousSessionState && result.changedFiles.isEmpty { result.changedFiles = changedFiles }
        if preserveConversationState && shouldCarryPreviousSessionState {
            // After the daemon starts sending granular conversation events, intermediate
            // sessionUpdated snapshots are still emitted for status/log/tool patches. Those
            // snapshots can legitimately represent a transient state between queue removal,
            // user_text materialization, thinking flushes, and final status, so letting them
            // replace the incrementally rendered conversation makes pending/user/thinking
            // bubbles disappear and reappear during follow-up and Working ↔ Done transitions.
            // Reconnect/sessionSnapshot still hydrates these fields fully; only live
            // sessionUpdated merges preserve the incremental render state.
            result.messages = messages
            result.queuedSteers = queuedSteers
            result.queuedFollowUps = queuedFollowUps
            result.steeringMode = steeringMode
            result.followUpMode = followUpMode
            result.activitySummary = activitySummary
        }
        // pendingExtensionUiRequest is authoritative on the daemon side: every sessionUpdated
        // carries the full session, so an incoming `nil` means the daemon has explicitly cleared
        // the request (answered, cancelled, timed out, dropped on reattach). Falling back to the
        // existing value would resurrect the form after the user submits — a sessionUpdated that
        // was queued before the answer was processed (e.g. emitted by a concurrent tool/thinking
        // patch) lands after the local clear and re-attaches REQUEST_A; the post-answer snapshot
        // then carries `nil`, and the fallback would restore REQUEST_A, leaving the askUserQuestion
        // form stuck on screen. Trust the incoming value instead.
        if result.piSessionFilePath == nil { result.piSessionFilePath = piSessionFilePath }
        if result.currentAssistantRun == nil { result.currentAssistantRun = currentAssistantRun }
        if result.notifyMainOnCompletion == nil { result.notifyMainOnCompletion = notifyMainOnCompletion }
        result.hasRuntimeDetachedFollowUpRejection = result.hasRuntimeDetachedFollowUpRejection || hasRuntimeDetachedFollowUpRejection
        result.isMainAgentHandoff = result.isMainAgentHandoff || isMainAgentHandoff
        return result
    }

    private func representsFreshPiSessionReset(comparedTo previous: Self) -> Bool {
        guard piSessionFilePath != nil else { return false }
        guard status == .waiting_for_input else { return false }
        guard lastSummary == "Ready for instructions" else { return false }
        guard pendingExtensionUiRequest == nil else { return false }
        guard messages.isEmpty, queuedSteers.isEmpty, queuedFollowUps.isEmpty else { return false }
        guard tools.isEmpty, artifacts.isEmpty, changedFiles.isEmpty else { return false }
        guard todoState?.tasks.isEmpty != false else { return false }
        return !previous.messages.isEmpty
            || !previous.queuedSteers.isEmpty
            || !previous.queuedFollowUps.isEmpty
            || !previous.tools.isEmpty
            || previous.todoState?.tasks.isEmpty == false
            || !previous.artifacts.isEmpty
            || !previous.changedFiles.isEmpty
            || previous.lastRequestText != nil
            || !previous.logPreview.isEmpty
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

    static func isDisplayableLogPreview(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.hasPrefix("extension ui:") && !normalized.hasPrefix(PickyLogPrefixes.extensionAnswer.trimmingCharacters(in: .whitespaces))
    }

    static func isRuntimeReattachLogLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("runtime reattached from pi session:")
    }


    static func isMainAgentHandoffLogLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix(PickyLogPrefixes.handoff)
    }

    static func lastRequestText(from logs: [String]) -> String? {
        logs.reversed().compactMap(requestText(fromLogLine:)).first
    }

    static func requestText(fromLogLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [PickyLogPrefixes.steer, PickyLogPrefixes.followUp, PickyLogPrefixes.handoff, PickyLogPrefixes.extensionAnswer] {
            if trimmed.hasPrefix(prefix) {
                return normalizedRequestText(String(trimmed.dropFirst(prefix.count)))
            }
        }

        let transcriptPrefix = "source transcript:"
        if line.hasPrefix(transcriptPrefix) {
            return normalizedRequestText(String(line.dropFirst(transcriptPrefix.count)))
        }
        return nil
    }

    private static func normalizedRequestText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isRuntimeDetachedFollowUpRejection(_ line: String) -> Bool {
        (line.localizedCaseInsensitiveContains("follow-up rejected:") || line.localizedCaseInsensitiveContains("steer rejected:"))
            && line.localizedCaseInsensitiveContains("Runtime session is not attached after daemon restart")
    }
}

extension Array where Element == PickySessionListViewModel.SessionCard {
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

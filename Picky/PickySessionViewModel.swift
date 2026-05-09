//
//  PickySessionViewModel.swift
//  Picky
//
//  Long-running session state for the Picky HUD.
//

import AppKit
import Combine
import Foundation
import UserNotifications

protocol PickyNotificationDelivering: AnyObject {
    func deliver(title: String, body: String, identifier: String)
}

final class PickyNoopNotificationCenter: PickyNotificationDelivering {
    private(set) var delivered: [(title: String, body: String, identifier: String)] = []

    func deliver(title: String, body: String, identifier: String) {
        delivered.append((title, body, identifier))
    }
}

final class PickySystemNotificationCenter: PickyNotificationDelivering {
    func deliver(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        let request = makeRequest(title: title, body: body, identifier: identifier)
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.add(request, to: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        print("⚠️ Picky notification authorization failed: \(error.localizedDescription)")
                    }
                    guard granted else {
                        print("⚠️ Picky notification skipped: authorization denied")
                        return
                    }
                    Self.add(request, to: center)
                }
            case .denied:
                print("⚠️ Picky notification skipped: authorization denied")
            @unknown default:
                print("⚠️ Picky notification skipped: unsupported authorization status")
            }
        }
    }

    private func makeRequest(title: String, body: String, identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private static func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) {
        center.add(request) { error in
            if let error {
                print("⚠️ Picky notification delivery failed: \(error.localizedDescription)")
            }
        }
    }
}

enum PickySessionListViewModelError: LocalizedError, Equatable {
    case emptyFollowUp
    case noSessionSelected
    case missingReport
    case missingPiSessionFile

    var errorDescription: String? {
        switch self {
        case .emptyFollowUp: "Steer message cannot be empty"
        case .noSessionSelected: "No session selected for steering"
        case .missingReport: "Report is not available yet"
        case .missingPiSessionFile: "Pi session file is not available yet"
        }
    }
}

protocol PickyClipboardWriting {
    func copy(_ text: String)
}

struct PickyPasteboardClipboardWriter: PickyClipboardWriting {
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct PickyComposerDraftRequest: Equatable, Identifiable {
    let id: String
    let text: String
}

@MainActor
final class PickySessionListViewModel: ObservableObject {
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
        var hasRuntimeDetachedFollowUpRejection: Bool
        var isMainAgentHandoff: Bool

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

    @Published private(set) var sessions: [SessionCard] = []
    @Published private(set) var archivedSessions: [SessionCard] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var hoveredVoiceFollowUpSessionID: String?
    @Published private(set) var activeVoiceFollowUpSessionID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastOpenedArtifactPath: String?
    @Published private(set) var slashCommandsBySessionID: [String: [PickySlashCommand]] = [:]
    @Published private(set) var composerDraftRequestsBySessionID: [String: PickyComposerDraftRequest] = [:]
    @Published private(set) var pendingDoneFlashSessionIDs: Set<String> = []
    @Published private(set) var isLoadingInitialSessionSnapshot = true

    var selectedSession: SessionCard? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    private let client: any PickyAgentClient
    private let notificationCenter: PickyNotificationDelivering
    private let notificationPreferencesProvider: PickyNotificationPreferencesProviding
    private let selectionStore: PickySessionSelectionStoring
    private let archiveStore: PickySessionArchiveStoring
    private let artifactPathValidator: PickyArtifactPathValidator
    private let clipboardWriter: PickyClipboardWriting
    private let terminalPresenter: PickyTerminalOverlayPresenting
    private let terminalSessionSyncer: PickyTerminalSessionSyncing
    private let reportPresenter: PickyReportPresenting
    private let toolHistoryPresenter: PickyToolHistoryPresenting
    private let generatedReportDirectory: URL
    private var eventTask: Task<Void, Never>?
    private var voiceFollowUpTargetCancellable: AnyCancellable?
    private var deliveredNotificationKeys = Set<String>()
    private var slashCommandRequestedSessionIDs = Set<String>()
    private var lastIncrementalSeqBySessionID: [String: Int] = [:]
    private var hasExplicitSelection = false

    init(
        client: any PickyAgentClient,
        notificationCenter: PickyNotificationDelivering = PickySystemNotificationCenter(),
        notificationPreferencesProvider: PickyNotificationPreferencesProviding = PickyNotificationPreferencesStore(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        archiveStore: PickySessionArchiveStoring = PickyUserDefaultsSessionArchiveStore.shared,
        artifactPathValidator: PickyArtifactPathValidator = PickyArtifactPathValidator(appSupportRoot: PickyAppSupport.defaultRoot()),
        clipboardWriter: PickyClipboardWriting = PickyPasteboardClipboardWriter(),
        terminalPresenter: PickyTerminalOverlayPresenting? = nil,
        terminalSessionSyncer: PickyTerminalSessionSyncing = PickyPiSessionFileSyncer(),
        reportPresenter: PickyReportPresenting? = nil,
        toolHistoryPresenter: PickyToolHistoryPresenting? = nil,
        generatedReportDirectory: URL = PickyAppSupport.defaultRoot().appendingPathComponent("GeneratedReports", isDirectory: true)
    ) {
        self.client = client
        self.notificationCenter = notificationCenter
        self.notificationPreferencesProvider = notificationPreferencesProvider
        self.selectionStore = selectionStore
        self.archiveStore = archiveStore
        self.artifactPathValidator = artifactPathValidator
        self.clipboardWriter = clipboardWriter
        self.terminalPresenter = terminalPresenter ?? PickyTerminalOverlayPresenter.shared
        self.terminalSessionSyncer = terminalSessionSyncer
        self.reportPresenter = reportPresenter ?? PickyReportViewerPresenter.shared
        self.toolHistoryPresenter = toolHistoryPresenter ?? PickyToolHistoryPresenter.shared
        self.generatedReportDirectory = generatedReportDirectory
        self.selectedSessionID = selectionStore.selectedSessionID
        self.hoveredVoiceFollowUpSessionID = selectionStore.hoveredVoiceFollowUpSessionID
        self.hasExplicitSelection = self.selectedSessionID != nil
        self.voiceFollowUpTargetCancellable = NotificationCenter.default.publisher(for: .pickyVoiceFollowUpTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.setActiveVoiceFollowUpSessionID(notification.userInfo?[PickyVoiceFollowUpTargetNotification.sessionIDKey] as? String)
            }
    }

    func start() {
        pickySessionLog("viewModel start")
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                self.apply(event)
            }
        }
        Task { await client.connect() }
    }

    func stop() {
        pickySessionLog("viewModel stop")
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
    }

    func select(sessionID: String?) {
        pickySessionLog("select requested session=\(sessionID ?? "default")")
        hasExplicitSelection = sessionID != nil
        if let sessionID, sessions.contains(where: { $0.id == sessionID }) {
            selectedSessionID = sessionID
            selectionStore.selectedSessionID = sessionID
        } else {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
    }

    func submit(transcript: String, context: PickyContextPacket) async throws {
        pickySessionLog("submit context=\(context.id) source=\(context.source) transcriptChars=\(transcript.count)")
        _ = try await client.submit(PickyAgentSubmission(transcript: transcript, context: context))
    }

    func createEmptyPickleSession(cwd: String) async throws {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = PickyContextPacket(
            id: "context-\(UUID().uuidString)",
            source: "system",
            capturedAt: Date(),
            transcript: nil,
            selectedText: nil,
            cwd: trimmedCwd.isEmpty ? nil : trimmedCwd,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: ["manualPickle=true"]
        )
        pickySessionLog("create empty Pickle session context=\(context.id) cwd=\(context.cwd ?? "none")")
        do {
            try await client.send(PickyCommandEnvelope(type: .createEmptyPickleSession, context: context))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Forks the Pickle session at `sessionID` into a brand-new sibling that resumes from a
    /// snapshot of its Pi transcript. Daemon-side rejects when the source has no Pi session file
    /// or is not yet attached to a runtime; we surface that error via `lastError` like the rest
    /// of the lifecycle commands here.
    func duplicate(sessionID: String) async throws {
        pickySessionLog("duplicate session=\(sessionID)")
        do {
            try await client.send(PickyCommandEnvelope(type: .duplicatePickleSession, sessionId: sessionID))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func beginHoveredVoiceFollowUp(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        hoveredVoiceFollowUpSessionID = sessionID
        selectionStore.hoveredVoiceFollowUpSessionID = sessionID
        pickySessionLog("voice follow-up hovered session=\(sessionID)")
    }

    func endHoveredVoiceFollowUp(sessionID: String) {
        guard hoveredVoiceFollowUpSessionID == sessionID else { return }
        hoveredVoiceFollowUpSessionID = nil
        selectionStore.hoveredVoiceFollowUpSessionID = nil
        pickySessionLog("voice follow-up hover cleared session=\(sessionID)")
    }

    func ensureSlashCommandsLoaded(sessionID: String) {
        guard slashCommandsBySessionID[sessionID] == nil else { return }
        guard !slashCommandRequestedSessionIDs.contains(sessionID) else { return }
        slashCommandRequestedSessionIDs.insert(sessionID)
        pickySessionLog("slash commands requested session=\(sessionID)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(PickyCommandEnvelope(type: .listSlashCommands, sessionId: sessionID))
            } catch {
                slashCommandRequestedSessionIDs.remove(sessionID)
                lastError = error.localizedDescription
            }
        }
    }

    func slashCommandSuggestions(for text: String, sessionID: String, limit: Int = PickySlashCommandAutocompletePolicy.maxSuggestions) -> [PickySlashCommand] {
        PickySlashCommandAutocompletePolicy.suggestions(for: text, commands: slashCommandsBySessionID[sessionID] ?? [], limit: limit)
    }

    func hasLoadedSlashCommands(sessionID: String) -> Bool {
        slashCommandsBySessionID[sessionID] != nil
    }

    func composerDraftRequest(for sessionID: String) -> PickyComposerDraftRequest? {
        composerDraftRequestsBySessionID[sessionID]
    }

    func consumeComposerDraftRequest(sessionID: String, requestID: String) {
        guard composerDraftRequestsBySessionID[sessionID]?.id == requestID else { return }
        composerDraftRequestsBySessionID[sessionID] = nil
    }

    func markDoneFlashConsumed(sessionID: String) {
        pendingDoneFlashSessionIDs.remove(sessionID)
    }

    func followUp(text: String, sessionID: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Follow-up message cannot be empty"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = "No session selected for follow-up"
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("follow-up session=\(target) textChars=\(trimmed.count)")
        do {
            try await client.send(PickyCommandEnvelope(type: .followUp, sessionId: target, text: trimmed))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        let now = Date()
        update(sessionID: target) { card in
            card.lastRequestText = trimmed
            card.lastRequestAt = now
            card.updatedAt = now
        }
        select(sessionID: target)
    }

    func steer(text: String, sessionID: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Steer message cannot be empty"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = "No session selected for steering"
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("steer session=\(target) textChars=\(trimmed.count)")
        do {
            try await client.send(PickyCommandEnvelope(type: .steer, sessionId: target, text: trimmed))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        let now = Date()
        update(sessionID: target) { card in
            card.lastRequestText = trimmed
            card.lastRequestAt = now
            card.updatedAt = now
        }
        select(sessionID: target)
    }

    func abort(sessionID: String) async throws {
        pickySessionLog("abort session=\(sessionID)")
        try await client.send(PickyCommandEnvelope(type: .abort, sessionId: sessionID))
        update(sessionID: sessionID) { card in
            if !card.status.isTerminal { card.status = .cancelled }
            card.updatedAt = Date()
        }
    }

    func clearQueue(sessionID: String, kind: PickyQueueClearKind) async throws {
        pickySessionLog("clear queue session=\(sessionID) kind=\(kind.rawValue)")
        try await client.send(PickyCommandEnvelope(type: .clearQueue, sessionId: sessionID, kind: kind))
    }

    func cycleThinkingLevel(sessionID: String) async throws {
        pickySessionLog("cycle thinking level session=\(sessionID)")
        do {
            try await client.send(PickyCommandEnvelope(type: .cycleSessionThinkingLevel, sessionId: sessionID))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func cycleModel(sessionID: String, direction: PickyModelCycleDirection = .forward) async throws {
        pickySessionLog("cycle model session=\(sessionID) direction=\(direction.rawValue)")
        do {
            try await client.send(PickyCommandEnvelope(type: .cycleSessionModel, sessionId: sessionID, direction: direction))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func setNotifyMainOnCompletion(sessionID: String, enabled: Bool) async throws {
        pickySessionLog("set notify main on completion session=\(sessionID) enabled=\(enabled)")
        try await client.send(PickyCommandEnvelope(type: .setNotifyMainOnCompletion, sessionId: sessionID, enabled: enabled))
        update(sessionID: sessionID) { card in
            card.notifyMainOnCompletion = enabled
            card.updatedAt = Date()
        }
    }

    func answerExtensionUi(sessionID: String, requestID: String, value: JSONValue) async throws {
        pickySessionLog("answer extension-ui session=\(sessionID) request=\(requestID)")
        try await client.send(PickyCommandEnvelope(type: .answerExtensionUi, sessionId: sessionID, requestId: requestID, value: value))
        update(sessionID: sessionID) { card in
            let now = Date()
            if let pending = card.pendingExtensionUiRequest, pending.id == requestID {
                if let summary = PickyAskUserQuestionFormState.summarizeAnswer(request: pending, value: value) {
                    card.lastRequestText = summary
                    card.lastRequestAt = now
                }
                card.pendingExtensionUiRequest = nil
                card.status = .running
                card.lastSummary = "Extension UI answered"
            }
            card.updatedAt = now
        }
    }

    func cancelExtensionUi(sessionID: String, requestID: String) async throws {
        try await answerExtensionUi(sessionID: sessionID, requestID: requestID, value: .object(["cancelled": .bool(true)]))
    }

    func openToolHistory(sessionID: String, scope: PickyToolHistoryScope = .session) {
        pickySessionLog("open tool history session=\(sessionID) scope=\(scope)")
        let title = sessionTitle(for: sessionID)
        toolHistoryPresenter.openHistory(sessionID: sessionID, title: title, scope: scope) { [weak self] in
            self?.toolsForSession(sessionID: sessionID) ?? []
        }
    }

    func openToolHistoryForCurrentTurn(sessionID: String) {
        let scope = currentTurnScope(for: sessionID)
        openToolHistory(sessionID: sessionID, scope: scope)
    }

    func openToolHistoryForAgentActivity(sessionID: String, messageID: String) {
        let scope = agentActivityScope(for: sessionID, messageID: messageID)
        openToolHistory(sessionID: sessionID, scope: scope)
    }

    private func sessionTitle(for sessionID: String) -> String {
        (sessions + archivedSessions).first(where: { $0.id == sessionID })?.title ?? "Session"
    }

    private func toolsForSession(sessionID: String) -> [PickyToolActivity]? {
        (sessions + archivedSessions).first(where: { $0.id == sessionID })?.tools
    }

    private func currentTurnScope(for sessionID: String) -> PickyToolHistoryScope {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }) else { return .session }
        let lastUserText = session.messages.last(where: { $0.kind == .userText })
        return .dateRange(start: lastUserText?.createdAt, end: nil)
    }

    private func agentActivityScope(for sessionID: String, messageID: String) -> PickyToolHistoryScope {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let activityIndex = session.messages.firstIndex(where: { $0.id == messageID && $0.kind == .agentActivity })
        else { return .session }
        let activity = session.messages[activityIndex]
        let priorMessages = session.messages.prefix(activityIndex)
        let priorUserText = priorMessages.last(where: { $0.kind == .userText })
        return .dateRange(start: priorUserText?.createdAt, end: activity.createdAt)
    }

    /// Opens a specific message's text content in the markdown report viewer.
    /// Used by the per-bubble hover-icon affordance so the user can expand any
    /// user request or agent reply (not just the latest one) into the full viewer.
    func openReport(sessionID: String, messageID: String) async throws {
        pickySessionLog("open report session=\(sessionID) message=\(messageID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let message = session.messages.first(where: { $0.id == messageID }),
              let markdown = message.openAsReportMarkdown else {
            lastError = "Message is not available as a report"
            throw PickySessionListViewModelError.missingReport
        }
        let titleSuffix: String
        let fileNamePrefix: String
        switch message.kind {
        case .userText:
            titleSuffix = "Request"
            fileNamePrefix = "request"
        case .agentText:
            titleSuffix = "Response"
            fileNamePrefix = "response"
        case .system:
            titleSuffix = "System message"
            fileNamePrefix = "system"
        default:
            titleSuffix = "Message"
            fileNamePrefix = "message"
        }
        do {
            try openGeneratedReport(
                windowKey: "\(sessionID):message:\(messageID)",
                title: "\(session.title) \u{2014} \(titleSuffix)",
                fileName: "\(fileNamePrefix)-\(sanitizedReportFileComponent(messageID)).md",
                markdown: markdown
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func openGeneratedReport(windowKey: String, title: String, fileName: String, markdown: String) throws {
        try FileManager.default.createDirectory(at: generatedReportDirectory, withIntermediateDirectories: true)
        let fileURL = generatedReportDirectory.appendingPathComponent(fileName, isDirectory: false)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        lastOpenedArtifactPath = fileURL.path
        try reportPresenter.openReport(sessionID: windowKey, title: title, fileURL: fileURL, markdown: markdown)
    }

    private func sanitizedReportFileComponent(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return sanitized.isEmpty ? "report" : String(sanitized.prefix(96))
    }

    func copyTerminalResumeCommand(sessionID: String) {
        pickySessionLog("copy terminal resume command session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        let command = PickyPiTerminalCommand.makeCliResumeCommand(sessionFilePath: piSessionFilePath, cwd: session.cwd)
        clipboardWriter.copy(command)
        lastError = nil
    }

    func openTerminalOverlay(sessionID: String) {
        pickySessionLog("open terminal overlay session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        // Earlier history pill stays clickable while the Pickle is still working: the overlay
        // launches its own `pi --session` process against the on-disk session file, so the user
        // gets a read view of the running transcript even though the daemon is still writing.

        let baselineSnapshot = terminalSessionSnapshotIfAvailable(sessionFilePath: piSessionFilePath)

        do {
            try terminalPresenter.openTerminal(
                sessionID: session.id,
                title: session.title,
                sessionFilePath: piSessionFilePath,
                cwd: session.cwd,
                onClose: { [weak self] in
                    self?.syncTerminalSessionOnce(sessionID: session.id, baselineSnapshot: baselineSnapshot)
                }
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func syncTerminalSessionOnce(sessionID: String, baselineSnapshot: PickyTerminalSessionSnapshot? = nil) {
        guard (sessions + archivedSessions).contains(where: { $0.id == sessionID }) else { return }
        let command = PickyCommandEnvelope(
            type: .syncTerminalSession,
            sessionId: sessionID,
            baselinePiMessageId: baselineSnapshot?.lastMessageId
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(command)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func terminalSessionSnapshotIfAvailable(sessionFilePath: String) -> PickyTerminalSessionSnapshot? {
        do {
            let snapshot = try terminalSessionSyncer.snapshot(sessionFilePath: sessionFilePath)
            return snapshot.isEmpty ? nil : snapshot
        } catch {
            return nil
        }
    }

    func archive(sessionID: String) {
        pickySessionLog("archive session=\(sessionID)")
        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.insert(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.insert(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        Task { try? await client.send(PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archived: true)) }

        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let archived = sessions.remove(at: index)
        if !archivedSessions.contains(where: { $0.id == sessionID }) {
            archivedSessions.append(archived)
        }
        archivedSessions = archivedSessions.sortedForHUD()
        if selectedSessionID == sessionID {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
        if hoveredVoiceFollowUpSessionID == sessionID {
            hoveredVoiceFollowUpSessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
        if activeVoiceFollowUpSessionID == sessionID {
            activeVoiceFollowUpSessionID = nil
        }
    }

    func unarchive(sessionID: String) {
        pickySessionLog("unarchive session=\(sessionID)")
        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.remove(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.remove(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        Task { try? await client.send(PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archived: false)) }

        guard let index = archivedSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let restored = archivedSessions.remove(at: index)
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions.append(restored)
        }
        sessions = sessions.sortedForHUD()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    func searchSessions(query: String) -> [SessionCard] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = sessions + archivedSessions
        guard !normalized.isEmpty else { return all }
        return all.filter { session in
            let haystack = [
                session.title,
                session.cwd,
                session.status.rawValue,
                session.lastSummary,
                session.linkBadgeArtifacts.compactMap { $0.url?.absoluteString }.joined(separator: " ")
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            return haystack.contains(normalized)
        }
    }

    private func apply(_ event: PickyClientEvent) {
        switch event {
        case .connected:
            pickySessionLog("client connected")
            if sessions.isEmpty && archivedSessions.isEmpty {
                isLoadingInitialSessionSnapshot = true
            }
            lastError = nil
            Task { try? await client.send(PickyCommandEnvelope(type: .listSessions)) }
        case .disconnected:
            pickySessionLog("client disconnected")
            lastError = "Disconnected from picky-agentd"
        case .recoverableError(let message):
            pickySessionLog("client recoverable error=\(message)")
            lastError = message
        case .protocolEvent(let envelope):
            apply(envelope.event)
        }
    }

    private func apply(_ event: PickyEvent) {
        switch event {
        case .sessionSnapshot(let snapshot):
            pickySessionLog("snapshot sessions=\(snapshot.count)")
            isLoadingInitialSessionSnapshot = false
            let previousCardsByID = Dictionary(uniqueKeysWithValues: (sessions + archivedSessions).map { ($0.id, $0) })
            let cards = snapshot.map(SessionCard.fromAgentSession)
            let archivedIDs = effectiveArchivedSessionIDs(for: cards)
            lastIncrementalSeqBySessionID = lastIncrementalSeqBySessionID.filter { sessionID, _ in cards.contains { $0.id == sessionID } }
            sessions = cards.filter { !archivedIDs.contains($0.id) }.sortedForHUD()
            archivedSessions = cards.filter { archivedIDs.contains($0.id) }.sortedForHUD()
            for card in cards {
                PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
                PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
            }
            pruneSlashCommandCache(knownSessionIDs: Set(cards.map(\.id)))
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
            syncActiveVoiceFollowUpAfterSessionListChange()
            for card in sessions {
                if previousCardsByID[card.id] == nil {
                    markNotificationDeliveredIfNeeded(for: card)
                } else {
                    deliverNotificationIfNeeded(for: card)
                }
            }
        case .sessionUpdated(let session):
            pickySessionLog("session updated session=\(session.id) status=\(session.status.rawValue)")
            let incomingCard = SessionCard.fromAgentSession(session)
            let previousCard = (sessions + archivedSessions).first { $0.id == session.id }
            if shouldInvalidateSlashCommandCache(previous: previousCard, incoming: incomingCard) {
                invalidateSlashCommandCache(sessionID: session.id)
            }
            upsert(
                incomingCard,
                preserveIncrementalConversationState: lastIncrementalSeqBySessionID[session.id] != nil
            )
        case .sessionLogAppended(let sessionId, let line):
            pickySessionLog("session log session=\(sessionId) lineChars=\(line.count)")
            if SessionCard.piSessionFilePath(fromLogLine: line) != nil || SessionCard.isRuntimeReattachLogLine(line) {
                invalidateSlashCommandCache(sessionID: sessionId)
            }
            update(sessionID: sessionId) { card in
                if SessionCard.isDisplayableLogPreview(line) {
                    card.logPreview = line
                }
                if SessionCard.isMainAgentHandoffLogLine(line) {
                    card.isMainAgentHandoff = true
                }
                if let piSessionFilePath = SessionCard.piSessionFilePath(fromLogLine: line) {
                    card.piSessionFilePath = piSessionFilePath
                }
                if let requestText = SessionCard.requestText(fromLogLine: line) {
                    card.lastRequestText = requestText
                    // Log lines arrive when the daemon broadcasts them, which is essentially
                    // when the request was issued — Date() here is close enough to the real
                    // wall-clock time of the request to drive the REQUEST row's stamp.
                    card.lastRequestAt = Date()
                }
                if SessionCard.isRuntimeDetachedFollowUpRejection(line) {
                    card.hasRuntimeDetachedFollowUpRejection = true
                }
                card.updatedAt = Date()
            }
        case .toolActivityUpdated(let sessionId, let tool):
            update(sessionID: sessionId) { card in
                if let toolIndex = card.tools.firstIndex(where: { $0.toolCallId == tool.toolCallId }) {
                    card.tools[toolIndex] = tool
                } else {
                    card.tools.append(tool)
                }
                card.logPreview = [tool.name, tool.preview].compactMap { $0 }.joined(separator: ": ")
                card.updatedAt = tool.endedAt ?? Date()
            }
        case .extensionUiRequest(let request):
            pickySessionLog("extension-ui request session=\(request.sessionId) request=\(request.id) method=\(request.method)")
            if handleFireAndForgetExtensionUiRequest(request) { return }
            update(sessionID: request.sessionId) { card in
                card.status = .waiting_for_input
                card.pendingExtensionUiRequest = request
                card.lastSummary = request.prompt ?? request.title ?? "Waiting for input"
                card.updatedAt = request.createdAt
            }
        case .artifactUpdated(let sessionId, let artifact):
            pickySessionLog("artifact updated session=\(sessionId) artifact=\(artifact.id) kind=\(artifact.kind)")
            update(sessionID: sessionId) { card in
                if let index = card.artifacts.firstIndex(where: { $0.id == artifact.id }) {
                    card.artifacts[index] = artifact
                } else {
                    card.artifacts.append(artifact)
                }
                card.updatedAt = artifact.updatedAt
            }
        case .slashCommandsSnapshot(let sessionId, let commands):
            pickySessionLog("slash commands snapshot session=\(sessionId) commands=\(commands.count)")
            slashCommandsBySessionID[sessionId] = commands
            slashCommandRequestedSessionIDs.insert(sessionId)
        case .sessionMessageAppended(let sessionId, let message, let seq):
            guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
            update(sessionID: sessionId) { card in
                card.messages.append(message)
                card.updatedAt = max(card.updatedAt, message.createdAt)
            }
        case .sessionMessageReplaced(let sessionId, let messageId, let message, let seq):
            guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
            update(sessionID: sessionId) { card in
                if let index = card.messages.firstIndex(where: { $0.id == messageId }) {
                    card.messages[index] = message
                } else {
                    card.messages.append(message)
                }
                card.updatedAt = max(card.updatedAt, message.createdAt)
            }
        case .sessionMessageRemoved(let sessionId, let messageId, let seq):
            guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
            update(sessionID: sessionId) { card in
                card.messages.removeAll { $0.id == messageId }
                card.updatedAt = Date()
            }
        case .sessionQueueUpdated(let sessionId, let steering, let followUp, let steeringMode, let followUpMode, let seq):
            guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
            update(sessionID: sessionId) { card in
                card.queuedSteers = steering
                card.queuedFollowUps = followUp
                if let steeringMode { card.steeringMode = steeringMode }
                if let followUpMode { card.followUpMode = followUpMode }
                card.updatedAt = Date()
            }
        case .sessionActivityUpdated(let sessionId, let activitySummary, let seq):
            guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
            update(sessionID: sessionId) { card in
                card.activitySummary = activitySummary
                card.updatedAt = Date()
            }
        case .error(let error):
            pickySessionLog("protocol error code=\(error.code) command=\(error.commandId ?? "none")")
            lastError = error.message
        case .terminalSessionSyncOutcome(let outcome):
            // Suppress the banner for the "nothing new" outcome — the user already
            // saw the terminal close cleanly, so a banner that just says "nothing
            // imported" is noise. The baseline-missing and imported-N-messages
            // outcomes still surface so the user notices a silent skip or a
            // successful import.
            guard PickyTerminalSyncOutcomePolicy.shouldSurfaceBanner(for: outcome) else { break }
            update(sessionID: outcome.sessionId) { card in
                card.lastTerminalSyncOutcome = outcome
                card.updatedAt = Date()
            }
        case .quickReply, .mainMessagesSnapshot, .mainMessageAppended, .mainAgentModelsSnapshot,
             .mainRealtimeStateChanged, .mainRealtimeInputTranscriptDelta, .mainRealtimeInputTranscriptCompleted,
             .mainRealtimeOutputAudioDelta, .mainRealtimeOutputAudioDone,
             .mainRealtimeOutputTranscriptDelta, .mainRealtimeOutputTranscriptCompleted, .mainRealtimeTurnDone,
             .pointerOverlayRequested, .hello, .unknown:
            break
        }
    }

    func dismissTerminalSyncOutcome(sessionID: String) {
        update(sessionID: sessionID) { card in
            card.lastTerminalSyncOutcome = nil
        }
    }

    private func handleFireAndForgetExtensionUiRequest(_ request: PickyExtensionUiRequest) -> Bool {
        switch request.method {
        case "set_editor_text":
            composerDraftRequestsBySessionID[request.sessionId] = PickyComposerDraftRequest(id: request.id, text: request.text ?? request.prompt ?? "")
            return true
        case "notify", "setStatus", "setWidget", "setTitle":
            return true
        default:
            return false
        }
    }

    private func acceptIncrementalEvent(sessionID: String, seq: Int) -> Bool {
        let lastSeq = lastIncrementalSeqBySessionID[sessionID] ?? 0
        guard seq > lastSeq else { return false }
        lastIncrementalSeqBySessionID[sessionID] = seq
        return true
    }

    private func shouldInvalidateSlashCommandCache(previous: SessionCard?, incoming: SessionCard) -> Bool {
        guard let previous else { return false }
        return previous.cwd != incoming.cwd
            || previous.piSessionFilePath != incoming.piSessionFilePath
            || (SessionCard.isRuntimeReattachLogLine(incoming.logPreview) && previous.logPreview != incoming.logPreview)
    }

    private func invalidateSlashCommandCache(sessionID: String) {
        slashCommandsBySessionID[sessionID] = nil
        slashCommandRequestedSessionIDs.remove(sessionID)
    }

    private func pruneSlashCommandCache(knownSessionIDs: Set<String>) {
        slashCommandsBySessionID = slashCommandsBySessionID.filter { knownSessionIDs.contains($0.key) }
        composerDraftRequestsBySessionID = composerDraftRequestsBySessionID.filter { knownSessionIDs.contains($0.key) }
        slashCommandRequestedSessionIDs = slashCommandRequestedSessionIDs.filter { knownSessionIDs.contains($0) }
        pendingDoneFlashSessionIDs = pendingDoneFlashSessionIDs.filter { knownSessionIDs.contains($0) }
        lastIncrementalSeqBySessionID = lastIncrementalSeqBySessionID.filter { knownSessionIDs.contains($0.key) }
    }

    private func effectiveArchivedSessionIDs(for _: [SessionCard]) -> Set<String> {
        let manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        if archiveStore.archivedSessionIDs != manuallyArchivedIDs {
            archiveStore.archivedSessionIDs = manuallyArchivedIDs
        }
        return manuallyArchivedIDs
    }

    private func upsert(_ card: SessionCard, preserveIncrementalConversationState: Bool = false) {
        let archivedIDs = effectiveArchivedSessionIDs(for: [card])
        let shouldArchive = archivedIDs.contains(card.id)
        let previousStatus = (sessions + archivedSessions).first(where: { $0.id == card.id })?.status
        PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
        PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
        var incoming = card
        if let existing = (sessions + archivedSessions).first(where: { $0.id == card.id }) {
            incoming = existing.merged(with: card, preserveConversationState: preserveIncrementalConversationState)
        }

        sessions.removeAll { $0.id == card.id }
        archivedSessions.removeAll { $0.id == card.id }
        if shouldArchive {
            archivedSessions.append(incoming)
        } else {
            sessions.append(incoming)
        }
        sessions = sessions.sortedForHUD()
        archivedSessions = archivedSessions.sortedForHUD()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
        if !shouldArchive {
            requestDoneFlashIfNeeded(previousStatus: previousStatus, incoming: incoming)
            deliverNotificationIfNeeded(for: incoming)
        }
    }

    private func requestDoneFlashIfNeeded(previousStatus: PickySessionStatus?, incoming: SessionCard) {
        // Only celebrate live transitions into completed. nil previousStatus means a brand-new
        // session arriving already as .completed (e.g. snapshot replay routed through upsert);
        // the user did not watch it transition so we skip the flash. Snapshot hydration writes
        // directly to `sessions`/`archivedSessions` without going through upsert, so historical
        // completed sessions never reach this code path on initial connect.
        guard incoming.status == .completed else { return }
        guard let previousStatus, previousStatus != .completed else { return }
        pendingDoneFlashSessionIDs.insert(incoming.id)
    }

    private func update(sessionID: String, mutate: (inout SessionCard) -> Void) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            var card = sessions[index]
            mutate(&card)
            sessions[index] = card
            sessions = sessions.sortedForHUD()
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
            syncActiveVoiceFollowUpAfterSessionListChange()
            deliverNotificationIfNeeded(for: card)
            return
        }
        guard let archivedIndex = archivedSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var archivedCard = archivedSessions[archivedIndex]
        mutate(&archivedCard)
        archivedSessions[archivedIndex] = archivedCard
        archivedSessions = archivedSessions.sortedForHUD()
    }

    private func syncSelectionAfterSessionListChange() {
        if hasExplicitSelection, let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            selectionStore.selectedSessionID = selectedSessionID
        } else {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
    }

    private func syncVoiceFollowUpAfterSessionListChange() {
        if let hoveredVoiceFollowUpSessionID, sessions.contains(where: { $0.id == hoveredVoiceFollowUpSessionID }) {
            selectionStore.hoveredVoiceFollowUpSessionID = hoveredVoiceFollowUpSessionID
        } else {
            hoveredVoiceFollowUpSessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
    }

    private func setActiveVoiceFollowUpSessionID(_ sessionID: String?) {
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        activeVoiceFollowUpSessionID = trimmed.isEmpty ? nil : trimmed
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    private func syncActiveVoiceFollowUpAfterSessionListChange() {
        if let activeVoiceFollowUpSessionID, sessions.contains(where: { $0.id == activeVoiceFollowUpSessionID }) {
            return
        }
        activeVoiceFollowUpSessionID = nil
    }

    private func defaultSelectionID() -> String? {
        sessions.sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }.first?.id
    }

    private func markNotificationDeliveredIfNeeded(for session: SessionCard) {
        guard let notification = notification(for: session) else { return }
        deliveredNotificationKeys.insert(notification.key)
    }

    private func deliverNotificationIfNeeded(for session: SessionCard) {
        guard let notification = notification(for: session) else {
            resetTerminalNotificationKeysIfNeeded(for: session)
            return
        }

        guard !deliveredNotificationKeys.contains(notification.key) else { return }
        deliveredNotificationKeys.insert(notification.key)
        notificationCenter.deliver(title: notification.title, body: notification.body, identifier: notification.key)
    }

    private func notification(for session: SessionCard) -> (key: String, title: String, body: String)? {
        let preferences = notificationPreferencesProvider.notificationPreferences
        let notification: (key: String, title: String, body: String)?
        switch session.status {
        case .completed:
            if session.pinned { return nil }
            guard preferences.notifyOnCompleted else { return nil }
            notification = ("\(session.id):completed", "분석이 끝났습니다", session.lastSummary.isEmpty ? session.title : session.lastSummary)
        case .failed:
            guard preferences.notifyOnFailed else { return nil }
            notification = ("\(session.id):failed", "Picky 작업이 실패했습니다", session.lastSummary.isEmpty ? "Open logs for details." : session.lastSummary)
        case .waiting_for_input:
            guard preferences.notifyOnWaitingForInput else { return nil }
            guard let pendingRequest = session.pendingExtensionUiRequest else { return nil }
            notification = ("\(session.id):waiting:\(pendingRequest.id)", "Picky가 입력을 기다립니다", pendingRequest.prompt ?? pendingRequest.title ?? session.title)
        case .queued, .running, .blocked, .cancelled:
            notification = nil
        }

        return notification
    }

    private func resetTerminalNotificationKeysIfNeeded(for session: SessionCard) {
        guard !session.status.isTerminal else { return }
        deliveredNotificationKeys.remove("\(session.id):completed")
        deliveredNotificationKeys.remove("\(session.id):failed")
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
        self.hasRuntimeDetachedFollowUpRejection = session.logs.contains(where: Self.isRuntimeDetachedFollowUpRejection)
        self.isMainAgentHandoff = session.logs.contains(where: Self.isMainAgentHandoffLogLine)
    }

    func merged(with incoming: Self, preserveConversationState: Bool = false) -> Self {
        var result = incoming
        if !status.canTransition(to: incoming.status) {
            result.status = status
        }
        if result.logPreview.isEmpty { result.logPreview = logPreview }
        if result.lastSummary.isEmpty { result.lastSummary = lastSummary }
        // thinkingPreview is daemon-authoritative just like pendingExtensionUiRequest: the daemon
        // explicitly drops it (`patch.thinkingPreview = undefined`) on terminal status transitions
        // and on extension UI answer, so an incoming `nil` means "thinking is over". Falling back
        // to the existing value would pin the previous "Thinking: ..." text to the card and let
        // it briefly flash again the next time the session re-enters `.running` after a follow-up.
        if result.lastRequestText == nil { result.lastRequestText = lastRequestText }
        if result.lastRequestAt == nil { result.lastRequestAt = lastRequestAt }
        if result.tools.isEmpty { result.tools = tools }
        if result.artifacts.isEmpty { result.artifacts = artifacts }
        if result.changedFiles.isEmpty { result.changedFiles = changedFiles }
        if preserveConversationState {
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

private extension Array where Element == PickySessionListViewModel.SessionCard {
    func sortedForHUD() -> [Element] {
        sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }
}

enum PickySlashCommandNavigationDirection {
    case up
    case down
}

enum PickySlashCommandAutocompletePolicy {
    static let maxSuggestions = 4

    static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let query = String(text.dropFirst())
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    static func suggestions(for text: String, commands: [PickySlashCommand], limit: Int = maxSuggestions) -> [PickySlashCommand] {
        guard let query = query(in: text) else { return [] }
        let scored = commands.enumerated().compactMap { index, command -> (score: Int, index: Int, command: PickySlashCommand)? in
            guard let score = score(commandName: command.name, query: query) else { return nil }
            return (score, index, command)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map(\.command)
    }

    static func completionText(for command: PickySlashCommand) -> String {
        "/\(command.name) "
    }

    static func clampedSelectionIndex(_ index: Int, suggestionCount: Int) -> Int {
        guard suggestionCount > 0 else { return 0 }
        return min(max(index, 0), suggestionCount - 1)
    }

    static func movedSelectionIndex(current index: Int, suggestionCount: Int, direction: PickySlashCommandNavigationDirection) -> Int {
        guard suggestionCount > 0 else { return 0 }
        let current = clampedSelectionIndex(index, suggestionCount: suggestionCount)
        switch direction {
        case .up:
            return current == 0 ? suggestionCount - 1 : current - 1
        case .down:
            return current == suggestionCount - 1 ? 0 : current + 1
        }
    }

    private static func score(commandName: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let name = commandName.lowercased()
        let needle = query.lowercased()
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 10 + max(0, name.count - needle.count) }
        if let range = name.range(of: needle) {
            let distance = name.distance(from: name.startIndex, to: range.lowerBound)
            return 100 + distance + max(0, name.count - needle.count)
        }
        return fuzzySubsequenceScore(name: name, query: needle)
    }

    private static func fuzzySubsequenceScore(name: String, query: String) -> Int? {
        let haystack = Array(name)
        let needle = Array(query)
        guard !needle.isEmpty else { return 0 }
        var searchStart = haystack.startIndex
        var gapPenalty = 0
        for character in needle {
            guard let match = haystack[searchStart...].firstIndex(of: character) else { return nil }
            gapPenalty += haystack.distance(from: searchStart, to: match)
            searchStart = haystack.index(after: match)
        }
        return 200 + gapPenalty + max(0, haystack.count - needle.count)
    }
}

enum PickyHUDStatusTone: Equatable {
    case inProgress
    case error
    case completed
    case other
}

extension PickySessionStatus {
    var hudTone: PickyHUDStatusTone {
        switch self {
        case .running:
            return .inProgress
        case .blocked, .failed:
            return .error
        case .completed:
            return .completed
        case .queued, .waiting_for_input, .cancelled:
            return .other
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running, .waiting_for_input, .blocked: false
        }
    }

    var hudPriority: Int {
        switch self {
        case .waiting_for_input: 0
        case .running: 1
        case .queued: 2
        case .blocked: 3
        case .failed: 4
        case .completed: 5
        case .cancelled: 6
        }
    }

    func canTransition(to next: PickySessionStatus) -> Bool {
        if self == next { return true }
        switch self {
        case .completed, .failed, .cancelled:
            return next == .queued || next == .running
        case .queued:
            return true
        case .running:
            return next != .queued
        case .waiting_for_input:
            return next != .queued
        case .blocked:
            return next != .queued
        }
    }
}

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

private func pickySessionLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    print("🧭 Picky session UI — \(message)")
}

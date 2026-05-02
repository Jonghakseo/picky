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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum PickySessionListViewModelError: LocalizedError, Equatable {
    case emptyFollowUp
    case noSessionSelected
    case missingReport
    case missingPiSessionFile

    var errorDescription: String? {
        switch self {
        case .emptyFollowUp: "Follow-up cannot be empty"
        case .noSessionSelected: "No session selected for follow-up"
        case .missingReport: "Report is not available yet"
        case .missingPiSessionFile: "Pi session file is not available yet"
        }
    }
}

protocol PickyTerminalResumeLaunching {
    func resume(sessionFilePath: String, cwd: String?) throws
}

struct PickyGhosttyResumeLauncher: PickyTerminalResumeLaunching {
    func resume(sessionFilePath: String, cwd: String?) throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil else {
            throw PickyGhosttyResumeLauncherError.ghosttyNotInstalled
        }

        let workingDirectory = Self.workingDirectory(from: cwd)
        let script = Self.makeAppleScript(sessionFilePath: sessionFilePath, workingDirectory: workingDirectory)

        var errorInfo: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&errorInfo) != nil else {
            throw PickyGhosttyResumeLauncherError.appleScriptFailed(errorInfo?.description ?? "Unknown AppleScript error")
        }
    }

    static func makeAppleScript(sessionFilePath: String, workingDirectory: String) -> String {
        let command = "cd \(Self.shellQuoted(workingDirectory)) && exec pi --session \(Self.shellQuoted(sessionFilePath))"
        return """
        set resumeCommand to \"\(Self.appleScriptString(command))\"
        set resumeWorkingDirectory to \"\(Self.appleScriptString(workingDirectory))\"
        set wasRunning to application \"Ghostty\" is running
        tell application \"Ghostty\"
          set resumeConfig to new surface configuration
          set initial working directory of resumeConfig to resumeWorkingDirectory
          set command of resumeConfig to resumeCommand
          set wait after command of resumeConfig to true
          if wasRunning and ((count of windows) is greater than 0) then
            set targetWindow to front window
            set resumedTab to new tab in targetWindow with configuration resumeConfig
            select tab resumedTab
          else
            set resumedWindow to new window with configuration resumeConfig
          end if
          activate
        end tell
        """
    }

    static func workingDirectory(from cwd: String?) -> String {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum PickyGhosttyResumeLauncherError: LocalizedError, Equatable {
    case ghosttyNotInstalled
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .ghosttyNotInstalled: "Ghostty is not installed."
        case .appleScriptFailed(let message): "Failed to open Ghostty: \(message)"
        }
    }
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
        var logPreview: String
        var tools: [PickyToolActivity]
        var artifacts: [PickyArtifact]
        var changedFiles: [PickyChangedFile]
        var pendingExtensionUiRequest: PickyExtensionUiRequest?
        var piSessionFilePath: String?

        var activeTool: PickyToolActivity? {
            tools.last { $0.isActive }
        }

        var toolCount: Int { tools.count }

        var isTerminal: Bool { status.isTerminal }

        var reportArtifact: PickyArtifact? {
            artifacts.first { $0.kind == "report" || $0.kind == "final_answer" }
        }

        var prArtifacts: [PickyArtifact] {
            artifacts.filter { artifact in
                artifact.kind == "pr" || artifact.url?.absoluteString.contains("/pull/") == true
            }
        }

        func elapsedDescription(now: Date = Date()) -> String {
            let seconds = max(0, Int(now.timeIntervalSince(createdAt)))
            if seconds < 60 { return "\(seconds)s" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m" }
            return "\(minutes / 60)h \(minutes % 60)m"
        }
    }

    @Published private(set) var sessions: [SessionCard] = []
    @Published private(set) var archivedSessions: [SessionCard] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var activeVoiceFollowUpSessionID: String?
    @Published private(set) var hoveredVoiceFollowUpSessionID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastOpenedArtifactPath: String?

    var selectedSession: SessionCard? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    private let client: any PickyAgentClient
    private let notificationCenter: PickyNotificationDelivering
    private let selectionStore: PickySessionSelectionStoring
    private let archiveStore: PickySessionArchiveStoring
    private let artifactPathValidator: PickyArtifactPathValidator
    private var eventTask: Task<Void, Never>?
    private var deliveredNotificationKeys = Set<String>()
    private var hasExplicitSelection = false

    init(
        client: any PickyAgentClient,
        notificationCenter: PickyNotificationDelivering = PickySystemNotificationCenter(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        archiveStore: PickySessionArchiveStoring = PickyUserDefaultsSessionArchiveStore.shared,
        artifactPathValidator: PickyArtifactPathValidator = PickyArtifactPathValidator(appSupportRoot: PickyAppSupport.defaultRoot())
    ) {
        self.client = client
        self.notificationCenter = notificationCenter
        self.selectionStore = selectionStore
        self.archiveStore = archiveStore
        self.artifactPathValidator = artifactPathValidator
        self.selectedSessionID = selectionStore.selectedSessionID
        self.activeVoiceFollowUpSessionID = selectionStore.activeVoiceFollowUpSessionID
        self.hoveredVoiceFollowUpSessionID = selectionStore.hoveredVoiceFollowUpSessionID
        self.hasExplicitSelection = self.selectedSessionID != nil
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

    func beginVoiceFollowUp(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        activeVoiceFollowUpSessionID = sessionID
        selectionStore.activeVoiceFollowUpSessionID = sessionID
        pickySessionLog("voice follow-up active session=\(sessionID)")
    }

    func endVoiceFollowUp(sessionID: String) {
        guard activeVoiceFollowUpSessionID == sessionID else { return }
        activeVoiceFollowUpSessionID = nil
        selectionStore.activeVoiceFollowUpSessionID = nil
        pickySessionLog("voice follow-up cleared session=\(sessionID)")
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

    func followUp(text: String, sessionID: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Follow-up cannot be empty"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = "No session selected for follow-up"
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("follow-up session=\(target) textChars=\(trimmed.count)")
        try await client.send(PickyCommandEnvelope(type: .followUp, sessionId: target, text: trimmed))
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

    func answerExtensionUi(sessionID: String, requestID: String, value: JSONValue) async throws {
        pickySessionLog("answer extension-ui session=\(sessionID) request=\(requestID)")
        try await client.send(PickyCommandEnvelope(type: .answerExtensionUi, sessionId: sessionID, requestId: requestID, value: value))
        update(sessionID: sessionID) { card in
            if card.pendingExtensionUiRequest?.id == requestID {
                card.pendingExtensionUiRequest = nil
                card.status = .running
                card.lastSummary = "Extension UI answered"
            }
            card.updatedAt = Date()
        }
    }

    func cancelExtensionUi(sessionID: String, requestID: String) async throws {
        try await answerExtensionUi(sessionID: sessionID, requestID: requestID, value: .object(["cancelled": .bool(true)]))
    }

    func openReport(sessionID: String, workspace: NSWorkspace = .shared) async throws {
        pickySessionLog("open report session=\(sessionID)")
        guard let artifact = sessions.first(where: { $0.id == sessionID })?.reportArtifact else {
            lastError = "Report is not available yet"
            throw PickySessionListViewModelError.missingReport
        }
        if let path = artifact.path {
            do {
                let url = try artifactPathValidator.validateReadableFile(path: path)
                lastOpenedArtifactPath = url.path
                workspace.open(url)
            } catch {
                lastError = error.localizedDescription
                throw error
            }
        } else {
            try await client.send(PickyCommandEnvelope(type: .openArtifact, sessionId: sessionID, artifactId: artifact.id))
        }
    }

    func copySummary(sessionID: String, pasteboard: NSPasteboard = .general) {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }) else { return }
        pasteboard.clearContents()
        pasteboard.setString(session.lastSummary.isEmpty ? session.title : session.lastSummary, forType: .string)
    }

    func resumeInGhostty(sessionID: String, launcher: PickyTerminalResumeLaunching = PickyGhosttyResumeLauncher()) {
        pickySessionLog("resume in Ghostty session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        do {
            try launcher.resume(sessionFilePath: piSessionFilePath, cwd: session.cwd)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archive(sessionID: String) {
        pickySessionLog("archive session=\(sessionID)")
        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.insert(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

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
        if activeVoiceFollowUpSessionID == sessionID {
            activeVoiceFollowUpSessionID = nil
            selectionStore.activeVoiceFollowUpSessionID = nil
        }
        if hoveredVoiceFollowUpSessionID == sessionID {
            hoveredVoiceFollowUpSessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
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
                session.prArtifacts.compactMap { $0.url?.absoluteString }.joined(separator: " ")
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            return haystack.contains(normalized)
        }
    }

    private func apply(_ event: PickyClientEvent) {
        switch event {
        case .connected:
            pickySessionLog("client connected")
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
            var archivedIDs = archiveStore.archivedSessionIDs
            let cards = snapshot.map(SessionCard.init(session:))
            for card in cards where card.isRuntimeDetachedRestoredSession {
                archivedIDs.insert(card.id)
            }
            archiveStore.archivedSessionIDs = archivedIDs
            sessions = cards.filter { !archivedIDs.contains($0.id) }.sortedForHUD()
            archivedSessions = cards.filter { archivedIDs.contains($0.id) }.sortedForHUD()
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
            sessions.forEach(deliverNotificationIfNeeded(for:))
        case .sessionUpdated(let session):
            pickySessionLog("session updated session=\(session.id) status=\(session.status.rawValue)")
            upsert(SessionCard(session: session))
        case .sessionLogAppended(let sessionId, let line):
            pickySessionLog("session log session=\(sessionId) lineChars=\(line.count)")
            update(sessionID: sessionId) { card in
                if SessionCard.isDisplayableLogPreview(line) {
                    card.logPreview = line
                }
                if let piSessionFilePath = SessionCard.piSessionFilePath(fromLogLine: line) {
                    card.piSessionFilePath = piSessionFilePath
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
        case .artifactOpened(_, _, let path):
            do {
                let url = try artifactPathValidator.validateReadableFile(path: path)
                lastOpenedArtifactPath = url.path
                NSWorkspace.shared.open(url)
            } catch {
                lastError = error.localizedDescription
            }
        case .error(let error):
            pickySessionLog("protocol error code=\(error.code) command=\(error.commandId ?? "none")")
            lastError = error.message
        case .quickReply, .hello, .unknown:
            break
        }
    }

    private func upsert(_ card: SessionCard) {
        var archivedIDs = archiveStore.archivedSessionIDs
        if card.isRuntimeDetachedRestoredSession {
            archivedIDs.insert(card.id)
            archiveStore.archivedSessionIDs = archivedIDs
        }
        let shouldArchive = archivedIDs.contains(card.id)
        var incoming = card
        if let existing = (sessions + archivedSessions).first(where: { $0.id == card.id }) {
            incoming = existing.merged(with: card)
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
        if !shouldArchive {
            deliverNotificationIfNeeded(for: incoming)
        }
    }

    private func update(sessionID: String, mutate: (inout SessionCard) -> Void) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            var card = sessions[index]
            mutate(&card)
            sessions[index] = card
            sessions = sessions.sortedForHUD()
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
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
        if let activeVoiceFollowUpSessionID, sessions.contains(where: { $0.id == activeVoiceFollowUpSessionID }) {
            selectionStore.activeVoiceFollowUpSessionID = activeVoiceFollowUpSessionID
        } else {
            activeVoiceFollowUpSessionID = nil
            selectionStore.activeVoiceFollowUpSessionID = nil
        }

        if let hoveredVoiceFollowUpSessionID, sessions.contains(where: { $0.id == hoveredVoiceFollowUpSessionID }) {
            selectionStore.hoveredVoiceFollowUpSessionID = hoveredVoiceFollowUpSessionID
        } else {
            hoveredVoiceFollowUpSessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
    }

    private func defaultSelectionID() -> String? {
        sessions.sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }.first?.id
    }

    private func deliverNotificationIfNeeded(for session: SessionCard) {
        let notification: (key: String, title: String, body: String)?
        switch session.status {
        case .completed:
            notification = ("\(session.id):completed", "분석이 끝났습니다", session.lastSummary.isEmpty ? session.title : session.lastSummary)
        case .failed:
            notification = ("\(session.id):failed", "Picky 작업이 실패했습니다", session.lastSummary.isEmpty ? "Open logs for details." : session.lastSummary)
        case .waiting_for_input:
            notification = ("\(session.id):waiting:\(session.pendingExtensionUiRequest?.id ?? "unknown")", "Picky가 입력을 기다립니다", session.pendingExtensionUiRequest?.prompt ?? session.pendingExtensionUiRequest?.title ?? session.title)
        case .queued, .running, .blocked, .cancelled:
            notification = nil
        }

        guard let notification, !deliveredNotificationKeys.contains(notification.key) else { return }
        deliveredNotificationKeys.insert(notification.key)
        notificationCenter.deliver(title: notification.title, body: notification.body, identifier: notification.key)
    }
}

private extension PickySessionListViewModel.SessionCard {
    init(session: PickyAgentSession) {
        self.id = session.id
        self.title = session.title
        self.status = session.status
        self.cwd = session.cwd
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.lastSummary = session.lastSummary ?? ""
        self.logPreview = session.logs.reversed().first(where: Self.isDisplayableLogPreview) ?? session.tools.last?.preview ?? ""
        self.tools = session.tools
        self.artifacts = session.artifacts
        self.changedFiles = session.changedFiles
        self.pendingExtensionUiRequest = session.pendingExtensionUiRequest
        self.piSessionFilePath = session.logs.compactMap(Self.piSessionFilePath(fromLogLine:)).last
    }

    var isRuntimeDetachedRestoredSession: Bool {
        status == .blocked && lastSummary.localizedCaseInsensitiveContains("Runtime not attached after daemon restart")
    }

    func merged(with incoming: Self) -> Self {
        var result = incoming
        if !status.canTransition(to: incoming.status) {
            result.status = status
        }
        if result.logPreview.isEmpty { result.logPreview = logPreview }
        if result.lastSummary.isEmpty { result.lastSummary = lastSummary }
        if result.tools.isEmpty { result.tools = tools }
        if result.artifacts.isEmpty { result.artifacts = artifacts }
        if result.changedFiles.isEmpty { result.changedFiles = changedFiles }
        if result.pendingExtensionUiRequest == nil { result.pendingExtensionUiRequest = pendingExtensionUiRequest }
        if result.piSessionFilePath == nil { result.piSessionFilePath = piSessionFilePath }
        return result
    }

    static func piSessionFilePath(fromLogLine line: String) -> String? {
        let prefix = "pi session: "
        guard line.hasPrefix(prefix) else { return nil }
        let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func isDisplayableLogPreview(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("extension ui:")
    }
}

private extension Array where Element == PickySessionListViewModel.SessionCard {
    func sortedForHUD() -> [Element] {
        sorted { lhs, rhs in
            if lhs.status.hudPriority != rhs.status.hudPriority {
                return lhs.status.hudPriority < rhs.status.hudPriority
            }
            return lhs.updatedAt > rhs.updatedAt
        }
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

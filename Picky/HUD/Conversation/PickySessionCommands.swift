//
//  PickySessionCommands.swift
//  Picky
//
//  Narrow imperative boundary for Conversation. Views observe projection stores;
//  commands remain an unobserved capability so unrelated session changes do not
//  invalidate the mounted conversation subtree.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
protocol PickySessionCommands: AnyObject, PickyGitChipActionViewModelDispatch {
    var activeVoiceFollowUpSessionID: String? { get }
    var screenContextTargetSessionID: String? { get }
    var screenContextTargetSticky: Bool { get }
    var voiceFollowUpHoverState: PickyVoiceFollowUpHoverState { get }
    var slashCommandsBySessionID: [String: [PickySlashCommand]] { get }
    var autocompleteEvents: PassthroughSubject<PickyAutocompleteClientEvent, Never> { get }

    func beginHoveredVoiceFollowUp(sessionID: String)
    func endHoveredVoiceFollowUp(sessionID: String)
    func toggleScreenContextTarget(sessionID: String)
    func armScreenContextTarget(sessionID: String, sticky: Bool)
    func clearScreenContextTarget(sessionID: String?)
    func ensureSlashCommandsLoaded(sessionID: String)
    func requestAutocompleteCapabilities(sessionID: String) -> String
    func queryAutocomplete(sessionID: String, generation: Int, lines: [String], cursorLine: Int, cursorCol: Int, draftRevision: Int, draftFingerprint: String, force: Bool) -> String
    func applyAutocomplete(sessionID: String, generation: Int, lines: [String], cursorLine: Int, cursorCol: Int, draftRevision: Int, draftFingerprint: String, item: PickyAutocompleteItem, prefix: String) -> String
    func slashCommandsIncludingRewindTreeCommand(_ commands: [PickySlashCommand], sessionID: String) -> [PickySlashCommand]
    func composerDraftRequest(for sessionID: String) -> PickyComposerDraftRequest?
    func consumeComposerDraftRequest(sessionID: String, requestID: String)
    func copyMessageText(_ text: String)
    func persistedComposerDraft(for sessionID: String) -> String
    func updateComposerDraft(_ draft: String, sessionID: String)
    func clearComposerDraft(sessionID: String)
    func persistedComposerAttachmentPaths(for sessionID: String) -> [String]
    func updateComposerAttachmentPaths(_ paths: [String], sessionID: String)
    func replaceComposerDraftText(_ text: String, sessionID: String)
    func clearQueueRestoringQueuedInputs(sessionID: String, kind: PickyQueueClearKind) async throws
    func clearQueue(sessionID: String, kind: PickyQueueClearKind) async throws
    func abortRestoringQueuedInputs(sessionID: String) async throws
    func steer(text: String, sessionID: String?) async throws
    func followUp(text: String, sessionID: String?) async throws
    func listSessionRuntimeOptions(sessionID: String) async throws -> PickySessionRuntimeOptions
    func setSessionModel(sessionID: String, provider: String, modelID: String) async throws
    func setSessionThinkingLevel(sessionID: String, thinkingLevel: PickyMainAgentThinkingLevel) async throws
    func cycleThinkingLevel(sessionID: String) async throws
    func cycleModel(sessionID: String, direction: PickyModelCycleDirection) async throws
    func setNotifyMainOnCompletion(sessionID: String, enabled: Bool) async throws
    func thinkingBlocksHidden(sessionID: String) -> Bool
    func isTodoProgressExpanded(sessionID: String, isComplete: Bool) -> Bool
    func setTodoProgressExpanded(_ isExpanded: Bool, sessionID: String)
    func isSubagentInvocationExpanded(invocationID: String, sessionID: String, isComplete: Bool) -> Bool
    func setSubagentInvocationExpanded(_ isExpanded: Bool, invocationID: String, sessionID: String)
    func openToolHistoryForCurrentTurn(sessionID: String)
    func openToolHistoryForAgentActivity(sessionID: String, messageID: String)
    func openReport(sessionID: String, messageID: String) async throws
    func openSubagentRunResponse(sessionID: String, invocationID: String, runId: Int) async throws
    func continueAfterRuntimeFailure(sessionID: String) async throws
    func retryAfterRuntimeRace(sessionID: String) async throws
    func dismissTerminalSyncOutcome(sessionID: String)
    func answerExtensionUi(sessionID: String, requestID: String, value: JSONValue) async throws
    func cancelExtensionUi(sessionID: String, requestID: String) async throws
    func isInlineTerminalMode(sessionID: String) -> Bool
    var inlineTerminalAttachmentStore: PickyTerminalAttachmentStore { get }
    func inlineTerminalSession(for session: PickyConversationSessionCard) -> PickyInlineTerminalSession?
    func disableInlineTerminalMode(sessionID: String)
    func isInlineTerminalAttachmentActive(sessionID: String, attachmentID: String) -> Bool
    func activateInlineTerminalAttachment(sessionID: String, attachmentID: String)
    func releaseInlineTerminalAttachment(sessionID: String, attachmentID: String)
    func loadRewindTargets(sessionID: String) async throws -> [PickyRewindTarget]
    func rewind(sessionID: String, toEntry entryID: String) async
    func openTerminalOverlay(sessionID: String)
    func toggleInlineTerminalMode(sessionID: String)
    func copyTerminalResumeCommand(sessionID: String)
    func syncTerminalSessionOnce(sessionID: String, baselineSnapshot: PickyTerminalSessionSnapshot?)
    func duplicate(sessionID: String) async throws
    func requestCompaction(sessionID: String) async
    func archive(sessionID: String)

    // HUD-only imperative bridge. These commands deliberately remain
    // unobserved; mounted HUD subtrees read their exact registry stores.
    func sessionCard(sessionID: String) -> PickyConversationSessionCard?
    func markDoneFlashConsumed(sessionID: String)
    func markSessionRead(sessionID: String)
    func markConversationCardOpened(sessionID: String)
    func markSessionClosed(sessionID: String)
    func sessionStore(sessionID: String) -> PickySessionStore?
    func toggleStickyScreenContextTarget(sessionID: String)
    func assignSessionToDockGroup(sessionID: String, groupID: String)
    func removeRecentPickleFolder(_ cwd: String)
    func pinPickleFolder(_ cwd: String)
    func unpinPickleFolder(_ cwd: String)
    func reorderPinnedPickleFolders(_ cwds: [String])
    func createEmptyPickleSession(cwd: String) async throws -> String
    func createDockGroup(name: String, withMemberIDs memberSessionIDs: [String]) -> String
    func renameDockGroup(id: String, to name: String)
    func setDockGroupColor(id: String, color: PickyDockGroupColor)
    func removeDockGroup(id: String, keepMembers: Bool)
    func moveSessionInDock(sessionID: String, to destination: PickyDockContainer)
    func moveDockGroup(id: String, toTopLevelIndex target: Int)
    func toggleThinkingBlocks(sessionID: String)
    func openLatestAgentResponseReport(sessionID: String) async throws
    func unarchive(sessionID: String)
    func requestOpenSession(sessionID: String, targetDisplayID: CGDirectDisplayID?)
    func requestCloseSession(sessionID: String, targetDisplayID: CGDirectDisplayID?)
    var shellTerminalAttachmentStore: PickyTerminalAttachmentStore { get }
    func shellTerminalSession(sessionID: String) -> PickyShellTerminalSession
    func isShellTerminalAttachmentActive(sessionID: String, attachmentID: String) -> Bool
    func activateShellTerminalAttachment(sessionID: String, attachmentID: String)
    func releaseShellTerminalAttachment(sessionID: String, attachmentID: String)
    func sessionDiffStore(for sessionID: String) -> PickySessionDiffStore
    func setSessionDiffVisible(_ isVisible: Bool, sessionID: String)
    func selectSessionDiffView(_ view: PickySessionDiffView, sessionID: String)
}

/// Lifecycle capability for AppKit's overlay manager. It is separate from the
/// mounted HUD command boundary so only the manager can start/stop the session
/// stream, while views never observe the global façade.
@MainActor
protocol PickyHUDSessionLifecycle: PickySessionCommands {
    var dockState: PickyHUDDockState { get }
    func unreadFocusShortcutTargetSessionID() -> String?
    func start()
    func stop()
}

/// Compatibility name used only at the Conversation boundary. The concrete
/// legacy façade remains outside HUD view declarations.
typealias PickyConversationSessionCard = PickySessionCard

@MainActor
enum PickyConversationStoreResolver {
    static func legacyStore(for card: PickySessionCard) -> PickySessionStore {
        let store = PickySessionStore(sessionID: card.id)
        store.replace(card: card)
        return store
    }

    static func card(from store: PickySessionStore) -> PickySessionCard? {
        store.materializedSessionCard()
    }
}

enum PickyConversationJournalPresentation: Equatable {
    case unavailable
    case empty
    case messages

    init(state: PickyProjectionSectionState<[PickySessionMessage]>) {
        switch state {
        case .unavailable:
            self = .unavailable
        case .loaded(let messages):
            self = messages.isEmpty ? .empty : .messages
        }
    }
}

/// Header-only projection. It deliberately reads the metadata owner and never
/// constructs the legacy SessionCard compatibility value.
@MainActor
struct PickyConversationHeaderProjection {
    let id: String
    let title: String
    let status: PickySessionStatus
    let lastSummary: String
    let contextUsage: PickyContextUsage?
    let currentAssistantRun: PickyAssistantRunMetadata?
    let piSessionFilePath: String?
    let notifyMainOnCompletion: Bool?

    init(metaStore: PickySessionMetaStore) {
        guard case .loaded(let metadata) = metaStore.metadataState else {
            preconditionFailure("Conversation header requires loaded metadata")
        }
        id = metadata.id
        title = metadata.title
        status = metadata.status
        lastSummary = metadata.lastSummary ?? ""
        contextUsage = metadata.contextUsage
        currentAssistantRun = metadata.currentAssistantRun
        piSessionFilePath = metadata.piSessionFilePath
        notifyMainOnCompletion = metadata.notifyMainOnCompletion
    }

    init(card: PickyConversationSessionCard) {
        id = card.id
        title = card.title
        status = card.status
        lastSummary = card.lastSummary
        contextUsage = card.contextUsage
        currentAssistantRun = card.currentAssistantRun
        piSessionFilePath = card.piSessionFilePath
        notifyMainOnCompletion = card.notifyMainOnCompletion
    }

    var canRequestDockCompaction: Bool {
        guard !(status == .running && lastSummary.localizedCaseInsensitiveContains("compacting")) else { return false }
        switch status {
        case .completed, .blocked, .failed, .cancelled: return true
        case .queued, .running, .waiting_for_input: return false
        }
    }
}

/// Composer-only projection. Membership/value reads stay limited to its own
/// metadata, journal, and queue owners; it never observes the session façade.
@MainActor
struct PickyConversationComposerProjection {
    let id: String
    let status: PickySessionStatus
    let lastSummary: String
    let notifyMainOnCompletion: Bool?
    let currentAssistantRun: PickyAssistantRunMetadata?
    let messageContext: PickyComposerMessageContext
    let queuedSteers: [PickyQueueItem]
    let queuedFollowUps: [PickyQueueItem]
    let steeringMode: PickyQueueMode
    let followUpMode: PickyQueueMode

    init(
        metaStore: PickySessionMetaStore,
        conversationStore: PickyConversationStore,
        queueStore: PickySessionQueueStore
    ) {
        guard case .loaded(let metadata) = metaStore.metadataState else {
            preconditionFailure("Conversation composer requires loaded metadata")
        }
        id = metadata.id
        status = metadata.status
        lastSummary = metadata.lastSummary ?? ""
        notifyMainOnCompletion = metadata.notifyMainOnCompletion
        currentAssistantRun = metadata.currentAssistantRun
        messageContext = conversationStore.composerMessageContext
        let queue = queueStore.queueState.loadedValue
        queuedSteers = queue?.steers ?? []
        queuedFollowUps = queue?.followUps ?? []
        let modes = queueStore.queueModes
        steeringMode = modes.steeringMode
        followUpMode = modes.followUpMode
    }

    init(card: PickyConversationSessionCard) {
        id = card.id
        status = card.status
        lastSummary = card.lastSummary
        notifyMainOnCompletion = card.notifyMainOnCompletion
        currentAssistantRun = card.currentAssistantRun
        messageContext = PickyComposerMessageContext(messages: card.messages)
        queuedSteers = card.queuedSteers
        queuedFollowUps = card.queuedFollowUps
        steeringMode = card.steeringMode
        followUpMode = card.followUpMode
    }

    var visibleQueue: PickyVisibleQueue {
        PickyVisibleQueue(
            queuedSteers: queuedSteers,
            queuedFollowUps: queuedFollowUps,
            committedUserMessages: messageContext.submittedUserMessages
        )
    }

    var isCompacting: Bool {
        status == .running && lastSummary.localizedCaseInsensitiveContains("compacting")
    }
}

/// Context-line-only projection. CWD/status metadata and artifact links have
/// separate owners; keeping them explicit prevents transcript changes from
/// invalidating this row.
@MainActor
struct PickyConversationContextProjection {
    let id: String
    let cwd: String?
    let status: PickySessionStatus
    let updatedAt: Date
    let artifacts: [PickyArtifact]

    init(metaStore: PickySessionMetaStore, artifactStore: PickySessionArtifactStore) {
        guard case .loaded(let metadata) = metaStore.metadataState else {
            preconditionFailure("Conversation context requires loaded metadata")
        }
        id = metadata.id
        cwd = metadata.cwd
        status = metadata.status
        updatedAt = metadata.updatedAt
        artifacts = artifactStore.artifactsState.loadedValue ?? []
    }

    init(card: PickyConversationSessionCard) {
        id = card.id
        cwd = card.cwd
        status = card.status
        updatedAt = card.updatedAt
        artifacts = card.artifacts
    }

    var compactCwdDescription: String? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardized = NSString(string: trimmed).standardizingPath
        if standardized == home { return "~" }
        if standardized.hasPrefix(home + "/") { return "~" + String(standardized.dropFirst(home.count)) }
        return trimmed
    }

    var linkBadgeArtifacts: [PickyArtifact] {
        artifacts.filter(\.isHUDLinkBadge)
    }

    func linkBadgeArtifacts(suppressingPullRequest pullRequest: PickyGitHubPullRequestStatus?) -> [PickyArtifact] {
        guard let pullRequest else { return linkBadgeArtifacts }
        let prRepositoryPath = Self.githubRepositoryPath(of: pullRequest.url)
        let prNumber = String(pullRequest.number)
        return linkBadgeArtifacts.filter { artifact in
            guard artifact.linkBadgeKind == .github,
                  let url = artifact.url,
                  url.pathComponents.contains("pull"),
                  Self.githubRepositoryPath(of: url) == prRepositoryPath,
                  artifact.githubIssueOrPullRequestNumber == prNumber else {
                return true
            }
            return false
        }
    }

    func linkBadgeText(for artifact: PickyArtifact) -> String? {
        guard let kind = artifact.linkBadgeKind else { return artifact.title }
        switch kind {
        case .github: return artifact.githubIssueOrPullRequestNumber.map { "#\($0)" } ?? artifact.title
        case .jira: return artifact.jiraIssueKey ?? artifact.title
        case .linear: return artifact.linearIssueKey ?? artifact.title
        case .slack, .notion, .sentry, .figma, .googleDocs, .googleSheets, .googleSlides, .googleDrive:
            let matching = linkBadgeArtifacts.filter { $0.linkBadgeKind == kind }
            guard matching.count > 1, let index = matching.firstIndex(where: { $0.id == artifact.id }) else { return nil }
            return "#\(index + 1)"
        case .generic:
            guard let host = artifact.url?.host?.lowercased() else { return nil }
            let matching = linkBadgeArtifacts.filter { $0.linkBadgeKind == .generic && $0.url?.host?.lowercased() == host }
            guard matching.count > 1, let index = matching.firstIndex(where: { $0.id == artifact.id }) else { return nil }
            return "#\(index + 1)"
        }
    }

    private static func githubRepositoryPath(of url: URL) -> String? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return "\(components[0])/\(components[1])".lowercased()
    }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}

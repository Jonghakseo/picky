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

struct PickyHUDOpenSessionRequest: Equatable {
    let id = UUID()
    let sessionID: String
    /// When set, only the HUD panel on this display should open the card.
    /// `nil` keeps the legacy behavior of opening on every display.
    var targetDisplayID: CGDirectDisplayID?
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
    case archivedSession
    case pickleRuntimeUnavailable
    case missingReport
    case missingPiSessionFile

    var errorDescription: String? {
        switch self {
        case .emptyFollowUp: "Steer message cannot be empty"
        case .noSessionSelected: "No session selected for steering"
        case .archivedSession: "Cannot steer an archived Pickle session"
        case .pickleRuntimeUnavailable: "Pickle runtime is unavailable"
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

protocol PickyRecentPickleFolderStoring {
    var recentPickleCwds: [String] { get }
    func record(cwd: String) throws -> [String]
    func remove(cwd: String) throws -> [String]
}

/// Read/write access to the persisted dock layout (groups + ordered
/// session/group refs). Production uses the same `settings.json` Picky has
/// always used; tests inject a fake implementation.
protocol PickyDockLayoutStoring {
    func load() -> PickyDockLayout
    func save(_ layout: PickyDockLayout) throws
}

struct PickyNoopDockLayoutStore: PickyDockLayoutStoring {
    func load() -> PickyDockLayout { .empty }
    func save(_ layout: PickyDockLayout) throws {}
}

struct PickySettingsDockLayoutStore: PickyDockLayoutStoring {
    var settingsStore: PickySettingsStore = PickySettingsStore()

    func load() -> PickyDockLayout {
        settingsStore.load().dockLayout
    }

    func save(_ layout: PickyDockLayout) throws {
        var settings = settingsStore.load()
        settings.dockLayout = layout
        try settingsStore.save(settings)
    }
}

struct PickyNoopRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    var recentPickleCwds: [String] { [] }
    func record(cwd: String) throws -> [String] { [] }
    func remove(cwd: String) throws -> [String] { [] }
}

struct PickySettingsRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    var settingsStore: PickySettingsStore = PickySettingsStore()

    var recentPickleCwds: [String] {
        settingsStore.load().recentPickleCwds
    }

    func record(cwd: String) throws -> [String] {
        var settings = settingsStore.load()
        settings.recordRecentPickleCwd(cwd)
        let updatedRecent = settings.normalizedPaths().recentPickleCwds
        try settingsStore.save(settings)
        return updatedRecent
    }

    func remove(cwd: String) throws -> [String] {
        var settings = settingsStore.load()
        settings.removeRecentPickleCwd(cwd)
        let updatedRecent = settings.normalizedPaths().recentPickleCwds
        try settingsStore.save(settings)
        return updatedRecent
    }
}

private struct PickyPendingFullscreenTurnSnapshot: Equatable {
    let id: UUID
    let cwd: String?
    let existingTurnIDs: Set<String>
    let snapshot: PickyFullscreenTurnGitSnapshot
}

/// Owns the "which Pickle is the cursor hovering over for voice follow-up"
/// flag in its own ObservableObject so the SwiftUI subscription is scoped to
/// the one view that actually reads it (the conversation header's pi-badge).
/// When this flag lived on `PickySessionListViewModel.@Published` directly,
/// every conversation subview observing the viewModel re-evaluated its body
/// on every cursor enter/exit of the card, which cascaded into per-bubble
/// markdown re-parsing and TextKit re-measurement and showed up as visible
/// hover lag.
@MainActor
final class PickyVoiceFollowUpHoverState: ObservableObject {
    @Published var sessionID: String?
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
    /// Voice-follow-up hover state lives in its own ObservableObject so views
    /// that don't read it (every conversation subview except the header) do
    /// not invalidate on cursor enter/exit of the card. Read-only forwarding
    /// getter `hoveredVoiceFollowUpSessionID` below keeps existing callers and
    /// tests working unchanged.
    let voiceFollowUpHoverState = PickyVoiceFollowUpHoverState()
    var hoveredVoiceFollowUpSessionID: String? { voiceFollowUpHoverState.sessionID }
    @Published private(set) var activeVoiceFollowUpSessionID: String?
    @Published private(set) var screenContextTargetSessionID: String?
    /// `true` when the armed Pickle should keep receiving Picky inputs until
    /// the user clicks it again or arms another. `false` is the legacy one-shot
    /// behavior. Always `false` when `screenContextTargetSessionID` is nil.
    @Published private(set) var screenContextTargetSticky: Bool = false
    /// Bumped to a fresh UUID every time the user arms a Pickle (one-shot or
    /// sticky). The HUD observes this token and collapses any expanded card so
    /// the user can immediately drive the armed Pickle from another app. Using
    /// a UUID rather than a flag avoids missed transitions when the user arms
    /// the same Pickle twice in a row from different entry points.
    @Published private(set) var screenContextArmCollapseToken: UUID = UUID()
    @Published private(set) var lastError: String?
    @Published private(set) var lastOpenedArtifactPath: String?
    @Published private(set) var slashCommandsBySessionID: [String: [PickySlashCommand]] = [:]
    /// Published mirror of `PickySessionComposerDraftController` request state.
    /// `PickyConversationComposerView` observes this dictionary with `.onChange`,
    /// so every controller mutation path must call `syncComposerDraftRequests()`.
    @Published private(set) var composerDraftRequestsBySessionID: [String: PickyComposerDraftRequest] = [:]
    @Published private(set) var thinkingBlocksHiddenBySessionID: [String: Bool] = [:]
    @Published private(set) var pendingDoneFlashSessionIDs: Set<String> = []
    /// Sessions whose detail card is currently presented as an inline Pi TUI instead of
    /// the SwiftUI chat/composer. This is intentionally UI-only state: the daemon and
    /// existing terminal overlay keep their current behavior.
    @Published private(set) var inlineTerminalSessionIDs: Set<String> = []
    /// The one inline terminal attachment that is allowed to render its SwiftTerm NSView.
    /// Other visible inline terminal cards stay in TUI mode but show an explanatory
    /// placeholder so AppKit never has to attach one terminal view to multiple parents.
    @Published private(set) var activeInlineTerminalAttachmentSessionID: String?
    private var inlineTerminalAttachmentCoordinator = PickyTerminalAttachmentCoordinator()
    /// Long-lived inline terminal sessions keyed by Pickle session ID. The terminal
    /// NSView/process is retained here so collapsing/reopening the HUD card reuses
    /// the same TUI instead of launching a fresh `pi --session` process.
    private var inlineTerminalSessionsBySessionID: [String: PickyInlineTerminalSession] = [:]
    /// Inline terminal sessions that have been closed from the UI but are still
    /// waiting for the `pi --session` process to exit/fallback before daemon sync.
    /// This mirrors the separate terminal overlay, which retains its model until
    /// the post-close sync callback fires.
    private var closingInlineTerminalSessionsByCloseID: [UUID: PickyInlineTerminalSession] = [:]
    /// The one local shell terminal add-on attachment that may render its AppKit
    /// terminal view. Multiple HUD panels can exist, but a single NSView cannot be
    /// attached to multiple parents at the same time.
    @Published private(set) var activeShellTerminalAttachmentSessionID: String?
    private var shellTerminalAttachmentCoordinator = PickyTerminalAttachmentCoordinator()
    /// Long-lived local shell terminals keyed by Pickle session ID. Hiding the
    /// add-on intentionally keeps the shell process alive so reopening resumes the
    /// same terminal session.
    private var shellTerminalSessionsBySessionID: [String: PickyShellTerminalSession] = [:]
    /// Sessions that finished or are waiting for input but have not been opened
    /// by the user yet. Lives on the view model (single source of truth) so all
    /// dock instances render the indicator in sync.
    @Published private(set) var unreadSessionIDs: Set<String> = []
    @Published private(set) var recentPickleCwds: [String]
    @Published private(set) var isLoadingInitialSessionSnapshot = true
    @Published private(set) var openSessionRequest: PickyHUDOpenSessionRequest?
    /// Fires every time a dock card is opened (the user clicked it to expand).
    /// Distinct from `selectedSessionID` so subscribers can react to repeated
    /// open gestures on the same session. Used by the onboarding flow to
    /// detect when the user inspects the demo Pickle's contents.
    @Published private(set) var lastOpenedSessionToken: UUID = UUID()
    private(set) var lastOpenedSessionID: String?
    /// Symmetric counterpart of `lastOpenedSessionToken`: fires every time the
    /// user toggles an open card back closed. Lets the onboarding flow split
    /// 'click to close' and 'long-press to archive' into separate beats.
    @Published private(set) var lastClosedSessionToken: UUID = UUID()
    private(set) var lastClosedSessionID: String?
    let fullscreenTurnSnapshotStore = PickyFullscreenTurnSnapshotStore()

    var selectedSession: SessionCard? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    private let client: any PickyAgentClient
    private let notificationCenter: PickyNotificationDelivering
    private let notificationPreferencesProvider: PickyNotificationPreferencesProviding
    private let selectionStore: PickySessionSelectionStoring
    private let archiveStore: PickySessionArchiveStoring
    private let manualOrderStore: PickySessionManualOrderStoring
    /// User-controlled dock order. Stored in the same direction as `sessions`
    /// (newest at index 0 = visually-end slot after `prefix.reversed()`). IDs
    /// not yet present here are auto-prepended when first observed, so brand
    /// new Pickles always land on the visually-end slot, regardless of any
    /// past drag the user did to existing sessions.
    private var manualOrder: [String] = []
    /// Persisted dock layout (groups + ordered top-level entries). Source of
    /// truth for the dock rail's visual ordering once any group has been
    /// created. Empty layout falls back to the legacy `manualOrder` flow.
    @Published private(set) var dockLayout: PickyDockLayout = .empty
    private let dockLayoutController: PickySessionDockLayoutController
    private let composerDraftController: PickySessionComposerDraftController
    private let recentPickleFolderStore: PickyRecentPickleFolderStoring
    private let artifactPathValidator: PickyArtifactPathValidator
    private let clipboardWriter: PickyClipboardWriting
    private let terminalPresenter: PickyTerminalOverlayPresenting
    private let terminalSessionSyncer: PickyTerminalSessionSyncing
    private let reportPresenter: PickyReportPresenting
    private let toolHistoryPresenter: PickyToolHistoryPresenting
    private let generatedReportDirectory: URL
    private let manualPickleChildSpawner: (any PickyManualPickleChildSpawning)?
    private let childSessionReleaser: (any PickyChildSessionReleasing)?
    private let archiveCommitDelayNanoseconds: UInt64
    private var archiveCommitTasks: [String: Task<Void, Never>] = [:]
    private var releasedArchivedChildSessionIDs = Set<String>()
    private let manualPickleSessionIdFactory: () -> String
    private var terminalSessionCommandChains: [String: Task<Void, Never>] = [:]
    private var terminalSessionCommandChainIDs: [String: UUID] = [:]
    private var eventTask: Task<Void, Never>?
    /// Safety watchdog that flips `isLoadingInitialSessionSnapshot` to `false`
    /// even when the daemon never delivers a `sessionSnapshot` (e.g. WebSocket
    /// upgrade silently fails, agentd crashes mid-handshake, or a protocol
    /// mismatch swallows the response). Without this fallback the dock UI used
    /// to stay stuck on the initial loading state, which manifested as an
    /// invisible HUD on environments where the handshake stalled (notably new
    /// macOS releases). The grace period matches the daemon's typical first
    /// snapshot turnaround with comfortable slack.
    private var initialSnapshotWatchdogTask: Task<Void, Never>?
    private let initialSnapshotWatchdogNanoseconds: UInt64 = 4_000_000_000
    /// Wallclock instant of the most recent `.connected` event. Used purely
    /// for diagnostics so we can report how long the daemon kept us waiting
    /// for the first `sessionSnapshot` after the WebSocket handshake
    /// completed — or, if the watchdog fires, exactly how long we waited
    /// before giving up.
    private var lastConnectedAt: Date?
    private var voiceFollowUpTargetCancellable: AnyCancellable?
    private var screenContextTargetCancellable: AnyCancellable?
    private var composerDraftAppendCancellable: AnyCancellable?
    private var deliveredNotificationKeys = Set<String>()
    private var slashCommandRequestedSessionIDs = Set<String>()
    private var slashCommandsEpochBySessionID: [String: UInt64] = [:]
    private var slashCommandRequestEpochByID: [String: UInt64] = [:]
    private var slashCommandRequestSessionByID: [String: String] = [:]
    private var lastIncrementalSeqBySessionID: [String: Int] = [:]
    private var pendingFullscreenTurnSnapshotsBySessionID: [String: [PickyPendingFullscreenTurnSnapshot]] = [:]
    private var pendingNewFullscreenTurnSnapshots: [PickyPendingFullscreenTurnSnapshot] = []
    private var hasExplicitSelection = false

    init(
        client: any PickyAgentClient,
        notificationCenter: PickyNotificationDelivering = PickySystemNotificationCenter(),
        notificationPreferencesProvider: PickyNotificationPreferencesProviding = PickyNotificationPreferencesStore(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        archiveStore: PickySessionArchiveStoring = PickyUserDefaultsSessionArchiveStore.shared,
        manualOrderStore: PickySessionManualOrderStoring = PickyUserDefaultsSessionManualOrderStore.shared,
        composerDraftStore: PickyComposerDraftStoring = PickyUserDefaultsComposerDraftStore.shared,
        composerAttachmentDraftStore: PickyComposerAttachmentDraftStoring = PickyUserDefaultsComposerAttachmentDraftStore.shared,
        recentPickleFolderStore: PickyRecentPickleFolderStoring = PickyNoopRecentPickleFolderStore(),
        dockLayoutStore: PickyDockLayoutStoring = PickyNoopDockLayoutStore(),
        artifactPathValidator: PickyArtifactPathValidator = PickyArtifactPathValidator(appSupportRoot: PickyAppSupport.defaultRoot()),
        clipboardWriter: PickyClipboardWriting = PickyPasteboardClipboardWriter(),
        terminalPresenter: PickyTerminalOverlayPresenting? = nil,
        terminalSessionSyncer: PickyTerminalSessionSyncing = PickyPiSessionFileSyncer(),
        reportPresenter: PickyReportPresenting? = nil,
        toolHistoryPresenter: PickyToolHistoryPresenting? = nil,
        generatedReportDirectory: URL = PickyAppSupport.defaultRoot().appendingPathComponent("GeneratedReports", isDirectory: true),
        manualPickleChildSpawner: (any PickyManualPickleChildSpawning)? = nil,
        childSessionReleaser: (any PickyChildSessionReleasing)? = nil,
        archiveCommitDelayNanoseconds: UInt64 = PickyHUDArchiveUndoToastPolicy.durationNanoseconds,
        manualPickleSessionIdFactory: @escaping () -> String = { "session-\(UUID().uuidString)" }
    ) {
        self.client = client
        self.notificationCenter = notificationCenter
        self.notificationPreferencesProvider = notificationPreferencesProvider
        self.selectionStore = selectionStore
        self.archiveStore = archiveStore
        self.manualOrderStore = manualOrderStore
        self.manualOrder = manualOrderStore.manualOrder
        self.composerDraftController = PickySessionComposerDraftController(
            draftStore: composerDraftStore,
            attachmentStore: composerAttachmentDraftStore
        )
        self.recentPickleFolderStore = recentPickleFolderStore
        self.recentPickleCwds = recentPickleFolderStore.recentPickleCwds
        let dockLayoutController = PickySessionDockLayoutController(store: dockLayoutStore) { error in
            pickySessionLog("dockLayout save failed: \(error)")
        }
        self.dockLayoutController = dockLayoutController
        self.dockLayout = dockLayoutController.layout
        self.artifactPathValidator = artifactPathValidator
        self.clipboardWriter = clipboardWriter
        self.terminalPresenter = terminalPresenter ?? PickyTerminalOverlayPresenter.shared
        self.terminalSessionSyncer = terminalSessionSyncer
        self.reportPresenter = reportPresenter ?? PickyReportViewerPresenter.shared
        self.toolHistoryPresenter = toolHistoryPresenter ?? PickyToolHistoryPresenter.shared
        self.generatedReportDirectory = generatedReportDirectory
        self.manualPickleChildSpawner = manualPickleChildSpawner
        self.childSessionReleaser = childSessionReleaser
        self.archiveCommitDelayNanoseconds = archiveCommitDelayNanoseconds
        self.manualPickleSessionIdFactory = manualPickleSessionIdFactory
        self.selectedSessionID = selectionStore.selectedSessionID
        self.voiceFollowUpHoverState.sessionID = selectionStore.hoveredVoiceFollowUpSessionID
        self.screenContextTargetSessionID = selectionStore.screenContextTargetSessionID
        self.screenContextTargetSticky = selectionStore.screenContextTargetSticky
        self.hasExplicitSelection = self.selectedSessionID != nil
        self.voiceFollowUpTargetCancellable = NotificationCenter.default.publisher(for: .pickyVoiceFollowUpTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.setActiveVoiceFollowUpSessionID(notification.userInfo?[PickyVoiceFollowUpTargetNotification.sessionIDKey] as? String)
            }
        self.screenContextTargetCancellable = NotificationCenter.default.publisher(for: .pickyScreenContextTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let sessionID = notification.userInfo?[PickyScreenContextTargetNotification.sessionIDKey] as? String
                let sticky = (notification.userInfo?[PickyScreenContextTargetNotification.stickyKey] as? Bool) ?? false
                self?.screenContextTargetSessionID = sessionID
                self?.screenContextTargetSticky = sessionID == nil ? false : sticky
            }
        self.composerDraftAppendCancellable = NotificationCenter.default.publisher(for: .pickyComposerDraftAppendRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let sessionID = notification.userInfo?[PickyComposerDraftAppendNotification.sessionIDKey] as? String,
                      let text = notification.userInfo?[PickyComposerDraftAppendNotification.textKey] as? String else { return }
                self?.appendComposerDraftText(text, sessionID: sessionID)
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
        initialSnapshotWatchdogTask?.cancel()
        initialSnapshotWatchdogTask = nil
        terminalSessionCommandChains.values.forEach { $0.cancel() }
        terminalSessionCommandChains.removeAll()
        terminalSessionCommandChainIDs.removeAll()
        client.disconnect()
    }

    private func armInitialSnapshotWatchdog() {
        initialSnapshotWatchdogTask?.cancel()
        let timeoutNanoseconds = initialSnapshotWatchdogNanoseconds
        initialSnapshotWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.isLoadingInitialSessionSnapshot else { return }
            let waitedMs = self.lastConnectedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            pickySessionLog("initial snapshot watchdog fired — unblocking dock UI without sessionSnapshot waitedSinceConnectedMs=\(waitedMs)")
            self.isLoadingInitialSessionSnapshot = false
            self.initialSnapshotWatchdogTask = nil
        }
    }

    private func disarmInitialSnapshotWatchdog() {
        initialSnapshotWatchdogTask?.cancel()
        initialSnapshotWatchdogTask = nil
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

    func requestOpenSession(sessionID: String, targetDisplayID: CGDirectDisplayID? = nil) {
        pickySessionLog("open session requested session=\(sessionID) display=\(targetDisplayID.map(String.init) ?? "all")")
        if sessions.contains(where: { $0.id == sessionID }) {
            select(sessionID: sessionID)
        }
        openSessionRequest = PickyHUDOpenSessionRequest(sessionID: sessionID, targetDisplayID: targetDisplayID)
    }

    func submit(transcript: String, context: PickyContextPacket) async throws {
        pickySessionLog("submit context=\(context.id) source=\(context.source) transcriptChars=\(transcript.count)")
        let pendingSnapshotID = await enqueueFullscreenTurnSnapshotForNewSession(cwd: context.cwd)
        do {
            _ = try await client.submit(PickyAgentSubmission(transcript: transcript, context: context))
        } catch {
            if let pendingSnapshotID {
                removePendingNewFullscreenTurnSnapshot(id: pendingSnapshotID)
            }
            throw error
        }
    }

    @discardableResult
    func createEmptyPickleSession(cwd: String) async throws -> String {
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
            let command = PickyCommandEnvelope(type: .createEmptyPickleSession, context: context)
            guard let manualPickleChildSpawner else {
                lastError = PickySessionListViewModelError.pickleRuntimeUnavailable.localizedDescription
                throw PickySessionListViewModelError.pickleRuntimeUnavailable
            }
            let childCwd = context.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            let sessionID = manualPickleSessionIdFactory()
            let childClient = try await manualPickleChildSpawner.spawnManualPickleChildClient(
                sessionId: sessionID,
                cwd: childCwd
            )
            try await childClient.send(command)
            lastError = nil
            if let cwd = context.cwd {
                recordRecentPickleFolder(cwd)
            }
            return sessionID
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func removeRecentPickleFolder(_ cwd: String) {
        do {
            recentPickleCwds = try recentPickleFolderStore.remove(cwd: cwd)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func recordRecentPickleFolder(_ cwd: String) {
        do {
            recentPickleCwds = try recentPickleFolderStore.record(cwd: cwd)
        } catch {
            // A Pickle already started successfully; keep the session creation result and
            // surface only the persistence failure for diagnostics.
            lastError = error.localizedDescription
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
        // Dedup before mutating @Published — SwiftUI onHover can fire repeated
        // hovering=true callbacks (e.g. on scroll or layout updates), and any
        // assignment to a @Published republishes regardless of equality. The
        // resulting objectWillChange cascade re-evaluates every HUD view that
        // observes the viewModel (conversation card/list/header/composer/etc.),
        // which in turn re-parses markdown for each bubble's isTruncated check
        // and re-measures TextKit. Guarding with a same-value early return
        // keeps the hover-driven cascade to one event per real state change.
        guard hoveredVoiceFollowUpSessionID != sessionID else { return }
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        voiceFollowUpHoverState.sessionID = sessionID
        selectionStore.hoveredVoiceFollowUpSessionID = sessionID
        pickySessionLog("voice follow-up hovered session=\(sessionID)")
    }

    func endHoveredVoiceFollowUp(sessionID: String) {
        guard hoveredVoiceFollowUpSessionID == sessionID else { return }
        voiceFollowUpHoverState.sessionID = nil
        selectionStore.hoveredVoiceFollowUpSessionID = nil
        pickySessionLog("voice follow-up hover cleared session=\(sessionID)")
    }

    func toggleScreenContextTarget(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTarget(sessionID: sessionID)
            return
        }
        armScreenContextTarget(sessionID: sessionID, sticky: false)
    }

    /// Promotes (or replaces) the armed Pickle. `sticky=true` keeps the Pickle
    /// armed across follow-up/steer dispatches; `sticky=false` matches the
    /// existing one-shot tap behavior. Used by the header long-press gesture.
    func armScreenContextTarget(sessionID: String, sticky: Bool) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sticky
        selectionStore.setScreenContextTarget(sessionID: sessionID, sticky: sticky)
        select(sessionID: sessionID)
        screenContextArmCollapseToken = UUID()
        pickySessionLog("screen context target armed session=\(sessionID) sticky=\(sticky)")
    }

    func clearScreenContextTarget(sessionID: String? = nil) {
        guard sessionID == nil || screenContextTargetSessionID == sessionID else { return }
        clearScreenContextTargetState()
    }

    /// Purge a locally-created demo session entirely — active list, archive,
    /// and every per-session tracking map. Used by the onboarding flow when
    /// the user skips mid-tour; we don't want the fake Pickle lingering in
    /// archive search where clicking it would do nothing because the daemon
    /// has never heard of it. Distinct from `archive(sessionID:)` (which
    /// sends a daemon command) since the demo session is purely client-side.
    func removeOnboardingDemoSession(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        archivedSessions.removeAll { $0.id == sessionID }
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys.remove("\(sessionID):completed")
        deliveredNotificationKeys.remove("\(sessionID):failed")
        thinkingBlocksHiddenBySessionID.removeValue(forKey: sessionID)
        slashCommandsBySessionID.removeValue(forKey: sessionID)
        slashCommandRequestedSessionIDs.remove(sessionID)
        slashCommandsEpochBySessionID.removeValue(forKey: sessionID)
        let removedRequestIDs = slashCommandRequestSessionByID.filter { $0.value == sessionID }.map(\.key)
        for requestID in removedRequestIDs {
            slashCommandRequestSessionByID.removeValue(forKey: requestID)
            slashCommandRequestEpochByID.removeValue(forKey: requestID)
        }
        lastIncrementalSeqBySessionID.removeValue(forKey: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTargetState()
        }
        reconcileDockLayout()
    }

    private func clearScreenContextTargetState() {
        guard screenContextTargetSessionID != nil || selectionStore.screenContextTargetSessionID != nil else { return }
        let cleared = screenContextTargetSessionID ?? selectionStore.screenContextTargetSessionID ?? "<nil>"
        screenContextTargetSessionID = nil
        screenContextTargetSticky = false
        selectionStore.setScreenContextTarget(sessionID: nil, sticky: false)
        pickySessionLog("screen context cleared session=\(cleared)")
    }

    func ensureSlashCommandsLoaded(sessionID: String) {
        guard slashCommandsBySessionID[sessionID] == nil else { return }
        guard !slashCommandRequestedSessionIDs.contains(sessionID) else { return }
        requestSlashCommands(sessionID: sessionID)
    }

    private func requestSlashCommands(sessionID: String) {
        slashCommandRequestedSessionIDs.insert(sessionID)
        let epoch = slashCommandsEpochBySessionID[sessionID] ?? 0
        let command = PickyCommandEnvelope(type: .listSlashCommands, sessionId: sessionID)
        slashCommandRequestEpochByID[command.id] = epoch
        slashCommandRequestSessionByID[command.id] = sessionID
        pickySessionLog("slash commands requested session=\(sessionID) epoch=\(epoch)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(command)
            } catch {
                slashCommandRequestEpochByID.removeValue(forKey: command.id)
                slashCommandRequestSessionByID.removeValue(forKey: command.id)
                if !slashCommandRequestSessionByID.values.contains(sessionID) {
                    slashCommandRequestedSessionIDs.remove(sessionID)
                }
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
        composerDraftController.request(for: sessionID)
    }

    func consumeComposerDraftRequest(sessionID: String, requestID: String) {
        composerDraftController.consumeRequest(sessionID: sessionID, requestID: requestID)
        syncComposerDraftRequests()
    }

    func persistedComposerDraft(for sessionID: String) -> String {
        composerDraftController.persistedDraft(for: sessionID)
    }

    func updateComposerDraft(_ draft: String, sessionID: String) {
        composerDraftController.updateDraft(draft, sessionID: sessionID)
    }

    /// Returns previously-persisted composer attachment paths for the session,
    /// filtered to those that still exist on disk. Dropped images live in the
    /// temp directory and may be reaped by the system between launches; the
    /// caller should treat missing paths as silently dropped.
    func persistedComposerAttachmentPaths(for sessionID: String) -> [String] {
        composerDraftController.persistedAttachmentPaths(for: sessionID)
    }

    func updateComposerAttachmentPaths(_ paths: [String], sessionID: String) {
        composerDraftController.updateAttachmentPaths(paths, sessionID: sessionID)
    }

    func clearComposerDraft(sessionID: String) {
        composerDraftController.clearDraft(sessionID: sessionID)
        syncComposerDraftRequests()
    }

    func appendComposerDraftText(_ text: String, sessionID: String) {
        guard composerDraftController.appendText(text, sessionID: sessionID) else { return }
        syncComposerDraftRequests()
        select(sessionID: sessionID)
    }

    func replaceComposerDraftText(_ text: String, sessionID: String) {
        guard composerDraftController.replaceText(text, sessionID: sessionID) else { return }
        syncComposerDraftRequests()
        select(sessionID: sessionID)
    }

    @discardableResult
    func restoreQueuedInputsToComposerDraft(sessionID: String, kind: PickyQueueClearKind = .all) -> Bool {
        guard let session = card(sessionID: sessionID),
              let queuedText = PickyQueuedInputDraftPolicy.queuedInputText(
                queuedSteers: session.queuedSteers,
                queuedFollowUps: session.queuedFollowUps,
                kind: kind
              )
        else { return false }
        appendComposerDraftText(queuedText, sessionID: sessionID)
        return true
    }

    func clearQueueRestoringQueuedInputs(sessionID: String, kind: PickyQueueClearKind) async throws {
        restoreQueuedInputsToComposerDraft(sessionID: sessionID, kind: kind)
        try await clearQueue(sessionID: sessionID, kind: kind)
    }

    func abortRestoringQueuedInputs(sessionID: String) async throws {
        let restoredQueuedInputs = restoreQueuedInputsToComposerDraft(sessionID: sessionID, kind: .all)
        if restoredQueuedInputs {
            try? await clearQueue(sessionID: sessionID, kind: .all)
        }
        try await abort(sessionID: sessionID)
    }

    private func syncComposerDraftRequests() {
        composerDraftRequestsBySessionID = composerDraftController.requestsBySessionID
    }

    func copyMessageText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardWriter.copy(text)
        lastError = nil
    }

    func thinkingBlocksHidden(sessionID: String) -> Bool {
        if let value = thinkingBlocksHiddenBySessionID[sessionID] { return value }
        guard let session = card(sessionID: sessionID) else { return false }
        return PickyPiSettingsReader.hideThinkingBlock(cwd: session.cwd)
    }

    func toggleThinkingBlocks(sessionID: String) {
        guard let session = card(sessionID: sessionID) else { return }
        let nextValue = !thinkingBlocksHidden(sessionID: sessionID)
        do {
            try PickyPiSettingsReader.setHideThinkingBlock(nextValue, cwd: session.cwd)
            lastError = nil
            syncThinkingBlockVisibility()
            pickySessionLog("thinking blocks hidden=\(nextValue) session=\(sessionID)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func markDoneFlashConsumed(sessionID: String) {
        pendingDoneFlashSessionIDs.remove(sessionID)
    }

    /// Called when the user opens a Pickle in any dock. Clears the unread badge
    /// across every HUD instance via the shared `@Published` set, and bumps
    /// `lastOpenedSessionToken` so non-HUD subscribers (e.g. onboarding) can
    /// react to the open gesture regardless of unread state.
    func markSessionRead(sessionID: String) {
        lastOpenedSessionID = sessionID
        lastOpenedSessionToken = UUID()
        guard unreadSessionIDs.contains(sessionID) else { return }
        unreadSessionIDs.remove(sessionID)
    }

    /// Mirror of `markSessionRead` for the close gesture: HUDView calls this
    /// when a previously-open dock card is toggled back closed. Onboarding
    /// uses it to split the open / close / archive CTAs into separate beats.
    func markSessionClosed(sessionID: String) {
        lastClosedSessionID = sessionID
        lastClosedSessionToken = UUID()
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
        guard sessions.contains(where: { $0.id == target }) else {
            if archivedSessions.contains(where: { $0.id == target }) {
                lastError = "Cannot follow up an archived Pickle session"
                throw PickySessionListViewModelError.archivedSession
            }
            lastError = "No session selected for follow-up"
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("follow-up session=\(target) textChars=\(trimmed.count)")
        let pendingSnapshotID = await enqueueFullscreenTurnSnapshot(sessionID: target)
        do {
            try await client.send(PickyCommandEnvelope(type: .followUp, sessionId: target, text: trimmed))
            lastError = nil
        } catch {
            if let pendingSnapshotID {
                removePendingFullscreenTurnSnapshot(sessionID: target, id: pendingSnapshotID)
            }
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
        guard sessions.contains(where: { $0.id == target }) else {
            if archivedSessions.contains(where: { $0.id == target }) {
                lastError = "Cannot steer an archived Pickle session"
                throw PickySessionListViewModelError.archivedSession
            }
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

    /// Re-sends the card's most recent user-request text via `steer` so the
    /// Pi SDK queues it behind the run that won the `activeRun` race. The
    /// failed card stays terminal until the supervisor revives it to
    /// `running` from inside `steer`, matching how the composer's `.steer`
    /// path handles a `cancelled`/`failed` session. Callers must already
    /// have confirmed the failure came from the recoverable race (see
    /// `PickyErrorBubbleView.isRecoverableRuntimeRace`); we still validate
    /// the target session is known and the text is non-empty here.
    func retryAfterRuntimeRace(sessionID: String) async throws {
        guard let card = sessions.first(where: { $0.id == sessionID }) ?? archivedSessions.first(where: { $0.id == sessionID }) else {
            lastError = "No session for retry"
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard let text = card.lastRequestText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            lastError = "No previous request text to retry"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        pickySessionLog("retry-after-race session=\(sessionID) textChars=\(text.count)")
        try await steer(text: text, sessionID: sessionID)
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

    private func card(sessionID: String) -> SessionCard? {
        (sessions + archivedSessions).first { $0.id == sessionID }
    }

    private func enqueueFullscreenTurnSnapshot(sessionID: String) async -> UUID? {
        guard let session = card(sessionID: sessionID), let snapshot = await captureFullscreenTurnSnapshot(cwd: session.cwd) else { return nil }
        let existingTurnIDs = Self.turnIDs(from: session.messages)
        let pending = PickyPendingFullscreenTurnSnapshot(id: UUID(), cwd: session.cwd, existingTurnIDs: existingTurnIDs, snapshot: snapshot)
        pendingFullscreenTurnSnapshotsBySessionID[sessionID, default: []].append(pending)
        return pending.id
    }

    private func enqueueFullscreenTurnSnapshotForNewSession(cwd: String?) async -> UUID? {
        guard let snapshot = await captureFullscreenTurnSnapshot(cwd: cwd) else { return nil }
        let pending = PickyPendingFullscreenTurnSnapshot(id: UUID(), cwd: cwd, existingTurnIDs: [], snapshot: snapshot)
        pendingNewFullscreenTurnSnapshots.append(pending)
        return pending.id
    }

    private func removePendingFullscreenTurnSnapshot(sessionID: String, id: UUID) {
        pendingFullscreenTurnSnapshotsBySessionID[sessionID]?.removeAll { $0.id == id }
        if pendingFullscreenTurnSnapshotsBySessionID[sessionID]?.isEmpty == true {
            pendingFullscreenTurnSnapshotsBySessionID.removeValue(forKey: sessionID)
        }
    }

    private func removePendingNewFullscreenTurnSnapshot(id: UUID) {
        pendingNewFullscreenTurnSnapshots.removeAll { $0.id == id }
    }

    private func captureFullscreenTurnSnapshot(cwd: String?) async -> PickyFullscreenTurnGitSnapshot? {
        await PickyFullscreenTurnSnapshotCapturer.captureSnapshot(cwd: cwd)
    }

    private func bindPendingFullscreenTurnSnapshots(sessionID: String, messages: [PickySessionMessage]) {
        let turnIDs = messages
            .filter { $0.kind == .userText || $0.kind == .commandReceipt }
            .map(\.id)
        guard !turnIDs.isEmpty else { return }

        var recordedTurnIDs = Set(fullscreenTurnSnapshotStore.snapshots[sessionID]?.keys.map { $0 } ?? [])
        if var pending = pendingFullscreenTurnSnapshotsBySessionID[sessionID], !pending.isEmpty {
            var remaining: [PickyPendingFullscreenTurnSnapshot] = []
            for snapshot in pending {
                guard let turnID = turnIDs.first(where: { !recordedTurnIDs.contains($0) && !snapshot.existingTurnIDs.contains($0) }) else {
                    remaining.append(snapshot)
                    continue
                }
                fullscreenTurnSnapshotStore.record(sessionID: sessionID, turnID: turnID, snapshot: snapshot.snapshot)
                recordedTurnIDs.insert(turnID)
            }
            pendingFullscreenTurnSnapshotsBySessionID[sessionID] = remaining.isEmpty ? nil : remaining
        }

        guard !pendingNewFullscreenTurnSnapshots.isEmpty,
              fullscreenTurnSnapshotStore.snapshots[sessionID]?.isEmpty != false,
              let firstTurnID = turnIDs.first,
              !recordedTurnIDs.contains(firstTurnID) else { return }
        let cwd = card(sessionID: sessionID)?.cwd
        let pendingIndex = pendingNewFullscreenTurnSnapshots.firstIndex { pending in
            Self.cwdsMatch(pending.cwd, cwd)
        } ?? pendingNewFullscreenTurnSnapshots.indices.first
        guard let index = pendingIndex else { return }
        let pending = pendingNewFullscreenTurnSnapshots.remove(at: index)
        fullscreenTurnSnapshotStore.record(sessionID: sessionID, turnID: firstTurnID, snapshot: pending.snapshot)
    }

    private static func turnIDs(from messages: [PickySessionMessage]) -> Set<String> {
        Set(messages.filter { $0.kind == .userText || $0.kind == .commandReceipt }.map(\.id))
    }

    private static func cwdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == (rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private func sessionTitle(for sessionID: String) -> String {
        card(sessionID: sessionID)?.title ?? "Session"
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

    /// Opens the newest LLM response in the markdown report viewer. This backs
    /// the HUD's ⌘R shortcut so users can expand the latest reply without aiming
    /// for the hover-only bubble corner button.
    func openLatestAgentResponseReport(sessionID: String) async throws {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let messageID = session.latestAgentResponseReportMessageID else {
            lastError = "Latest response is not available as a report"
            throw PickySessionListViewModelError.missingReport
        }
        try await openReport(sessionID: sessionID, messageID: messageID)
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
            if message.notifyType != nil {
                titleSuffix = "Pi Extension Notice"
                fileNamePrefix = "notify"
            } else {
                titleSuffix = "System message"
                fileNamePrefix = "system"
            }
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

    func isInlineTerminalMode(sessionID: String) -> Bool {
        inlineTerminalSessionIDs.contains(sessionID)
    }

    func enableInlineTerminalMode(sessionID: String) {
        pickySessionLog("enable inline terminal session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              session.piSessionFilePath != nil else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        inlineTerminalSessionIDs.insert(sessionID)
        _ = inlineTerminalSession(for: session)
        endHoveredVoiceFollowUp(sessionID: sessionID)
        setTerminalSessionTailEnabled(sessionID: sessionID, enabled: true)
        lastError = nil
    }

    func disableInlineTerminalMode(sessionID: String) {
        pickySessionLog("disable inline terminal session=\(sessionID)")
        // Stop the daemon-side tail before draining the inline terminal so the final
        // `syncTerminalSession` reconcile (scheduled inside `closeInlineTerminalSession`)
        // doesn't race the tail watcher for the same JSONL entries.
        setTerminalSessionTailEnabled(sessionID: sessionID, enabled: false)
        inlineTerminalSessionIDs.remove(sessionID)
        removeVisibleInlineTerminalAttachments(sessionID: sessionID)
        endHoveredVoiceFollowUp(sessionID: sessionID)
        closeInlineTerminalSession(sessionID: sessionID)
    }

    /// Asks the daemon to start/stop tailing the Pi JSONL file for `sessionID`. Called whenever
    /// the user enters or leaves an inline TUI / Pi terminal overlay so the HUD dock icon keeps
    /// transitioning (`running` -> `completed`) even though agentd's own runtime is idle. Fire and
    /// forget: failures are logged at the daemon side and the HUD just degrades to the previous
    /// "frozen status until overlay close" behaviour.
    private func setTerminalSessionTailEnabled(sessionID: String, enabled: Bool) {
        enqueueTerminalSessionCommand(sessionID: sessionID) { [weak self] in
            await self?.sendTerminalSessionTailEnabled(sessionID: sessionID, enabled: enabled)
        }
    }

    private func enqueueTerminalSessionCommand(sessionID: String, operation: @escaping @MainActor () async -> Void) {
        let previous = terminalSessionCommandChains[sessionID]
        let chainID = UUID()
        terminalSessionCommandChainIDs[sessionID] = chainID
        let task = Task { [weak self, previous] in
            await previous?.value
            if !Task.isCancelled {
                await operation()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.terminalSessionCommandChainIDs[sessionID] == chainID else { return }
                self.terminalSessionCommandChains[sessionID] = nil
                self.terminalSessionCommandChainIDs[sessionID] = nil
            }
        }
        terminalSessionCommandChains[sessionID] = task
    }

    private func sendTerminalSessionTailEnabled(sessionID: String, enabled: Bool) async {
        let command = PickyCommandEnvelope(
            type: .setTerminalSessionTailEnabled,
            sessionId: sessionID,
            enabled: enabled
        )
        do {
            try await client.send(command)
        } catch {
            pickySessionLog("terminal tail toggle failed session=\(sessionID) enabled=\(enabled) error=\(error.localizedDescription)")
        }
    }

    func toggleInlineTerminalMode(sessionID: String) {
        if isInlineTerminalMode(sessionID: sessionID) {
            disableInlineTerminalMode(sessionID: sessionID)
        } else {
            enableInlineTerminalMode(sessionID: sessionID)
        }
    }

    func inlineTerminalSession(for session: SessionCard) -> PickyInlineTerminalSession? {
        guard inlineTerminalSessionIDs.contains(session.id) else { return nil }
        if let existing = inlineTerminalSessionsBySessionID[session.id] {
            return existing
        }
        guard let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return nil
        }
        let baselineSnapshot = terminalSessionSnapshotIfAvailable(sessionFilePath: piSessionFilePath)
        let inlineSession = PickyInlineTerminalSession(
            sessionID: session.id,
            title: session.title,
            sessionFilePath: piSessionFilePath,
            cwd: session.cwd,
            baselineSnapshot: baselineSnapshot,
            fontScalePersister: PickyTerminalFontScalePersister.defaultSettings()
        )
        inlineTerminalSessionsBySessionID[session.id] = inlineSession
        return inlineSession
    }

    func isInlineTerminalAttachmentActive(sessionID: String, attachmentID: String) -> Bool {
        inlineTerminalAttachmentCoordinator.isActive(sessionID: sessionID, attachmentID: attachmentID)
    }

    func activateInlineTerminalAttachment(sessionID: String, attachmentID: String) {
        inlineTerminalAttachmentCoordinator.activate(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: inlineTerminalSessionIDs
        )
        syncInlineTerminalAttachmentState()
    }

    func releaseInlineTerminalAttachment(sessionID: String, attachmentID: String) {
        inlineTerminalAttachmentCoordinator.release(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: inlineTerminalSessionIDs
        )
        syncInlineTerminalAttachmentState()
    }

    private func removeVisibleInlineTerminalAttachments(sessionID: String) {
        inlineTerminalAttachmentCoordinator.removeSession(
            sessionID: sessionID,
            eligibleSessionIDs: inlineTerminalSessionIDs
        )
        syncInlineTerminalAttachmentState()
    }

    private func syncInlineTerminalAttachmentState() {
        activeInlineTerminalAttachmentSessionID = inlineTerminalAttachmentCoordinator.activeSessionID
    }

    private func closeInlineTerminalSession(sessionID: String) {
        guard let inlineSession = inlineTerminalSessionsBySessionID.removeValue(forKey: sessionID) else { return }
        let closeID = UUID()
        closingInlineTerminalSessionsByCloseID[closeID] = inlineSession
        inlineSession.closeAndScheduleSync { [weak self] baselineSnapshot in
            guard let self else { return }
            syncTerminalSessionOnce(sessionID: sessionID, baselineSnapshot: baselineSnapshot)
            closingInlineTerminalSessionsByCloseID[closeID] = nil
        }
    }

    func shellTerminalSession(for session: SessionCard) -> PickyShellTerminalSession {
        if let existing = shellTerminalSessionsBySessionID[session.id] {
            return existing
        }
        let shellSession = PickyShellTerminalSession(
            sessionID: session.id,
            title: session.title,
            cwd: session.cwd,
            fontScalePersister: PickyTerminalFontScalePersister.defaultSettings()
        )
        shellTerminalSessionsBySessionID[session.id] = shellSession
        return shellSession
    }

    func isShellTerminalAttachmentActive(sessionID: String, attachmentID: String) -> Bool {
        shellTerminalAttachmentCoordinator.isActive(sessionID: sessionID, attachmentID: attachmentID)
    }

    func activateShellTerminalAttachment(sessionID: String, attachmentID: String) {
        shellTerminalAttachmentCoordinator.activate(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: shellTerminalEligibleSessionIDs
        )
        syncShellTerminalAttachmentState()
    }

    func releaseShellTerminalAttachment(sessionID: String, attachmentID: String) {
        shellTerminalAttachmentCoordinator.release(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: shellTerminalEligibleSessionIDs
        )
        syncShellTerminalAttachmentState()
    }

    private func removeVisibleShellTerminalAttachments(sessionID: String) {
        shellTerminalAttachmentCoordinator.removeSession(
            sessionID: sessionID,
            eligibleSessionIDs: shellTerminalEligibleSessionIDs
        )
        syncShellTerminalAttachmentState()
    }

    private var shellTerminalEligibleSessionIDs: Set<String> {
        Set((sessions + archivedSessions).map(\.id))
    }

    private func syncShellTerminalAttachmentState() {
        activeShellTerminalAttachmentSessionID = shellTerminalAttachmentCoordinator.activeSessionID
    }

    private func closeShellTerminalSession(sessionID: String) {
        removeVisibleShellTerminalAttachments(sessionID: sessionID)
        shellTerminalSessionsBySessionID.removeValue(forKey: sessionID)?.close()
    }

    func openTerminalOverlay(sessionID: String) {
        pickySessionLog("open terminal overlay session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        // The overlay launches its own `pi --session` process against the on-disk session
        // file, so the user gets a terminal view of the transcript even when the daemon is
        // still writing to it.

        let baselineSnapshot = terminalSessionSnapshotIfAvailable(sessionFilePath: piSessionFilePath)

        do {
            try terminalPresenter.openTerminal(
                sessionID: session.id,
                title: session.title,
                sessionFilePath: piSessionFilePath,
                cwd: session.cwd,
                onClose: { [weak self] in
                    guard let self else { return }
                    // Stop the daemon-side tail BEFORE the reconcile so we don't race the
                    // post-close `syncTerminalSession` for the same final JSONL entries.
                    self.setTerminalSessionTailEnabled(sessionID: session.id, enabled: false)
                    self.syncTerminalSessionOnce(sessionID: session.id, baselineSnapshot: baselineSnapshot)
                }
            )
            setTerminalSessionTailEnabled(sessionID: session.id, enabled: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func syncTerminalSessionOnce(sessionID: String, baselineSnapshot: PickyTerminalSessionSnapshot? = nil) {
        enqueueTerminalSessionCommand(sessionID: sessionID) { [weak self] in
            await self?.sendTerminalSessionSync(sessionID: sessionID, baselineSnapshot: baselineSnapshot)
        }
    }

    private func sendTerminalSessionSync(sessionID: String, baselineSnapshot: PickyTerminalSessionSnapshot? = nil) async {
        guard (sessions + archivedSessions).contains(where: { $0.id == sessionID }) else { return }
        let command = PickyCommandEnvelope(
            type: .syncTerminalSession,
            sessionId: sessionID,
            baselinePiMessageId: baselineSnapshot?.lastMessageId
        )
        do {
            try await client.send(command)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
        if isInlineTerminalMode(sessionID: sessionID) {
            disableInlineTerminalMode(sessionID: sessionID)
        }
        closeShellTerminalSession(sessionID: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.insert(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.insert(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        Task { try? await client.send(PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archived: true)) }

        scheduleArchiveCommit(sessionID: sessionID)

        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let archived = sessions.remove(at: index)
        if !archivedSessions.contains(where: { $0.id == sessionID }) {
            archivedSessions.append(archived)
        }
        archivedSessions = archivedSessions.sortedForHUD()
        // Keep manualOrder synced so the persisted array does not retain ids
        // outside both pools. Unarchive re-prepends the id to manualOrder, so
        // we intentionally drop the slot rather than try to remember it.
        applyManualOrderToActiveSessions()
        if selectedSessionID == sessionID {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
        if hoveredVoiceFollowUpSessionID == sessionID {
            voiceFollowUpHoverState.sessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
        if activeVoiceFollowUpSessionID == sessionID {
            activeVoiceFollowUpSessionID = nil
        }
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTarget(sessionID: sessionID)
        }
    }

    /// Tear down the child daemon once the archive undo window expires. Called from
    /// `archive(sessionID:)` and cancelled by `unarchive(sessionID:)` so users who tap Undo
    /// keep their child agentd alive.
    private func scheduleArchiveCommit(sessionID: String) {
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        let delay = archiveCommitDelayNanoseconds
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            guard self.archiveCommitTasks[sessionID] != nil else { return }
            self.archiveCommitTasks.removeValue(forKey: sessionID)
            guard let archivedSession = self.archivedSessions.first(where: { $0.id == sessionID }),
                  archivedSession.status.isTerminal
            else {
                pickySessionLog("archive-commit session=\(sessionID) keeping child for non-terminal Pickle")
                return
            }
            self.releaseArchivedTerminalChildIfCommitted(archivedSession)
        }
        archiveCommitTasks[sessionID] = task
    }

    private func releaseArchivedTerminalChildIfCommitted(_ session: SessionCard) {
        guard session.status.isTerminal else { return }
        guard archiveCommitTasks[session.id] == nil else { return }
        guard !releasedArchivedChildSessionIDs.contains(session.id) else { return }
        releasedArchivedChildSessionIDs.insert(session.id)
        pickySessionLog("archive-commit session=\(session.id) releasing terminal child")
        childSessionReleaser?.releaseChild(sessionId: session.id)
    }

    func unarchive(sessionID: String) {
        pickySessionLog("unarchive session=\(sessionID)")
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        releasedArchivedChildSessionIDs.remove(sessionID)
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
        // Only touch manualOrder if the user has already opted into manual
        // ordering by dragging at least once; otherwise let the historical
        // createdAt sort drive placement.
        if !manualOrder.isEmpty {
            manualOrder.removeAll { $0 == sessionID }
            manualOrder.insert(sessionID, at: 0)
            manualOrderStore.manualOrder = manualOrder
        }
        applyManualOrderToActiveSessions()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    /// Permanently delete every archived Pickle in one shot from the
    /// Settings → Pickle list header. Snapshots the current archived IDs
    /// up-front so concurrent restores/incoming events do not slip a row out
    /// from under the iteration, then funnels each ID through the existing
    /// single-row delete path so daemon validation, archive-store cleanup,
    /// and per-session map pruning all stay consistent. No-op when the
    /// archive is empty so a misrouted call (deep link, test, programmatic)
    /// never sends spurious deleteSession envelopes.
    func deleteAllArchivedSessions() {
        let ids = archivedSessions.map(\.id)
        guard !ids.isEmpty else { return }
        pickySessionLog("delete all archived sessions count=\(ids.count)")
        for sessionID in ids {
            deleteArchivedSession(sessionID: sessionID)
        }
    }

    /// Permanently delete an archived Pickle from both the local view model and the
    /// daemon's persisted session store. Triggered from Settings → Pickle. The
    /// daemon validates that the session is archived AND terminal AND has no live
    /// runtime handle; the UI only exposes the affordance for archived rows so a
    /// successful path is the only path the user ever sees.
    func deleteArchivedSession(sessionID: String) {
        pickySessionLog("delete archived session=\(sessionID)")
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        releasedArchivedChildSessionIDs.remove(sessionID)

        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.remove(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.remove(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        Task { try? await client.send(PickyCommandEnvelope(type: .deleteSession, sessionId: sessionID)) }

        // Mirror removeOnboardingDemoSession's cleanup: prune every per-session
        // map so a future incoming sessionUpdated for an unrelated session id
        // doesn't accidentally revive stale state for the deleted one.
        sessions.removeAll { $0.id == sessionID }
        archivedSessions.removeAll { $0.id == sessionID }
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys.remove("\(sessionID):completed")
        deliveredNotificationKeys.remove("\(sessionID):failed")
        thinkingBlocksHiddenBySessionID.removeValue(forKey: sessionID)
        slashCommandsBySessionID.removeValue(forKey: sessionID)
        slashCommandRequestedSessionIDs.remove(sessionID)
        slashCommandsEpochBySessionID.removeValue(forKey: sessionID)
        let removedRequestIDs = slashCommandRequestSessionByID.filter { $0.value == sessionID }.map(\.key)
        for requestID in removedRequestIDs {
            slashCommandRequestSessionByID.removeValue(forKey: requestID)
            slashCommandRequestEpochByID.removeValue(forKey: requestID)
        }
        lastIncrementalSeqBySessionID.removeValue(forKey: sessionID)
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTargetState()
        }
        if hoveredVoiceFollowUpSessionID == sessionID {
            voiceFollowUpHoverState.sessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
        if activeVoiceFollowUpSessionID == sessionID {
            activeVoiceFollowUpSessionID = nil
        }
        if selectedSessionID == sessionID {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
        applyManualOrderToActiveSessions()
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

    /// Synchronous event handler. Production has exactly one caller — the
    /// `for await event in client.events` loop in `start()`. Do NOT call this
    /// from other production code; new transport entries should go through
    /// `client.events`, not bypass it.
    ///
    /// Tests use this entry point directly so reducer assertions stay
    /// deterministic and free of `Task.sleep`-based settling. The `.connected`
    /// and `.disconnected` cases mutate loader state and spawn a `Task` to
    /// send `listSessions`, so this is not a pure reducer; treat it as the
    /// canonical event-application seam, called once per delivered event.
    func apply(_ event: PickyClientEvent) {
        switch event {
        case .connected:
            lastConnectedAt = Date()
            pickySessionLog("client connected sessions=\(sessions.count) archived=\(archivedSessions.count)")
            if sessions.isEmpty && archivedSessions.isEmpty {
                isLoadingInitialSessionSnapshot = true
                armInitialSnapshotWatchdog()
            }
            lastError = nil
            Task {
                pickySessionLog("send listSessions for initial snapshot")
                try? await client.send(PickyCommandEnvelope(type: .listSessions))
            }
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

    /// Inner reducer for fully-decoded protocol events. Stays private — reducer
    /// tests always go through the `PickyClientEvent.protocolEvent(...)` envelope
    /// (matching the production path), so this entry point has no external
    /// callers and exposing it would only widen the API surface.
    private func apply(_ event: PickyEvent) {
        switch event {
        case .sessionSnapshot(let snapshot):
            applySessionSnapshot(snapshot)
        case .sessionUpdated(let session):
            applySessionUpdated(session)
        case .sessionArchivedAuthoritative(let sessionId, let archived):
            applySessionArchivedAuthoritative(sessionID: sessionId, archived: archived)
        case .sessionLogAppended(let sessionId, let line):
            applySessionLogAppended(sessionID: sessionId, line: line)
        case .toolActivityUpdated(let sessionId, let tool):
            applyToolActivityUpdated(sessionID: sessionId, tool: tool)
        case .extensionUiRequest(let request):
            applyExtensionUiRequest(request)
        case .artifactUpdated(let sessionId, let artifact):
            applyArtifactUpdated(sessionID: sessionId, artifact: artifact)
        case .sessionResourcesReloaded(let sessionId):
            PickyPerf.event("vm_event_session_resources_reloaded")
            pickySessionLog("session resources reloaded session=\(sessionId)")
            invalidateSlashCommandCache(sessionID: sessionId, refreshIfPreviouslyRequested: true)
        case .slashCommandsSnapshot(let sessionId, let requestId, let commands):
            applySlashCommandsSnapshot(sessionID: sessionId, requestID: requestId, commands: commands)
        case .sessionMessageAppended(let sessionId, let message, let seq):
            applySessionMessageAppended(sessionID: sessionId, message: message, seq: seq)
        case .sessionMessageReplaced(let sessionId, let messageId, let message, let seq):
            applySessionMessageReplaced(sessionID: sessionId, messageID: messageId, message: message, seq: seq)
        case .sessionMessageRemoved(let sessionId, let messageId, let seq):
            applySessionMessageRemoved(sessionID: sessionId, messageID: messageId, seq: seq)
        case .sessionQueueUpdated(let sessionId, let steering, let followUp, let steeringMode, let followUpMode, let seq):
            applySessionQueueUpdated(sessionID: sessionId, steering: steering, followUp: followUp, steeringMode: steeringMode, followUpMode: followUpMode, seq: seq)
        case .sessionActivityUpdated(let sessionId, let activitySummary, let seq):
            applySessionActivityUpdated(sessionID: sessionId, activitySummary: activitySummary, seq: seq)
        case .error(let error):
            pickySessionLog("protocol error code=\(error.code) command=\(error.commandId ?? "none")")
            lastError = error.message
        case .terminalSessionSyncOutcome(let outcome):
            applyTerminalSessionSyncOutcome(outcome)
        case .quickReply, .mainMessagesSnapshot, .mainMessageAppended, .mainAgentSessionInfoUpdated, .mainAgentModelsSnapshot,
             .mainRealtimeStateChanged, .mainRealtimeInputTranscriptDelta, .mainRealtimeInputTranscriptCompleted,
             .mainRealtimeOutputAudioDelta, .mainRealtimeOutputAudioDone,
             .mainRealtimeOutputTranscriptDelta, .mainRealtimeOutputTranscriptCompleted, .mainRealtimeTurnDone,
             .transcriptionStreamStarted, .transcriptionDelta, .transcriptionCompleted,
             .transcriptionStreamFailed, .transcriptionStreamClosed,
             .pointerOverlayRequested, .pickleHandoffRequested, .pickleBridgeRequested, .externalEntryRequested,
             .externalEntryAccepted, .pushToTalkControlRequested, .hello, .pluginsReloaded, .unknown:
            break
        }
    }

    // MARK: - Protocol event handlers

    private func applySessionSnapshot(_ snapshot: [PickyAgentSession]) {
        PickyPerf.event("vm_event_session_snapshot")
        let elapsedSinceConnectedMs = lastConnectedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        pickySessionLog("snapshot sessions=\(snapshot.count) elapsedSinceConnectedMs=\(elapsedSinceConnectedMs)")
        disarmInitialSnapshotWatchdog()
        isLoadingInitialSessionSnapshot = false
        let previousCardsByID = Dictionary(uniqueKeysWithValues: (sessions + archivedSessions).map { ($0.id, $0) })
        let cards = snapshot.map(SessionCard.fromAgentSession)
        // Hydrate manuallyArchivedSessionIDs from the daemon's persisted `archived`
        // flag so a Picky restart with empty/cleared local UserDefaults still
        // partitions archived Pickles correctly. The union preserves any locally
        // archived ID that has not round-tripped yet; the intersection with the
        // snapshot universe prunes stale IDs (e.g. daemon-side purged sessions).
        // Skip when cards is empty so a partial/empty snapshot cannot wipe the
        // local archive set — the next non-empty snapshot will repopulate it.
        if !cards.isEmpty {
            let daemonArchivedIDs = Set(cards.filter(\.archived).map(\.id))
            let universe = Set(cards.map(\.id))
            let reconciled = archiveStore.manuallyArchivedSessionIDs
                .union(daemonArchivedIDs)
                .intersection(universe)
            if reconciled != archiveStore.manuallyArchivedSessionIDs {
                archiveStore.manuallyArchivedSessionIDs = reconciled
            }
        }
        let archivedIDs = effectiveArchivedSessionIDs(for: cards)
        lastIncrementalSeqBySessionID.removeAll()
        PickyPerf.interval("vm_snapshot_publish_session_lists") {
            sessions = cards.filter { !archivedIDs.contains($0.id) }
            archivedSessions = cards.filter { archivedIDs.contains($0.id) }.sortedForHUD()
        }
        PickyPerf.interval("vm_snapshot_apply_manual_order") {
            applyManualOrderToActiveSessions()
        }
        for card in cards {
            PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
            PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
            bindPendingFullscreenTurnSnapshots(sessionID: card.id, messages: card.messages)
        }
        pruneSlashCommandCache(knownSessionIDs: Set(cards.map(\.id)))
        syncThinkingBlockVisibility()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
        for card in sessions {
            if previousCardsByID[card.id] == nil {
                markNotificationDeliveredIfNeeded(for: card)
            } else {
                deliverNotificationIfNeeded(for: card)
            }
        }
    }

    private func applySessionUpdated(_ session: PickyAgentSession) {
        PickyPerf.event("vm_event_session_updated")
        pickySessionLog("session updated session=\(session.id) status=\(session.status.rawValue)")
        let incomingCard = PickyPerf.interval("vm_session_from_agent_session") {
            SessionCard.fromAgentSession(session)
        }
        let previousCard = (sessions + archivedSessions).first { $0.id == session.id }
        if shouldInvalidateSlashCommandCache(previous: previousCard, incoming: incomingCard) {
            invalidateSlashCommandCache(sessionID: session.id)
        }
        PickyPerf.interval("vm_event_session_updated_upsert") {
            upsert(
                incomingCard,
                preserveIncrementalConversationState: lastIncrementalSeqBySessionID[session.id] != nil
            )
        }
        if let messages = card(sessionID: session.id)?.messages {
            bindPendingFullscreenTurnSnapshots(sessionID: session.id, messages: messages)
        }
    }

    private func applySessionArchivedAuthoritative(sessionID sessionId: String, archived: Bool) {
        PickyPerf.event("vm_event_session_archived_authoritative")
        // agentd has issued an authoritative archive-state change (either
        // from a client setSessionArchived command, or from the realtime
        // picky_unarchive_pickle tool). Mirror it into the local
        // manuallyArchivedSessionIDs set — the only thing upsert() looks
        // at when deciding dock placement — and then re-upsert the card
        // so the dock actually moves. We do this here rather than on
        // plain sessionUpdated to avoid the long-standing
        // mid-flight unarchive flicker race.
        pickySessionLog("session archived authoritative session=\(sessionId) archived=\(archived)")
        var archivedIDs = archiveStore.archivedSessionIDs
        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        if archived {
            if archivedIDs.insert(sessionId).inserted { archiveStore.archivedSessionIDs = archivedIDs }
            if manuallyArchivedIDs.insert(sessionId).inserted { archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs }
        } else {
            if archivedIDs.remove(sessionId) != nil { archiveStore.archivedSessionIDs = archivedIDs }
            if manuallyArchivedIDs.remove(sessionId) != nil { archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs }
        }
        // Re-place the card by feeding the cached snapshot back through
        // upsert with its archived field updated to match. If we have no
        // record of the session yet, drop the signal — the next regular
        // sessionUpdated will hydrate it with the authoritative flag.
        if let existing = (sessions + archivedSessions).first(where: { $0.id == sessionId }) {
            var refreshed = existing
            refreshed.archived = archived
            upsert(refreshed, preserveIncrementalConversationState: true)
        }
    }

    private func applySessionLogAppended(sessionID sessionId: String, line: String) {
        PickyPerf.event("vm_event_session_log_appended")
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
    }

    private func applyToolActivityUpdated(sessionID sessionId: String, tool: PickyToolActivity) {
        PickyPerf.event("vm_event_tool_activity_updated")
        update(sessionID: sessionId) { card in
            if let toolIndex = card.tools.firstIndex(where: { $0.toolCallId == tool.toolCallId }) {
                card.tools[toolIndex] = tool
            } else {
                card.tools.append(tool)
            }
            card.logPreview = [tool.name, tool.preview].compactMap { $0 }.joined(separator: ": ")
            card.updatedAt = tool.endedAt ?? Date()
        }
    }

    private func applyExtensionUiRequest(_ request: PickyExtensionUiRequest) {
        PickyPerf.event("vm_event_extension_ui_request")
        pickySessionLog("extension-ui request session=\(request.sessionId) request=\(request.id) method=\(request.method)")
        if handleFireAndForgetExtensionUiRequest(request) { return }
        update(sessionID: request.sessionId) { card in
            card.status = .waiting_for_input
            card.pendingExtensionUiRequest = request
            card.lastSummary = request.prompt ?? request.title ?? "Waiting for input"
            card.updatedAt = request.createdAt
        }
    }

    private func applyArtifactUpdated(sessionID sessionId: String, artifact: PickyArtifact) {
        PickyPerf.event("vm_event_artifact_updated")
        pickySessionLog("artifact updated session=\(sessionId) artifact=\(artifact.id) kind=\(artifact.kind)")
        update(sessionID: sessionId) { card in
            if let index = card.artifacts.firstIndex(where: { $0.id == artifact.id }) {
                card.artifacts[index] = artifact
            } else {
                card.artifacts.append(artifact)
            }
            card.updatedAt = artifact.updatedAt
        }
    }

    private func applySlashCommandsSnapshot(sessionID sessionId: String, requestID requestId: String?, commands: [PickySlashCommand]) {
        PickyPerf.event("vm_event_slash_commands_snapshot")
        let currentEpoch = slashCommandsEpochBySessionID[sessionId] ?? 0
        let requestEpoch: UInt64?
        if let requestId {
            guard let requestSessionId = slashCommandRequestSessionByID.removeValue(forKey: requestId),
                  let matchedRequestEpoch = slashCommandRequestEpochByID.removeValue(forKey: requestId),
                  requestSessionId == sessionId else {
                pickySessionLog("slash commands snapshot discarded session=\(sessionId) reason=unknown-request commands=\(commands.count)")
                return
            }
            requestEpoch = matchedRequestEpoch
        } else {
            let staleRequestIDs = slashCommandRequestSessionByID
                .filter { entry in
                    entry.value == sessionId && slashCommandRequestEpochByID[entry.key] != currentEpoch
                }
                .map(\.key)
            if !staleRequestIDs.isEmpty {
                for staleRequestID in staleRequestIDs {
                    slashCommandRequestSessionByID.removeValue(forKey: staleRequestID)
                    slashCommandRequestEpochByID.removeValue(forKey: staleRequestID)
                }
                pickySessionLog("slash commands snapshot discarded session=\(sessionId) reason=no-request-id-after-epoch-invalidation staleRequests=\(staleRequestIDs.count) commands=\(commands.count)")
                return
            }
            let matchingRequestIDs = slashCommandRequestSessionByID
                .filter { entry in
                    entry.value == sessionId && slashCommandRequestEpochByID[entry.key] == currentEpoch
                }
                .map(\.key)
            guard !matchingRequestIDs.isEmpty else {
                pickySessionLog("slash commands snapshot discarded session=\(sessionId) reason=no-request-id-without-inflight commands=\(commands.count)")
                return
            }
            requestEpoch = currentEpoch
        }
        guard requestEpoch == currentEpoch else {
            pickySessionLog("slash commands snapshot discarded session=\(sessionId) requestEpoch=\(requestEpoch ?? 0) currentEpoch=\(currentEpoch) commands=\(commands.count)")
            return
        }
        clearSlashCommandRequests(sessionID: sessionId)
        pickySessionLog("slash commands snapshot session=\(sessionId) epoch=\(currentEpoch) commands=\(commands.count)")
        slashCommandsBySessionID[sessionId] = commands
        slashCommandRequestedSessionIDs.insert(sessionId)
    }

    private func applySessionMessageAppended(sessionID sessionId: String, message: PickySessionMessage, seq: Int) {
        PickyPerf.event("vm_event_session_message_appended")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        update(sessionID: sessionId) { card in
            card.messages.append(message)
            card.updatedAt = max(card.updatedAt, message.createdAt)
        }
        if message.kind == .userText || message.kind == .commandReceipt,
           let messages = card(sessionID: sessionId)?.messages {
            bindPendingFullscreenTurnSnapshots(sessionID: sessionId, messages: messages)
        }
    }

    private func applySessionMessageReplaced(sessionID sessionId: String, messageID messageId: String, message: PickySessionMessage, seq: Int) {
        PickyPerf.event("vm_event_session_message_replaced")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        update(sessionID: sessionId) { card in
            if let index = card.messages.firstIndex(where: { $0.id == messageId }) {
                card.messages[index] = message
            } else {
                card.messages.append(message)
            }
            card.updatedAt = max(card.updatedAt, message.createdAt)
        }
        if message.kind == .userText || message.kind == .commandReceipt,
           let messages = card(sessionID: sessionId)?.messages {
            bindPendingFullscreenTurnSnapshots(sessionID: sessionId, messages: messages)
        }
    }

    private func applySessionMessageRemoved(sessionID sessionId: String, messageID messageId: String, seq: Int) {
        PickyPerf.event("vm_event_session_message_removed")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        update(sessionID: sessionId) { card in
            card.messages.removeAll { $0.id == messageId }
            card.updatedAt = Date()
        }
    }

    private func applySessionQueueUpdated(sessionID sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int) {
        PickyPerf.event("vm_event_session_queue_updated")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        update(sessionID: sessionId) { card in
            card.queuedSteers = steering
            card.queuedFollowUps = followUp
            if let steeringMode { card.steeringMode = steeringMode }
            if let followUpMode { card.followUpMode = followUpMode }
            card.updatedAt = Date()
        }
    }

    private func applySessionActivityUpdated(sessionID sessionId: String, activitySummary: PickyActivitySummary, seq: Int) {
        PickyPerf.event("vm_event_session_activity_updated")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        update(sessionID: sessionId) { card in
            card.activitySummary = activitySummary
            card.updatedAt = Date()
        }
    }

    private func applyTerminalSessionSyncOutcome(_ outcome: PickyTerminalSessionSyncOutcome) {
        // Suppress the banner for the "nothing new" outcome — the user already
        // saw the terminal close cleanly, so a banner that just says "nothing
        // imported" is noise. The baseline-missing and imported-N-messages
        // outcomes still surface so the user notices a silent skip or a
        // successful import.
        guard PickyTerminalSyncOutcomePolicy.shouldSurfaceBanner(for: outcome) else { return }
        update(sessionID: outcome.sessionId) { card in
            card.lastTerminalSyncOutcome = outcome
            card.updatedAt = Date()
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
            let text = request.text ?? request.prompt ?? ""
            composerDraftController.primeRequest(sessionID: request.sessionId, requestID: request.id, text: text)
            syncComposerDraftRequests()
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

    private func invalidateSlashCommandCache(sessionID: String, refreshIfPreviouslyRequested: Bool = false) {
        // If there is an in-flight request, its response is about to be discarded by the epoch
        // bump below. Without a re-fire the composer would stay stuck on "Loading commands…"
        // until the next onAppear (i.e. until the HUD is closed and reopened). Always refresh in
        // that case so the UI converges as soon as the daemon answers the new request.
        let hadInFlightRequest = slashCommandRequestedSessionIDs.contains(sessionID)
        let shouldRefresh = hadInFlightRequest
            || (refreshIfPreviouslyRequested && slashCommandsBySessionID[sessionID] != nil)
        slashCommandsEpochBySessionID[sessionID] = (slashCommandsEpochBySessionID[sessionID] ?? 0) &+ 1
        slashCommandsBySessionID[sessionID] = nil
        slashCommandRequestedSessionIDs.remove(sessionID)
        if shouldRefresh {
            ensureSlashCommandsLoaded(sessionID: sessionID)
        }
    }

    /// Safety-net retry for the composer's "Loading commands…" state. If a previous request was
    /// dropped silently (e.g. transport loss), send another request in the same cache epoch so a
    /// slow-but-valid response from either request can still hydrate autocomplete instead of being
    /// starved by polling. No-op if commands are already loaded.
    func refreshSlashCommandsIfStillLoading(sessionID: String) {
        guard slashCommandsBySessionID[sessionID] == nil else { return }
        requestSlashCommands(sessionID: sessionID)
    }

    private func clearSlashCommandRequests(sessionID: String) {
        let requestIDs = slashCommandRequestSessionByID.filter { $0.value == sessionID }.map(\.key)
        for requestID in requestIDs {
            slashCommandRequestSessionByID.removeValue(forKey: requestID)
            slashCommandRequestEpochByID.removeValue(forKey: requestID)
        }
    }

    private func pruneSlashCommandCache(knownSessionIDs: Set<String>) {
        slashCommandsBySessionID = slashCommandsBySessionID.filter { knownSessionIDs.contains($0.key) }
        slashCommandsEpochBySessionID = slashCommandsEpochBySessionID.filter { knownSessionIDs.contains($0.key) }
        slashCommandRequestedSessionIDs = slashCommandRequestedSessionIDs.filter { knownSessionIDs.contains($0) }
        slashCommandRequestSessionByID = slashCommandRequestSessionByID.filter { knownSessionIDs.contains($0.value) }
        slashCommandRequestEpochByID = slashCommandRequestEpochByID.filter { slashCommandRequestSessionByID[$0.key] != nil }
        composerDraftController.prune(knownSessionIDs: knownSessionIDs)
        syncComposerDraftRequests()
        thinkingBlocksHiddenBySessionID = thinkingBlocksHiddenBySessionID.filter { knownSessionIDs.contains($0.key) }
        slashCommandRequestedSessionIDs = slashCommandRequestedSessionIDs.filter { knownSessionIDs.contains($0) }
        pendingDoneFlashSessionIDs = pendingDoneFlashSessionIDs.filter { knownSessionIDs.contains($0) }
        unreadSessionIDs = unreadSessionIDs.filter { knownSessionIDs.contains($0) }
        releasedArchivedChildSessionIDs = releasedArchivedChildSessionIDs.filter { knownSessionIDs.contains($0) }
        lastIncrementalSeqBySessionID = lastIncrementalSeqBySessionID.filter { knownSessionIDs.contains($0.key) }
        let removedInlineTerminalIDs = inlineTerminalSessionIDs.subtracting(knownSessionIDs)
        inlineTerminalSessionIDs = inlineTerminalSessionIDs.filter { knownSessionIDs.contains($0) }
        for sessionID in removedInlineTerminalIDs {
            removeVisibleInlineTerminalAttachments(sessionID: sessionID)
            closeInlineTerminalSession(sessionID: sessionID)
        }
        let removedShellTerminalIDs = Set(shellTerminalSessionsBySessionID.keys).subtracting(knownSessionIDs)
        for sessionID in removedShellTerminalIDs {
            closeShellTerminalSession(sessionID: sessionID)
        }
        if let screenContextTargetSessionID, !knownSessionIDs.contains(screenContextTargetSessionID) {
            clearScreenContextTarget(sessionID: screenContextTargetSessionID)
        }
    }

    private func syncThinkingBlockVisibility() {
        thinkingBlocksHiddenBySessionID = Dictionary(uniqueKeysWithValues: (sessions + archivedSessions).map { session in
            (session.id, PickyPiSettingsReader.hideThinkingBlock(cwd: session.cwd))
        })
    }

    private func effectiveArchivedSessionIDs(for _: [SessionCard]) -> Set<String> {
        let manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        if archiveStore.archivedSessionIDs != manuallyArchivedIDs {
            archiveStore.archivedSessionIDs = manuallyArchivedIDs
        }
        return manuallyArchivedIDs
    }

    private func upsert(_ card: SessionCard, preserveIncrementalConversationState: Bool = false) {
        PickyPerf.event("vm_upsert_called")
        let archivedIDs = effectiveArchivedSessionIDs(for: [card])
        let shouldArchive = archivedIDs.contains(card.id)
        let previousStatus = (sessions + archivedSessions).first(where: { $0.id == card.id })?.status
        PickyPerf.interval("vm_upsert_prefetch_enqueue") {
            PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
            PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
        }
        var incoming = card
        PickyPerf.interval("vm_upsert_merge_existing") {
            if let existing = (sessions + archivedSessions).first(where: { $0.id == card.id }) {
                incoming = existing.merged(with: card, preserveConversationState: preserveIncrementalConversationState)
            }
        }

        PickyPerf.interval("vm_upsert_remove_from_lists") {
            sessions.removeAll { $0.id == card.id }
            archivedSessions.removeAll { $0.id == card.id }
        }
        PickyPerf.interval("vm_upsert_append_to_list") {
            if shouldArchive {
                archivedSessions.append(incoming)
            } else {
                sessions.append(incoming)
            }
        }
        PickyPerf.interval("vm_upsert_sort_archived") {
            archivedSessions = archivedSessions.sortedForHUD()
        }
        PickyPerf.interval("vm_upsert_apply_manual_order") {
            applyManualOrderToActiveSessions()
        }
        PickyPerf.interval("vm_upsert_publish_thinking_visibility") {
            thinkingBlocksHiddenBySessionID[incoming.id] = PickyPiSettingsReader.hideThinkingBlock(cwd: incoming.cwd)
        }
        PickyPerf.interval("vm_upsert_sync_selection_state") {
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
            syncScreenContextTargetAfterSessionListChange()
            syncActiveVoiceFollowUpAfterSessionListChange()
        }
        if shouldArchive {
            // Archived sessions are out of the dock surface; suppress unread badge.
            PickyPerf.interval("vm_upsert_publish_archive_badges") {
                unreadSessionIDs.remove(incoming.id)
            }
            releaseArchivedTerminalChildIfCommitted(incoming)
        } else {
            releasedArchivedChildSessionIDs.remove(incoming.id)
            PickyPerf.interval("vm_upsert_publish_completion_badges") {
                requestDoneFlashIfNeeded(previousStatus: previousStatus, incoming: incoming)
                updateUnreadStateIfNeeded(previousStatus: previousStatus, incoming: incoming)
            }
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

    /// Mark a session unread when it transitions live into a state the user is
    /// expected to acknowledge (completed, failed, or waiting for input). Clear
    /// the flag the moment the session leaves that bucket on its own — e.g. a
    /// follow-up turn drives it back into `.running` — so the dot does not
    /// linger past the user's attention.
    private func updateUnreadStateIfNeeded(previousStatus: PickySessionStatus?, incoming: SessionCard) {
        let attentionStates: Set<PickySessionStatus> = [.completed, .failed, .waiting_for_input]
        let isAttentionNow = attentionStates.contains(incoming.status)
        let wasAttentionBefore = previousStatus.map(attentionStates.contains) ?? false
        if isAttentionNow {
            // Skip cold hydration: nil previousStatus means we are seeing this
            // session for the first time (snapshot replay routed through upsert).
            // The user never witnessed the transition, so we should not nag.
            guard let previousStatus else { return }
            guard previousStatus != incoming.status else { return }
            unreadSessionIDs.insert(incoming.id)
        } else if wasAttentionBefore {
            unreadSessionIDs.remove(incoming.id)
        }
    }

    private func update(sessionID: String, mutate: (inout SessionCard) -> Void) {
        PickyPerf.event("vm_update_called")
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            PickyPerf.interval("vm_update_active_session") {
                var card = sessions[index]
                PickyPerf.interval("vm_update_mutate_card") {
                    mutate(&card)
                }
                PickyPerf.interval("vm_update_publish_sessions_subscript") {
                    sessions[index] = card
                }
                // Manual order is the source of truth for active session ordering;
                // a per-card mutation does not change order, so no reapply needed.
                PickyPerf.interval("vm_update_sync_selection_state") {
                    syncSelectionAfterSessionListChange()
                    syncVoiceFollowUpAfterSessionListChange()
                    syncScreenContextTargetAfterSessionListChange()
                    syncActiveVoiceFollowUpAfterSessionListChange()
                }
                deliverNotificationIfNeeded(for: card)
            }
            return
        }
        guard let archivedIndex = archivedSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        PickyPerf.interval("vm_update_archived_session") {
            var archivedCard = archivedSessions[archivedIndex]
            PickyPerf.interval("vm_update_mutate_card") {
                mutate(&archivedCard)
            }
            PickyPerf.interval("vm_update_publish_archived_subscript") {
                archivedSessions[archivedIndex] = archivedCard
            }
            PickyPerf.interval("vm_update_sort_archived") {
                archivedSessions = archivedSessions.sortedForHUD()
            }
        }
    }

    /// Reapply ordering to `sessions`. When `manualOrder` is empty (= user
    /// has never dragged anything), this falls back to the historic
    /// `sortedForHUD()` order so creation-time semantics are preserved. Once
    /// the user makes a manual move, `moveSession` seeds `manualOrder` and
    /// subsequent calls maintain it: prune ids no longer present in the
    /// active/archived universe, and prepend any active id missing from
    /// `manualOrder` (preserving newest-first inside the new batch) so brand
    /// new Pickles land on the visually-end slot.
    private func applyManualOrderToActiveSessions() {
        PickyPerf.event("vm_apply_manual_order_called")
        // Keep the dock layout in lockstep with the daemon's session
        // universe. Done up-front so newly created Pickles end up appended
        // to `dockLayout.entries` before any HUD render reads it.
        PickyPerf.interval("vm_apply_manual_order_reconcile_dock_layout") {
            reconcileDockLayout()
        }
        guard !manualOrder.isEmpty else {
            PickyPerf.interval("vm_apply_manual_order_publish_sorted_default") {
                sessions = sessions.sortedForHUD()
            }
            return
        }
        var order = manualOrder
        let activeIDs = Set(sessions.map(\.id))
        let archivedIDs = Set(archivedSessions.map(\.id))
        let universe = activeIDs.union(archivedIDs)
        order.removeAll { !universe.contains($0) }

        let knownIDs = Set(order)
        let missingActiveIDs = sessions
            .filter { !knownIDs.contains($0.id) }
            .sortedForHUD() // newest first
            .map(\.id)
        if !missingActiveIDs.isEmpty {
            // Insert the whole missing batch at position 0 so newest-of-batch
            // ends up at index 0 (visually-end slot) and the rest follow in
            // newest-first order. Iterating with `insert(at:0)` would reverse
            // the batch, so we use `insert(contentsOf:)` instead.
            order.insert(contentsOf: missingActiveIDs, at: 0)
        }

        if order != manualOrder {
            manualOrder = order
            manualOrderStore.manualOrder = order
        }
        PickyPerf.interval("vm_apply_manual_order_publish_manual") {
            sessions = sessions.sortedByManualOrder(order)
        }
    }

    /// Capture the current active sessions order into `manualOrder` so the
    /// next reorder respects whatever the user is currently seeing. Called
    /// implicitly by `moveSession` the first time the user drags, before any
    /// manual override was persisted. No-op once `manualOrder` is non-empty.
    private func seedManualOrderIfNeeded() {
        guard manualOrder.isEmpty else { return }
        let sorted = sessions.sortedForHUD()
        let order = sorted.map(\.id)
        guard !order.isEmpty else { return }
        manualOrder = order
        manualOrderStore.manualOrder = order
    }

    /// Move a visible dock icon to a new display position. `toVisibleIndex` is
    /// in *visible* space — the same axis the dock renders along (top→bottom
    /// in a vertical dock, left→right in a horizontal dock), which is the
    /// `prefix(visibleSessionLimit).reversed()` slice of `sessions`. Clamps
    /// out-of-range targets and is a no-op when the index does not change.
    /// Returns `true` if the order actually changed.
    @discardableResult
    func moveSession(sessionID: String, toVisibleIndex visibleTargetRaw: Int) -> Bool {
        let visibleLimit = PickyHUDDockLayout.visibleSessionLimit
        let visibleCount = min(sessions.count, visibleLimit)
        guard visibleCount > 0 else { return false }

        // Visible space is `sessions.prefix(N).reversed()`. Underlying
        // sessions-index = (N - 1) - visibleIndex.
        guard let underlyingCurrent = sessions.prefix(visibleCount).firstIndex(where: { $0.id == sessionID }) else { return false }
        let visibleCurrent = (visibleCount - 1) - underlyingCurrent
        let visibleTarget = max(0, min(visibleCount - 1, visibleTargetRaw))
        guard visibleCurrent != visibleTarget else { return false }
        let underlyingTarget = (visibleCount - 1) - visibleTarget

        // Ensure every active session id is present in manualOrder before the
        // move. Otherwise inserting the dragged id by "active-count" index
        // would skip over the newcomer entries that have not been synced yet.
        seedManualOrderIfNeeded()
        applyManualOrderToActiveSessions()
        var order = manualOrder
        guard let fromOrderIdx = order.firstIndex(of: sessionID) else { return false }
        order.remove(at: fromOrderIdx)

        // Translate the active-sessions target index into a manualOrder index
        // by counting active ids encountered. manualOrder may interleave
        // archived ids (so unarchive restores the user's slot), so a direct
        // index match would land in the wrong place when those gaps exist.
        let activeIDs = Set(sessions.map(\.id)).subtracting([sessionID])
        var activeSeen = 0
        var insertIdx = order.count
        for (idx, id) in order.enumerated() {
            if activeSeen == underlyingTarget {
                insertIdx = idx
                break
            }
            if activeIDs.contains(id) {
                activeSeen += 1
            }
        }
        order.insert(sessionID, at: insertIdx)

        manualOrder = order
        manualOrderStore.manualOrder = order
        sessions = sessions.sortedByManualOrder(order)
        return true
    }

    /// Clear manual reorder for the dock so sessions fall back to creation
    /// time order. Useful as a "Reset order" menu action and from tests.
    func resetManualSessionOrder() {
        guard !manualOrder.isEmpty else { return }
        manualOrder = []
        manualOrderStore.manualOrder = []
        applyManualOrderToActiveSessions()
    }

    // MARK: - Dock layout / groups

    /// Drop dock-layout references whose session id no longer exists and
    /// append brand-new active sessions at the bottom of the dock (= end of
    /// `entries`). Called after every `sessions` mutation so the persisted
    /// layout stays in lockstep with the daemon's session universe.
    ///
    /// First-run migration: when the persisted layout is empty but the
    /// legacy `manualOrder` UserDefaults has user-driven reorders, seed the
    /// layout from that ordering (reversed because manualOrder stores newest
    /// first and `entries` is top-down = oldest first). New sessions then
    /// fall through to the standard "append to end" branch below.
    private func reconcileDockLayout() {
        guard dockLayoutController.reconcile(activeSessionIDs: sessions.map(\.id), legacyManualOrder: manualOrder) else { return }
        dockLayout = dockLayoutController.layout
    }

    /// Create a new group at the bottom of the dock (just above the `+`
    /// slot) with the next color in rotation. `memberSessionIDs` may include
    /// sessions that already live elsewhere in the layout — they are atomic
    /// ally removed from their previous container and inserted into the new
    /// group in the order provided. Returns the new group's id so callers
    /// can focus a rename input on it or run further operations.
    @discardableResult
    func createDockGroup(name: String = "", withMemberIDs memberSessionIDs: [String] = []) -> String {
        let groupID = dockLayoutController.createGroup(name: name, withMemberIDs: memberSessionIDs)
        dockLayout = dockLayoutController.layout
        return groupID
    }

    func renameDockGroup(id: String, to name: String) {
        guard dockLayoutController.renameGroup(id: id, to: name) else { return }
        dockLayout = dockLayoutController.layout
    }

    func setDockGroupColor(id: String, color: PickyDockGroupColor) {
        guard dockLayoutController.setGroupColor(id: id, color: color) else { return }
        dockLayout = dockLayoutController.layout
    }

    /// Remove a group. When `keepMembers` is true, the members are spliced
    /// back into the top-level layout at the group's previous position (the
    /// "Ungroup" action). When false, the group's member sessions are
    /// archived too ("Delete group + archive pickles").
    func removeDockGroup(id: String, keepMembers: Bool) {
        let removedMemberIDs = dockLayoutController.removeGroup(id: id, keepMembers: keepMembers)
        dockLayout = dockLayoutController.layout
        if !keepMembers {
            for memberID in removedMemberIDs {
                archive(sessionID: memberID)
            }
        }
    }

    /// Move a session to an explicit dock container/position. Used by the
    /// drag handler after it hit-tests the cursor against the current
    /// rendered slots.
    func moveSessionInDock(sessionID: String, to destination: PickyDockContainer) {
        guard dockLayoutController.moveSession(sessionID: sessionID, to: destination) else { return }
        dockLayout = dockLayoutController.layout
    }

    /// Reorder a group as a whole within the top-level layout. `target` is
    /// the post-removal index (0 = top of dock).
    func moveDockGroup(id: String, toTopLevelIndex target: Int) {
        guard dockLayoutController.moveGroup(id: id, toTopLevelIndex: target) else { return }
        dockLayout = dockLayoutController.layout
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
            voiceFollowUpHoverState.sessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
    }

    private func syncScreenContextTargetAfterSessionListChange() {
        if let screenContextTargetSessionID, sessions.contains(where: { $0.id == screenContextTargetSessionID }) {
            selectionStore.setScreenContextTarget(sessionID: screenContextTargetSessionID, sticky: screenContextTargetSticky)
        } else if screenContextTargetSessionID != nil {
            clearScreenContextTarget(sessionID: screenContextTargetSessionID)
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

    private func notification(for session: SessionCard) -> PickySessionNotificationPolicy.Notification? {
        PickySessionNotificationPolicy.notification(
            for: notificationInput(for: session),
            preferences: notificationPreferencesProvider.notificationPreferences
        )
    }

    private func notificationInput(for session: SessionCard) -> PickySessionNotificationPolicy.Input {
        let pendingRequest = session.pendingExtensionUiRequest.map {
            PickySessionNotificationPolicy.Input.PendingRequest(
                id: $0.id,
                title: $0.title,
                prompt: $0.prompt
            )
        }
        return PickySessionNotificationPolicy.Input(
            sessionID: session.id,
            title: session.title,
            status: session.status,
            lastSummary: session.lastSummary,
            pendingRequest: pendingRequest,
            pinned: session.pinned
        )
    }

    private func resetTerminalNotificationKeysIfNeeded(for session: SessionCard) {
        deliveredNotificationKeys.subtract(
            PickySessionNotificationPolicy.terminalDedupKeysToReset(
                sessionID: session.id,
                status: session.status
            )
        )
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
        return !previous.messages.isEmpty
            || !previous.queuedSteers.isEmpty
            || !previous.queuedFollowUps.isEmpty
            || !previous.tools.isEmpty
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
    /// slot after `prefix.reversed()`). IDs absent from `manualOrder` are
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

private func pickySessionLog(_ message: String) {
    PickyLog.notice(.sessionUI, prefix: "🧭 Picky session UI —", message: message)
}

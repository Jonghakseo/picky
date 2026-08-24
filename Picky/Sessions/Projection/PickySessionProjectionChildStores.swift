//
//  PickySessionProjectionChildStores.swift
//  Picky
//

import Foundation
import Observation

/// Scalar session fields owned by `PickySessionMetaStore`.
///
/// This deliberately excludes every child-owned collection and
/// `messageJournalAvailable` (owned by `PickySessionMessageStore`). The sixteen
/// scalar fields are the fifteen meta-patch fields owned here plus `finalAnswer`,
/// which has its own v2 mutation; `revision` is the projection cursor level.
struct PickySessionMetadata: Equatable {
    let id: String
    var revision: Int
    var title: String
    var status: PickySessionStatus
    var cwd: String?
    var piSessionFilePath: String?
    var createdAt: Date
    var updatedAt: Date
    var lastSummary: String?
    var thinkingPreview: String?
    var finalAnswer: String?
    var contextUsage: PickyContextUsage?
    var currentAssistantRun: PickyAssistantRunMetadata?
    var notifyMainOnCompletion: Bool?
    var archived: Bool?
    var archivedAt: Date?
    var pinned: Bool?

    init(session: PickyAgentSession, revision: Int = 0, archivedAt: Date? = nil) {
        id = session.id
        self.revision = revision
        title = session.title
        status = session.status
        cwd = session.cwd
        piSessionFilePath = session.piSessionFilePath
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        lastSummary = session.lastSummary
        thinkingPreview = session.thinkingPreview
        finalAnswer = session.finalAnswer
        contextUsage = session.contextUsage
        currentAssistantRun = session.currentAssistantRun
        notifyMainOnCompletion = session.notifyMainOnCompletion
        archived = session.archived
        self.archivedAt = archivedAt
        pinned = session.pinned
    }

    /// W4's v1 façade boundary supplies an already-built card. `finalAnswer`
    /// is not represented by that legacy value model, so it remains dormant
    /// until the v2 mutation path writes metadata directly.
    init(card: PickySessionListViewModel.SessionCard, revision: Int = 0, archivedAt: Date? = nil) {
        id = card.id
        self.revision = revision
        title = card.title
        status = card.status
        cwd = card.cwd
        piSessionFilePath = card.piSessionFilePath
        createdAt = card.createdAt
        updatedAt = card.updatedAt
        lastSummary = card.lastSummary
        thinkingPreview = card.thinkingPreview
        finalAnswer = nil
        contextUsage = card.contextUsage
        currentAssistantRun = card.currentAssistantRun
        notifyMainOnCompletion = card.notifyMainOnCompletion
        archived = card.archived
        self.archivedAt = archivedAt
        pinned = card.pinned
    }
}

@MainActor
@Observable
final class PickySessionMetaStore {
    @ObservationIgnored private var state: PickyProjectionSectionState<PickySessionMetadata> = .unavailable
    private(set) var valueRevision = 0

    var metadataState: PickyProjectionSectionState<PickySessionMetadata> {
        _ = valueRevision
        return state
    }

    func replace(_ metadata: PickySessionMetadata) {
        state = .loaded(metadata)
        valueRevision += 1
    }

    func markUnavailable() {
        state = .unavailable
        valueRevision += 1
    }
}

@MainActor
@Observable
final class PickySessionLogStore {
    @ObservationIgnored private var logsByID: [String: String] = [:]
    @ObservationIgnored private var state: PickyProjectionSectionState<[String]> = .unavailable
    private(set) var orderedLogIDs: [String] = []
    private(set) var valueRevision = 0

    var logsState: PickyProjectionSectionState<[String]> {
        _ = valueRevision
        return state
    }

    func replace(_ logs: [String]) {
        orderedLogIDs = logs.indices.map(String.init)
        logsByID = Dictionary(uniqueKeysWithValues: zip(orderedLogIDs, logs))
        state = .loaded(logs)
        valueRevision += 1
    }

    func log(id: String) -> String? {
        _ = valueRevision
        return logsByID[id]
    }

    func markUnavailable() {
        orderedLogIDs = []
        logsByID = [:]
        state = .unavailable
        valueRevision += 1
    }
}

@MainActor
@Observable
final class PickySessionToolStore {
    @ObservationIgnored private var toolsByID: [String: PickyToolActivity] = [:]
    @ObservationIgnored private var state: PickyProjectionSectionState<[PickyToolActivity]> = .unavailable
    private(set) var orderedToolIDs: [String] = []
    private(set) var valueRevision = 0

    var toolsState: PickyProjectionSectionState<[PickyToolActivity]> {
        _ = valueRevision
        return state
    }

    func replace(_ tools: [PickyToolActivity]) {
        orderedToolIDs = tools.map(\.id)
        toolsByID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        state = .loaded(tools)
        valueRevision += 1
    }

    func tool(id: String) -> PickyToolActivity? {
        _ = valueRevision
        return toolsByID[id]
    }

    func markUnavailable() {
        orderedToolIDs = []
        toolsByID = [:]
        state = .unavailable
        valueRevision += 1
    }
}

@MainActor
@Observable
final class PickySessionTodoStore {
    @ObservationIgnored private var tasksByID: [String: PickyTodoTask] = [:]
    @ObservationIgnored private var state: PickyProjectionSectionState<PickyTodoState?> = .unavailable
    private(set) var orderedTaskIDs: [String] = []
    private(set) var valueRevision = 0

    var todoState: PickyProjectionSectionState<PickyTodoState?> {
        _ = valueRevision
        return state
    }

    func replace(_ todoState: PickyTodoState?) {
        orderedTaskIDs = todoState?.tasks.map(\.id) ?? []
        tasksByID = Dictionary(uniqueKeysWithValues: (todoState?.tasks ?? []).map { ($0.id, $0) })
        state = .loaded(todoState)
        valueRevision += 1
    }

    func task(id: String) -> PickyTodoTask? {
        _ = valueRevision
        return tasksByID[id]
    }

    func markUnavailable() {
        orderedTaskIDs = []
        tasksByID = [:]
        state = .unavailable
        valueRevision += 1
    }
}

@MainActor
@Observable
final class PickySessionSubagentStore {
    @ObservationIgnored private var runsByID: [Int: PickySubagentRun] = [:]
    @ObservationIgnored private var state: PickyProjectionSectionState<[PickySubagentRun]> = .unavailable
    private(set) var orderedRunIDs: [Int] = []
    private(set) var valueRevision = 0

    var runsState: PickyProjectionSectionState<[PickySubagentRun]> {
        _ = valueRevision
        return state
    }

    func replace(_ runs: [PickySubagentRun]) {
        orderedRunIDs = runs.map(\.id)
        runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        state = .loaded(runs)
        valueRevision += 1
    }

    func run(id: Int) -> PickySubagentRun? {
        _ = valueRevision
        return runsByID[id]
    }

    func markUnavailable() {
        orderedRunIDs = []
        runsByID = [:]
        state = .unavailable
        valueRevision += 1
    }
}

@MainActor
@Observable
final class PickySessionArtifactStore {
    @ObservationIgnored private var artifactsByID: [String: PickyArtifact] = [:]
    @ObservationIgnored private var changedFilesByID: [String: PickyChangedFile] = [:]
    @ObservationIgnored private var artifactState: PickyProjectionSectionState<[PickyArtifact]> = .unavailable
    @ObservationIgnored private var changedFilesState: PickyProjectionSectionState<[PickyChangedFile]> = .unavailable
    private(set) var orderedArtifactIDs: [String] = []
    private(set) var orderedChangedFileIDs: [String] = []
    private(set) var valueRevision = 0

    var artifactsState: PickyProjectionSectionState<[PickyArtifact]> {
        _ = valueRevision
        return artifactState
    }

    var changedFilesProjectionState: PickyProjectionSectionState<[PickyChangedFile]> {
        _ = valueRevision
        return changedFilesState
    }

    func replace(artifacts: [PickyArtifact], changedFiles: [PickyChangedFile]) {
        orderedArtifactIDs = artifacts.map(\.id)
        artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        orderedChangedFileIDs = changedFiles.map(\.path)
        changedFilesByID = Dictionary(uniqueKeysWithValues: changedFiles.map { ($0.path, $0) })
        artifactState = .loaded(artifacts)
        changedFilesState = .loaded(changedFiles)
        valueRevision += 1
    }

    func artifact(id: String) -> PickyArtifact? {
        _ = valueRevision
        return artifactsByID[id]
    }

    func changedFile(path: String) -> PickyChangedFile? {
        _ = valueRevision
        return changedFilesByID[path]
    }

    func markUnavailable() {
        orderedArtifactIDs = []
        artifactsByID = [:]
        artifactState = .unavailable
        orderedChangedFileIDs = []
        changedFilesByID = [:]
        changedFilesState = .unavailable
        valueRevision += 1
    }
}

struct PickySessionQueueProjection: Equatable {
    let steers: [PickyQueueItem]
    let followUps: [PickyQueueItem]
}

/// Queue delivery modes are scalar session metadata, independent from the
/// availability of the queued-item collection in a bounded hydration payload.
struct PickySessionQueueModes: Equatable {
    let steeringMode: PickyQueueMode
    let followUpMode: PickyQueueMode

    static let `default` = Self(steeringMode: .oneAtATime, followUpMode: .oneAtATime)
}

@MainActor
@Observable
final class PickySessionQueueStore {
    @ObservationIgnored private var itemsByID: [String: PickyQueueItem] = [:]
    @ObservationIgnored private var state: PickyProjectionSectionState<PickySessionQueueProjection> = .unavailable
    @ObservationIgnored private var modes = PickySessionQueueModes.default
    private(set) var orderedSteerIDs: [String] = []
    private(set) var orderedFollowUpIDs: [String] = []
    private(set) var valueRevision = 0

    var queueState: PickyProjectionSectionState<PickySessionQueueProjection> {
        _ = valueRevision
        return state
    }

    var queueModes: PickySessionQueueModes {
        _ = valueRevision
        return modes
    }

    func replace(steers: [PickyQueueItem], followUps: [PickyQueueItem], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode) {
        orderedSteerIDs = stableIDs(for: steers, prefix: "steer")
        orderedFollowUpIDs = stableIDs(for: followUps, prefix: "follow-up")
        itemsByID = Dictionary(uniqueKeysWithValues: zip(orderedSteerIDs + orderedFollowUpIDs, steers + followUps))
        state = .loaded(PickySessionQueueProjection(steers: steers, followUps: followUps))
        modes = PickySessionQueueModes(steeringMode: steeringMode, followUpMode: followUpMode)
        valueRevision += 1
    }

    func item(id: String) -> PickyQueueItem? {
        _ = valueRevision
        return itemsByID[id]
    }

    func markUnavailable(steeringMode: PickyQueueMode = .oneAtATime, followUpMode: PickyQueueMode = .oneAtATime) {
        orderedSteerIDs = []
        orderedFollowUpIDs = []
        itemsByID = [:]
        state = .unavailable
        modes = PickySessionQueueModes(steeringMode: steeringMode, followUpMode: followUpMode)
        valueRevision += 1
    }

    private func stableIDs(for items: [PickyQueueItem], prefix: String) -> [String] {
        items.enumerated().map { index, item in "\(prefix):\(item.id ?? String(index))" }
    }
}

@MainActor
@Observable
final class PickySessionActivityStore {
    @ObservationIgnored private var state: PickyProjectionSectionState<PickyActivitySummary> = .unavailable
    private(set) var orderedActivityIDs: [String] = []
    private(set) var valueRevision = 0

    var activityState: PickyProjectionSectionState<PickyActivitySummary> {
        _ = valueRevision
        return state
    }

    func replace(_ summary: PickyActivitySummary) {
        orderedActivityIDs = ["current"]
        state = .loaded(summary)
        valueRevision += 1
    }

    func activitySummary() -> PickyActivitySummary? {
        _ = valueRevision
        guard case .loaded(let value) = state else { return nil }
        return value
    }

    func markUnavailable() {
        orderedActivityIDs = []
        state = .unavailable
        valueRevision += 1
    }
}

@MainActor
@Observable
final class PickySessionExtensionUiStore {
    @ObservationIgnored private var requestsByID: [String: PickyExtensionUiRequest] = [:]
    @ObservationIgnored private var state: PickyProjectionSectionState<PickyExtensionUiRequest?> = .unavailable
    private(set) var orderedRequestIDs: [String] = []
    private(set) var valueRevision = 0

    var requestState: PickyProjectionSectionState<PickyExtensionUiRequest?> {
        _ = valueRevision
        return state
    }

    func replace(_ request: PickyExtensionUiRequest?) {
        orderedRequestIDs = request.map { [$0.id] } ?? []
        requestsByID = request.map { [$0.id: $0] } ?? [:]
        state = .loaded(request)
        valueRevision += 1
    }

    func request(id: String) -> PickyExtensionUiRequest? {
        _ = valueRevision
        return requestsByID[id]
    }

    func markUnavailable() {
        orderedRequestIDs = []
        requestsByID = [:]
        state = .unavailable
        valueRevision += 1
    }
}

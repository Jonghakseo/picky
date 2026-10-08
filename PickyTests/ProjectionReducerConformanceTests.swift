//
//  ProjectionReducerConformanceTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

/// Swift runner for the language-neutral scenarios in
/// `contracts/projection/conformance/`.
///
/// Swift is the normative reader of the v2 projection stream; the TypeScript
/// reducer (`agentd/src/domain/session-projection-reducer.ts`) folds the same
/// files so a non-Swift client never becomes a third reading of the protocol.
/// Scenario events are decoded with the production wire decoder and fed to the
/// real storage reducer, and state is compared per child store so `unavailable`
/// stays distinguishable from `loaded` with an empty value.
struct ProjectionReducerConformanceTests {
    /// The shared contract directory must resolve and must not shrink. Zero
    /// executed scenarios is not a pass, and a deleted scenario is a silently
    /// dropped regression guard.
    @Test func findsEveryConformanceScenario() throws {
        #expect(
            projectionConformanceScenarioFiles.count >= 16,
            """
            Expected at least the 16 pinned conformance scenarios, found \
            \(projectionConformanceScenarioFiles.count): \(projectionConformanceScenarioFiles)
            """
        )
    }

    @Test(arguments: projectionConformanceScenarioFiles)
    @MainActor
    func foldsConformanceScenario(_ fileName: String) throws {
        let scenario = try ProjectionConformanceScenario.load(fileName: fileName)
        #expect(!scenario.scenarioDescription.isEmpty, "\(scenario.name): every scenario states the regression it pins")
        let outcome = try ProjectionConformanceRun().fold(scenario)
        try outcome.verify(against: scenario.expectation, scenarioName: scenario.name)
    }

    /// The daemon diffs each commit and picks `logAppend` or a whole `logsSet`
    /// per commit. That freedom only holds if both encodings land on the same
    /// client state, which is what the paired scenarios exist to prove.
    @Test @MainActor func reachesSameStateWhetherLogsArriveAsAppendsOrOneReplacement() throws {
        let appended = try ProjectionConformanceRun().fold(.load(name: "log-append-sequence"))
        let replaced = try ProjectionConformanceRun().fold(.load(name: "log-set-equivalent"))
        #expect(appended.sections == replaced.sections)
        #expect(appended.queueModes == replaced.queueModes)
        #expect(appended.signals == replaced.signals)
    }
}

/// Scenario file names, resolved from this test file rather than the working
/// directory so the runner works from any `xcodebuild` invocation.
private let projectionConformanceScenarioFiles: [String] = ((try? fixtureURLs(in: projectionConformanceDirectory)) ?? [])
    .map(\.lastPathComponent)

private let projectionConformanceDirectory = "contracts/projection/conformance"

// MARK: - Scenario

private struct ProjectionConformanceScenario: Decodable {
    let name: String
    let scenarioDescription: String
    let events: [PickyEventEnvelope]
    let expectation: ConformanceJSON

    private enum CodingKeys: String, CodingKey {
        case name
        case scenarioDescription = "description"
        case events
        case expectation = "expect"
    }

    static func load(fileName: String) throws -> Self {
        let url = try #require(try fixtureURLs(in: projectionConformanceDirectory).first { $0.lastPathComponent == fileName })
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func load(name: String) throws -> Self {
        try load(fileName: "\(name).json")
    }
}

// MARK: - Runner

/// Folds one scenario through the production storage reducer.
@MainActor
private struct ProjectionConformanceRun {
    private let storage = PickyRegistrySessionProjectionStorage()

    struct Outcome {
        var sessionPresent = false
        var signals: [String: Int] = [:]
        var queueModes = ConformanceJSON.null
        var sections: [String: ConformanceJSON] = [:]
    }

    func fold(_ scenario: ProjectionConformanceScenario) throws -> Outcome {
        var sessionID: String?
        var resets = 0
        var progressOnly = 0
        var ignoredTransactions = 0
        var ignoredSnapshots = 0

        for envelope in scenario.events {
            switch envelope.event {
            case .sessionProjectionSnapshot(let snapshot):
                sessionID = sessionID ?? snapshot.sessionId
                let armed = armLocalPresentation(sessionID: snapshot.sessionId)
                if storage.applyProjectionSnapshot(snapshot, archived: snapshot.projection.archived ?? false) == nil {
                    ignoredSnapshots += 1
                }
                if armed, didResetLocalPresentation(sessionID: snapshot.sessionId) { resets += 1 }
            case .sessionProjectionTransaction(let transaction):
                sessionID = sessionID ?? transaction.sessionId
                let armed = armLocalPresentation(sessionID: transaction.sessionId)
                let archived = mirroredArchived(for: transaction)
                if storage.applyAsyncTaskDetailTransaction(transaction) {
                    progressOnly += 1
                } else if storage.applyProjectionTransaction(transaction, archived: archived) == nil {
                    ignoredTransactions += 1
                }
                if armed, didResetLocalPresentation(sessionID: transaction.sessionId) { resets += 1 }
            default:
                Issue.record("\(scenario.name): unsupported conformance event \(envelope.id)")
            }
        }

        var outcome = Outcome()
        outcome.signals = [
            "localPresentationResets": resets,
            "progressOnlyTransactions": progressOnly,
            "ignoredTransactions": ignoredTransactions,
            "ignoredSnapshots": ignoredSnapshots,
        ]
        guard let sessionID, let store = storage.registry.existingSessionStore(sessionID: sessionID),
              case .loaded = store.metaStore.metadataState else {
            return outcome
        }
        outcome.sessionPresent = true
        outcome.queueModes = try ConformanceJSON.object([
            "steeringMode": ConformanceJSON.encoded(store.queueStore.queueModes.steeringMode),
            "followUpMode": ConformanceJSON.encoded(store.queueStore.queueModes.followUpMode),
        ])
        outcome.sections = try sections(of: store)
        return outcome
    }

    /// `clearLocallyOwnedProjectionPresentation()` is the reset the scenarios
    /// count. It is observable through the card's `isWritingReply`, so each
    /// event is applied with that flag raised and the drop is counted.
    private func armLocalPresentation(sessionID: String) -> Bool {
        guard let store = storage.registry.existingSessionStore(sessionID: sessionID),
              store.materializedSessionCard() != nil else { return false }
        store.replaceReplyWriting(true)
        return true
    }

    private func didResetLocalPresentation(sessionID: String) -> Bool {
        storage.registry.existingSessionStore(sessionID: sessionID)?.materializedSessionCard()?.isWritingReply == false
    }

    /// The archive flag is the client's optimistic-intent policy, which sits
    /// above the reducer. Mirroring the authoritative value keeps this runner
    /// on the reducer itself.
    private func mirroredArchived(for transaction: PickySessionProjectionTransaction) -> Bool {
        var archived = false
        if let store = storage.registry.existingSessionStore(sessionID: transaction.sessionId),
           case .loaded(let metadata) = store.metaStore.metadataState {
            archived = metadata.archived ?? false
        }
        for mutation in transaction.mutations {
            guard case .metaPatch(let patch) = mutation else { continue }
            switch patch.archived {
            case .unchanged: break
            case .clear: archived = false
            case .set(let value): archived = value
            }
        }
        return archived
    }

    private func sections(of store: PickySessionStore) throws -> [String: ConformanceJSON] {
        let artifacts = store.artifactStore
        let conversation = store.conversationStore
        return try [
            "meta": .section(store.metaStore.metadataState) { try ConformanceJSON.metadata($0) },
            "logs": .section(store.logStore.logsState) { try ConformanceJSON.encoded($0) },
            "tools": .section(store.toolStore.toolsState) { try ConformanceJSON.encoded($0) },
            "todo": .section(store.todoStore.todoState) { try ConformanceJSON.encoded($0) },
            "subagentRuns": .section(store.subagentStore.runsState) { try ConformanceJSON.encoded($0) },
            "asyncTaskDetail": .section(store.asyncTaskStore.detailState) { try ConformanceJSON.encoded($0) },
            "asyncControl": .section(store.asyncTaskStore.controlState) { try ConformanceJSON.encoded($0) },
            "artifacts": .section(artifacts.artifactsState) { try ConformanceJSON.encoded($0) },
            "changedFiles": .section(artifacts.changedFilesProjectionState) { try ConformanceJSON.encoded($0) },
            "messages": .section(conversation.messagesState) { try ConformanceJSON.encoded($0) },
            "messageJournalAvailable": .section(conversation.messageJournalAvailabilityState) { try ConformanceJSON.encoded($0) },
            "queue": .section(store.queueStore.queueState) { try ConformanceJSON.queue($0) },
            "activity": .section(store.activityStore.activityState) { try ConformanceJSON.encoded($0) },
            "extensionUiRequest": .section(store.extensionUiStore.requestState) { try ConformanceJSON.encoded($0) },
        ]
    }
}

private extension ProjectionConformanceRun.Outcome {
    /// Mirrors the TypeScript runner: an object compares only the keys the
    /// scenario lists, arrays must match in length and order, and `null` means
    /// "no value" because JSON cannot express absent versus undefined.
    func verify(against expectation: ConformanceJSON, scenarioName: String) throws {
        guard case .object(let expected) = expectation else {
            Issue.record("\(scenarioName): expect must be an object")
            return
        }
        if expected["sessionPresent"] == .bool(false) {
            #expect(!sessionPresent, "\(scenarioName): scenario expects no hydrated session")
            return
        }
        #expect(sessionPresent, "\(scenarioName): scenario expects a hydrated session")
        guard sessionPresent else { return }

        if case .object(let expectedSignals)? = expected["signals"] {
            for (signal, value) in expectedSignals {
                let actual = try #require(signals[signal], "\(scenarioName): unknown signal \(signal)")
                ConformanceJSON.number(Double(actual)).match(value, path: "\(scenarioName).signals.\(signal)")
            }
        }
        if let expectedModes = expected["queueModes"] {
            queueModes.match(expectedModes, path: "\(scenarioName).queueModes")
        }
        if case .object(let expectedSections)? = expected["sections"] {
            for (name, value) in expectedSections {
                let actual = try #require(sections[name], "\(scenarioName): unknown section \(name)")
                actual.match(value, path: "\(scenarioName).sections.\(name)")
            }
        }
    }
}

// MARK: - JSON comparison

private indirect enum ConformanceJSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ConformanceJSON])
    case object([String: ConformanceJSON])

    func match(_ expected: ConformanceJSON, path: String) {
        switch expected {
        case .null:
            #expect(self == .null, "\(path) should have no value, found \(self)")
        case .array(let expectedItems):
            guard case .array(let actualItems) = self else {
                Issue.record("\(path) should be an array, found \(self)")
                return
            }
            #expect(actualItems.count == expectedItems.count, "\(path) length: \(actualItems.count) != \(expectedItems.count)")
            guard actualItems.count == expectedItems.count else { return }
            for (index, item) in expectedItems.enumerated() {
                actualItems[index].match(item, path: "\(path)[\(index)]")
            }
        case .object(let expectedEntries):
            guard case .object(let actualEntries) = self else {
                Issue.record("\(path) should be an object, found \(self)")
                return
            }
            for (key, value) in expectedEntries {
                (actualEntries[key] ?? .null).match(value, path: "\(path).\(key)")
            }
        case .bool, .number, .string:
            #expect(self == expected, "\(path): \(self) != \(expected)")
        }
    }

    static func section<Value>(
        _ state: PickyProjectionSectionState<Value>,
        encode: (Value) throws -> ConformanceJSON
    ) rethrows -> ConformanceJSON {
        switch state {
        case .unavailable:
            return .object(["state": .string("unavailable")])
        case .loaded(let value):
            return .object(["state": .string("loaded"), "value": try encode(value)])
        }
    }

    /// Scalar session metadata has no wire type of its own, so it is projected
    /// field by field onto the manifest names the scenarios use.
    static func metadata(_ metadata: PickySessionMetadata) throws -> ConformanceJSON {
        try .object([
            "id": .string(metadata.id),
            "revision": .number(Double(metadata.revision)),
            "title": .string(metadata.title),
            "titleOrigin": encoded(metadata.titleOrigin),
            "status": encoded(metadata.status),
            "cwd": encoded(metadata.cwd),
            "piSessionFilePath": encoded(metadata.piSessionFilePath),
            "createdAt": encoded(metadata.createdAt),
            "updatedAt": encoded(metadata.updatedAt),
            "lastSummary": encoded(metadata.lastSummary),
            "thinkingPreview": encoded(metadata.thinkingPreview),
            "finalAnswer": encoded(metadata.finalAnswer),
            "contextUsage": encoded(metadata.contextUsage),
            "currentAssistantRun": encoded(metadata.currentAssistantRun),
            "notifyMainOnCompletion": encoded(metadata.notifyMainOnCompletion),
            "notifyMacOSOnCompletion": encoded(metadata.notifyMacOSOnCompletion),
            "fastMode": encoded(metadata.fastMode),
            "fastModeSupported": encoded(metadata.fastModeSupported),
            "runtimeRecovery": encoded(metadata.runtimeRecovery),
            "archived": encoded(metadata.archived),
            "archivedAt": encoded(metadata.archivedAt),
            "pinned": encoded(metadata.pinned),
            "lastRequest": encoded(metadata.lastRequest),
            "agentCycle": encoded(metadata.agentCycle),
            "asyncWorkSummary": encoded(metadata.asyncWorkSummary),
        ])
    }

    static func queue(_ projection: PickySessionQueueProjection) throws -> ConformanceJSON {
        try .object([
            "steers": encoded(projection.steers),
            "followUps": encoded(projection.followUps),
            "scheduled": encoded(projection.scheduled),
        ])
    }

    /// Round-trips a protocol value through the production encoder so the
    /// comparison sees exactly the wire shape the scenarios describe.
    static func encoded(_ value: some Encodable) throws -> ConformanceJSON {
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(["value": value])
        return try JSONDecoder().decode([String: ConformanceJSON].self, from: data)["value"] ?? .null
    }
}

extension ConformanceJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ConformanceJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ConformanceJSON].self))
        }
    }
}

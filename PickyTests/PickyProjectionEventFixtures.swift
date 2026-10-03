//
//  PickyProjectionEventFixtures.swift
//  PickyTests
//
//  Shared builders for projection v2 protocol events. The daemon only speaks
//  the v2 dialect, so tests that used to inject a v1 session payload hydrate a
//  session with `sessionProjectionSnapshot` and patch it with
//  `sessionProjectionTransaction`.
//
//  Revision bookkeeping lives on the instance, not in static storage: one
//  builder per test (Swift Testing makes a fresh suite value per test) keeps
//  the emitted cursor aligned with the view model that test created, even when
//  another suite runs concurrently with the same session IDs.
//

import Foundation
@testable import Picky

@MainActor
final class PickyProjectionEventFixtures {
    static let defaultEpoch = "epoch-test"

    struct Revisions: Equatable {
        let base: Int
        let revision: Int
    }

    let epoch: String
    private var revisionBySessionID: [String: Int] = [:]
    private var lastSeqBySessionID: [String: Int] = [:]
    private var snapshottedSessionIDs: Set<String> = []

    init(epoch: String = PickyProjectionEventFixtures.defaultEpoch) {
        self.epoch = epoch
    }

    // MARK: - Revision bookkeeping

    /// True once this builder has snapshotted the session, i.e. the receiving
    /// view model already has projection state a transaction can patch.
    /// Transactions emitted before that are buffered by the recovery
    /// coordinator and superseded by the next snapshot, which is what the
    /// daemon does for a frame that races ahead of bootstrap.
    func hasSnapshottedSession(_ sessionID: String) -> Bool {
        snapshottedSessionIDs.contains(sessionID)
    }

    /// Snapshots are authoritative at their serialized barrier, so each one
    /// advances the session revision and always installs. It also re-bases the
    /// `seq` mapping: a daemon that restarts and republishes a session starts
    /// its incremental counter over, and the snapshot is the barrier that makes
    /// the next low `seq` current again rather than stale.
    func nextSnapshotRevision(sessionID: String) -> Int {
        let next = (revisionBySessionID[sessionID] ?? 0) + 1
        revisionBySessionID[sessionID] = next
        snapshottedSessionIDs.insert(sessionID)
        lastSeqBySessionID[sessionID] = nil
        return next
    }

    /// Forgets that this builder ever snapshotted `sessionID`, so the next
    /// event for it is a fresh snapshot. Mirrors an authoritative membership
    /// removal followed by the daemon recreating the same session id.
    func forgetSession(_ sessionID: String) {
        snapshottedSessionIDs.remove(sessionID)
        lastSeqBySessionID[sessionID] = nil
    }

    /// Maps the v1 `seq` ordering contract onto v2 revisions. A newer `seq`
    /// chains `baseRevision` to the last emitted revision so the cursor applies
    /// it; a `seq` that is not newer produces a frame at or below the current
    /// revision, which the cursor drops exactly like a stale v1 `seq`.
    func transactionRevisions(sessionID: String, seq: Int? = nil) -> Revisions {
        let current = revisionBySessionID[sessionID] ?? 0
        guard let seq else { return advanceRevision(sessionID: sessionID, from: current) }
        if let lastSeq = lastSeqBySessionID[sessionID], seq <= lastSeq, current >= 1 {
            return Revisions(base: current - 1, revision: current)
        }
        lastSeqBySessionID[sessionID] = max(seq, lastSeqBySessionID[sessionID] ?? seq)
        return advanceRevision(sessionID: sessionID, from: current)
    }

    private func advanceRevision(sessionID: String, from current: Int) -> Revisions {
        revisionBySessionID[sessionID] = current + 1
        return Revisions(base: current, revision: current + 1)
    }

    // MARK: - Typed builders

    func snapshot(
        session: PickyAgentSession,
        revision: Int? = nil,
        complete: Bool = true,
        omittedFields: [String] = [],
        requestID: String? = nil
    ) -> PickySessionProjectionSnapshot {
        decode(
            PickySessionProjectionSnapshot.self,
            from: snapshotPayloadJSON(
                sessionID: session.id,
                projectionJSON: Self.encode(session),
                revision: revision,
                complete: complete,
                omittedFields: omittedFields,
                requestID: requestID
            )
        )
    }

    func snapshotEnvelope(
        id: String? = nil,
        session: PickyAgentSession,
        revision: Int? = nil,
        timestamp: Date = PickyProjectionEventFixtures.defaultTimestamp
    ) -> PickyEventEnvelope {
        let value = snapshot(session: session, revision: revision)
        return PickyEventEnvelope(
            id: id ?? "snapshot-\(session.id)-\(value.revision)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: timestamp,
            event: .sessionProjectionSnapshot(value)
        )
    }

    func transaction(
        sessionID: String,
        mutations: [String],
        seq: Int? = nil
    ) -> PickySessionProjectionTransaction {
        decode(
            PickySessionProjectionTransaction.self,
            from: transactionPayloadJSON(sessionID: sessionID, mutations: mutations, seq: seq)
        )
    }

    func transactionEnvelope(
        id: String? = nil,
        sessionID: String,
        mutations: [String],
        seq: Int? = nil,
        timestamp: Date = PickyProjectionEventFixtures.defaultTimestamp
    ) -> PickyEventEnvelope {
        let value = transaction(sessionID: sessionID, mutations: mutations, seq: seq)
        return PickyEventEnvelope(
            id: id ?? "transaction-\(sessionID)-\(value.revision)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: timestamp,
            event: .sessionProjectionTransaction(value)
        )
    }

    // MARK: - Event JSON builders

    /// Full `sessionProjectionSnapshot` event envelope JSON, for tests that
    /// exercise the decoder by feeding raw protocol text.
    func snapshotEventJSON(
        id: String? = nil,
        sessionID: String,
        projectionJSON: String,
        revision: Int? = nil,
        complete: Bool = true,
        omittedFields: [String] = [],
        requestID: String? = nil,
        timestamp: String = PickyProjectionEventFixtures.defaultTimestampText
    ) -> String {
        let payload = snapshotPayloadJSON(
            sessionID: sessionID,
            projectionJSON: projectionJSON,
            revision: revision,
            complete: complete,
            omittedFields: omittedFields,
            requestID: requestID
        )
        return Self.envelopeJSON(
            id: id ?? "snapshot-\(sessionID)",
            type: "sessionProjectionSnapshot",
            timestamp: timestamp,
            payload: payload
        )
    }

    /// Full `sessionProjectionTransaction` event envelope JSON.
    func transactionEventJSON(
        id: String? = nil,
        sessionID: String,
        mutations: [String],
        seq: Int? = nil,
        timestamp: String = PickyProjectionEventFixtures.defaultTimestampText
    ) -> String {
        let payload = transactionPayloadJSON(sessionID: sessionID, mutations: mutations, seq: seq)
        return Self.envelopeJSON(
            id: id ?? "transaction-\(sessionID)",
            type: "sessionProjectionTransaction",
            timestamp: timestamp,
            payload: payload
        )
    }

    private func snapshotPayloadJSON(
        sessionID: String,
        projectionJSON: String,
        revision: Int?,
        complete: Bool,
        omittedFields: [String],
        requestID: String?
    ) -> String {
        let resolvedRevision = revision ?? nextSnapshotRevision(sessionID: sessionID)
        revisionBySessionID[sessionID] = max(revisionBySessionID[sessionID] ?? 0, resolvedRevision)
        snapshottedSessionIDs.insert(sessionID)
        lastSeqBySessionID[sessionID] = nil
        let encodedRequestID = requestID.map { "\"requestId\":\(Self.encodeString($0))," } ?? ""
        return """
        \(encodedRequestID)"sessionId":\(Self.encodeString(sessionID)),"epoch":\(Self.encodeString(epoch)),"revision":\(resolvedRevision),"complete":\(complete),"omittedFields":\(Self.encodeStrings(omittedFields)),"projection":\(projectionJSON)
        """
    }

    private func transactionPayloadJSON(sessionID: String, mutations: [String], seq: Int?) -> String {
        let revisions = transactionRevisions(sessionID: sessionID, seq: seq)
        return """
        "sessionId":\(Self.encodeString(sessionID)),"epoch":\(Self.encodeString(epoch)),"baseRevision":\(revisions.base),"revision":\(revisions.revision),"mutations":[\(mutations.joined(separator: ","))]
        """
    }

    private static func envelopeJSON(id: String, type: String, timestamp: String, payload: String) -> String {
        """
        {"id":\(encodeString(id)),"protocolVersion":"\(pickyAgentProtocolVersion)","timestamp":\(encodeString(timestamp)),"type":"\(type)",\(payload)}
        """
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from payload: String) -> Value {
        try! JSONDecoder.pickyAgentProtocolDecoder().decode(type, from: Data("{\(payload)}".utf8))
    }

    // MARK: - Mutation JSON helpers

    static func metaPatchMutation(_ fields: String) -> String {
        "{\"type\":\"metaPatch\",\"patch\":{\(fields)}}"
    }

    static func messageAppendMutation(_ message: PickySessionMessage) -> String {
        "{\"type\":\"messageAppend\",\"message\":\(encode(message))}"
    }

    static func messagesImportMutation(_ messages: [PickySessionMessage]) -> String {
        "{\"type\":\"messagesImport\",\"messages\":\(encode(messages))}"
    }

    static func messageReplaceMutation(messageID: String, message: PickySessionMessage) -> String {
        "{\"type\":\"messageReplace\",\"messageId\":\(encodeString(messageID)),\"message\":\(encode(message))}"
    }

    static func messageRemoveMutation(messageID: String) -> String {
        "{\"type\":\"messageRemove\",\"messageId\":\(encodeString(messageID))}"
    }

    static func toolUpsertMutation(_ tool: PickyToolActivity) -> String {
        "{\"type\":\"toolUpsert\",\"tool\":\(encode(tool))}"
    }

    static func artifactUpsertMutation(_ artifact: PickyArtifact) -> String {
        "{\"type\":\"artifactUpsert\",\"artifact\":\(encode(artifact))}"
    }

    static func activitySetMutation(_ activity: PickyActivitySummary) -> String {
        "{\"type\":\"activitySet\",\"activitySummary\":\(encode(activity))}"
    }

    static func logAppendMutation(_ line: String) -> String {
        "{\"type\":\"logAppend\",\"line\":\(encodeString(line))}"
    }

    static func subagentRunsSetMutation(_ runs: [PickySubagentRun]) -> String {
        "{\"type\":\"subagentRunsSet\",\"runs\":\(encode(runs))}"
    }

    static func finalAnswerSetMutation(_ finalAnswer: String?) -> String {
        "{\"type\":\"finalAnswerSet\",\"finalAnswer\":\(finalAnswer.map(encodeString) ?? "null")}"
    }

    // MARK: - Encoding helpers

    static let defaultTimestamp = Date(timeIntervalSince1970: 1_787_544_000)
    static let defaultTimestampText = "2026-08-25T00:00:00.000Z"

    static func encodeString(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    static func encodeStrings(_ values: [String]) -> String {
        String(decoding: try! JSONEncoder().encode(values), as: UTF8.self)
    }

    static func encode<Value: Encodable>(_ value: Value) -> String {
        String(decoding: try! JSONEncoder.pickyAgentProtocolEncoder().encode(value), as: UTF8.self)
    }
}

//
//  PickySessionComposerDraftController.swift
//  Picky
//
//  Owns composer draft persistence, attachment draft persistence, and pending
//  draft requests for the session list facade. The ViewModel remains the
//  ObservableObject and selection side-effect owner.
//

import Foundation

struct PickyComposerDraftRequest: Equatable, Identifiable {
    let id: String
    let text: String
}

enum PickyQueuedInputDraftPolicy {
    static func queuedInputText(
        queuedSteers: [PickyQueueItem],
        queuedFollowUps: [PickyQueueItem],
        kind: PickyQueueClearKind = .all
    ) -> String? {
        let selected: [PickyQueueItem]
        switch kind {
        case .steering:
            selected = queuedSteers
        case .followUp:
            selected = queuedFollowUps
        case .all:
            selected = queuedSteers + queuedFollowUps
        }
        let merged = selected
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return merged.isEmpty ? nil : merged
    }

    static func draftRestoringQueuedInputs(
        draft: String,
        queuedSteers: [PickyQueueItem],
        queuedFollowUps: [PickyQueueItem],
        kind: PickyQueueClearKind = .all
    ) -> String? {
        guard let queuedText = queuedInputText(
            queuedSteers: queuedSteers,
            queuedFollowUps: queuedFollowUps,
            kind: kind
        ) else { return nil }
        return draft.isEmpty ? queuedText : "\(draft)\n\n\(queuedText)"
    }
}

@MainActor
final class PickySessionComposerDraftController {
    enum RequestKind: String {
        case append
        case replace
    }

    private let draftStore: PickyComposerDraftStoring
    private let attachmentStore: PickyComposerAttachmentDraftStoring
    private let fileExists: (String) -> Bool
    private let makeRequestID: (RequestKind) -> String

    private(set) var requestsBySessionID: [String: PickyComposerDraftRequest] = [:]

    init(
        draftStore: PickyComposerDraftStoring,
        attachmentStore: PickyComposerAttachmentDraftStoring,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        makeRequestID: @escaping (RequestKind) -> String = { kind in "draft-\(kind.rawValue)-\(UUID().uuidString)" }
    ) {
        self.draftStore = draftStore
        self.attachmentStore = attachmentStore
        self.fileExists = fileExists
        self.makeRequestID = makeRequestID
    }

    func request(for sessionID: String) -> PickyComposerDraftRequest? {
        requestsBySessionID[sessionID]
    }

    func consumeRequest(sessionID: String, requestID: String) {
        guard requestsBySessionID[sessionID]?.id == requestID else { return }
        requestsBySessionID[sessionID] = nil
    }

    func persistedDraft(for sessionID: String) -> String {
        draftStore.draft(for: sessionID) ?? ""
    }

    func updateDraft(_ draft: String, sessionID: String) {
        draftStore.setDraft(draft, for: sessionID)
    }

    func persistedAttachmentPaths(for sessionID: String) -> [String] {
        attachmentStore.attachmentPaths(for: sessionID).filter(fileExists)
    }

    func updateAttachmentPaths(_ paths: [String], sessionID: String) {
        attachmentStore.setAttachmentPaths(paths, for: sessionID)
    }

    func clearDraft(sessionID: String) {
        requestsBySessionID[sessionID] = nil
        draftStore.setDraft(nil, for: sessionID)
        attachmentStore.setAttachmentPaths([], for: sessionID)
    }

    @discardableResult
    func appendText(_ text: String, sessionID: String) -> Bool {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return false }
        let existing = draftStore.draft(for: sessionID) ?? ""
        let merged: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged = incoming
        } else {
            merged = existing + "\n\n" + incoming
        }
        requestsBySessionID[sessionID] = PickyComposerDraftRequest(id: makeRequestID(.append), text: merged)
        draftStore.setDraft(merged, for: sessionID)
        return true
    }

    @discardableResult
    func replaceText(_ text: String, sessionID: String) -> Bool {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return false }
        requestsBySessionID[sessionID] = PickyComposerDraftRequest(id: makeRequestID(.replace), text: incoming)
        draftStore.setDraft(incoming, for: sessionID)
        return true
    }

    func primeRequest(sessionID: String, requestID: String, text: String) {
        requestsBySessionID[sessionID] = PickyComposerDraftRequest(id: requestID, text: text)
        draftStore.setDraft(text, for: sessionID)
    }

    func prune(knownSessionIDs: Set<String>) {
        requestsBySessionID = requestsBySessionID.filter { knownSessionIDs.contains($0.key) }
        // Empty session snapshots can be transient during reconnects/daemon resets. Treat
        // them as non-authoritative for persisted composer data so unsent user drafts do
        // not disappear before the next real snapshot rehydrates the Pickle list.
        guard !knownSessionIDs.isEmpty else { return }
        draftStore.prune(knownSessionIDs: knownSessionIDs)
        attachmentStore.prune(knownSessionIDs: knownSessionIDs)
    }
}

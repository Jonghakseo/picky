//
//  PickySessionComposerDraftController.swift
//  Picky
//
//  Owns composer draft persistence, attachment draft persistence, and pending
//  draft requests for the session list facade. The ViewModel remains the
//  ObservableObject and selection side-effect owner.
//

import Combine
import Foundation

struct PickyComposerDraftRequest: Equatable, Identifiable {
    let id: String
    let text: String
}

enum PickyQueuedInputRestoreAvailability: Equatable {
    case unavailable
    case available
    case blockedByScreenContext(attachedImagesCount: Int)

    static func resolve(
        visibleQueue: PickyVisibleQueue,
        kind: PickyQueueClearKind = .all
    ) -> Self {
        let items = visibleQueue.items(for: kind)
        guard !items.isEmpty else { return .unavailable }
        let attachedImagesCount = items.reduce(0) { partialResult, item in
            partialResult + max(0, item.attachedImagesCount ?? 0)
        }
        return attachedImagesCount > 0
            ? .blockedByScreenContext(attachedImagesCount: attachedImagesCount)
            : .available
    }
}

enum PickyQueuedInputRestoreError: LocalizedError, Equatable {
    case blockedByScreenContext(attachedImagesCount: Int)

    var errorDescription: String? {
        switch self {
        case .blockedByScreenContext(let attachedImagesCount):
            L10n.t("hud.queue.restore.blockedByScreenContext.error", Int64(attachedImagesCount))
        }
    }
}

enum PickyQueuedInputDraftPolicy {
    static func queuedInputText(
        visibleQueue: PickyVisibleQueue,
        kind: PickyQueueClearKind = .all
    ) -> String? {
        let merged = visibleQueue.items(for: kind)
            .map { PickyQueuedInputText.displayText(from: $0.text) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return merged.isEmpty ? nil : merged
    }

    static func draftRestoringQueuedInputs(
        draft: String,
        visibleQueue: PickyVisibleQueue,
        kind: PickyQueueClearKind = .all
    ) -> String? {
        guard let queuedText = queuedInputText(visibleQueue: visibleQueue, kind: kind) else { return nil }
        return draft.isEmpty ? queuedText : "\(draft)\n\n\(queuedText)"
    }
}

@MainActor
final class PickySessionComposerDraftController {
    enum RequestKind: String {
        case append
        case replace
    }

#if compiler(>=6.2)
    /// See `PickySessionDockLayoutController.deinit` for why every `@MainActor`
    /// class an XCTest suite releases inline opts out of the synthesized
    /// isolated deinit (swiftlang/swift#87316, #88036).
    nonisolated deinit {}
#endif

    private let draftStore: PickyComposerDraftStoring
    private let attachmentStore: PickyComposerAttachmentDraftStoring
    private let fileExists: (String) -> Bool
    private let makeRequestID: (RequestKind) -> String
    private let draftPersistDelay: Duration

    /// Typed drafts awaiting a coalesced store write. Reads consult this first,
    /// so deferring the write never changes what callers observe. The store is
    /// UserDefaults-backed and each write re-encodes every session's draft, so
    /// writing per keystroke is both wasteful and a re-render trigger for any
    /// view watching the defaults domain.
    private var pendingDrafts: [String: String] = [:]
    private var draftFlushTask: Task<Void, Never>?

    @Published private(set) var requestsBySessionID: [String: PickyComposerDraftRequest] = [:]

    init(
        draftStore: PickyComposerDraftStoring,
        attachmentStore: PickyComposerAttachmentDraftStoring,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        makeRequestID: @escaping (RequestKind) -> String = { kind in "draft-\(kind.rawValue)-\(UUID().uuidString)" },
        draftPersistDelay: Duration = .milliseconds(500)
    ) {
        self.draftStore = draftStore
        self.attachmentStore = attachmentStore
        self.fileExists = fileExists
        self.makeRequestID = makeRequestID
        self.draftPersistDelay = draftPersistDelay
    }

    func request(for sessionID: String) -> PickyComposerDraftRequest? {
        requestsBySessionID[sessionID]
    }

    func requestPublisher(for sessionID: String) -> AnyPublisher<PickyComposerDraftRequest?, Never> {
        $requestsBySessionID
            .map { $0[sessionID] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func consumeRequest(sessionID: String, requestID: String) {
        guard requestsBySessionID[sessionID]?.id == requestID else { return }
        requestsBySessionID[sessionID] = nil
    }

    func persistedDraft(for sessionID: String) -> String {
        pendingDrafts[sessionID] ?? draftStore.draft(for: sessionID) ?? ""
    }

    /// Coalesces keystroke-rate updates into one store write after typing
    /// pauses. Call `flushPendingDrafts()` before the process exits.
    func updateDraft(_ draft: String, sessionID: String) {
        pendingDrafts[sessionID] = draft
        draftFlushTask?.cancel()
        let delay = draftPersistDelay
        draftFlushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushPendingDrafts()
        }
    }

    func flushPendingDrafts() {
        draftFlushTask?.cancel()
        draftFlushTask = nil
        let pending = pendingDrafts
        pendingDrafts = [:]
        for (sessionID, draft) in pending {
            draftStore.setDraft(draft, for: sessionID)
        }
    }

    /// Direct writes supersede a pending typed draft; dropping it prevents a
    /// later flush from resurrecting stale text over the explicit value.
    private func writeDraftNow(_ draft: String?, sessionID: String) {
        pendingDrafts[sessionID] = nil
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
        writeDraftNow(nil, sessionID: sessionID)
        attachmentStore.setAttachmentPaths([], for: sessionID)
    }

    @discardableResult
    func appendText(_ text: String, sessionID: String) -> Bool {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return false }
        let existing = persistedDraft(for: sessionID)
        let merged: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged = incoming
        } else {
            merged = existing + "\n\n" + incoming
        }
        requestsBySessionID[sessionID] = PickyComposerDraftRequest(id: makeRequestID(.append), text: merged)
        writeDraftNow(merged, sessionID: sessionID)
        return true
    }

    @discardableResult
    func replaceText(_ text: String, sessionID: String) -> Bool {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return false }
        requestsBySessionID[sessionID] = PickyComposerDraftRequest(id: makeRequestID(.replace), text: incoming)
        writeDraftNow(incoming, sessionID: sessionID)
        return true
    }

    func primeRequest(sessionID: String, requestID: String, text: String) {
        requestsBySessionID[sessionID] = PickyComposerDraftRequest(id: requestID, text: text)
        writeDraftNow(text, sessionID: sessionID)
    }

    func prune(knownSessionIDs: Set<String>) {
        requestsBySessionID = requestsBySessionID.filter { knownSessionIDs.contains($0.key) }
        // Empty session snapshots can be transient during reconnects/daemon resets. Treat
        // them as non-authoritative for persisted composer data so unsent user drafts do
        // not disappear before the next real snapshot rehydrates the Pickle list.
        guard !knownSessionIDs.isEmpty else { return }
        pendingDrafts = pendingDrafts.filter { knownSessionIDs.contains($0.key) }
        draftStore.prune(knownSessionIDs: knownSessionIDs)
        attachmentStore.prune(knownSessionIDs: knownSessionIDs)
    }
}

//
//  PickySessionComposerDraftControllerTests.swift
//  PickyTests
//
//  Characterization coverage for the composer-draft controller that owns
//  draft persistence, attachment persistence, pending request state, and
//  ViewModel-facing draft mutations.
//

import XCTest
@testable import Picky

@MainActor
final class PickySessionComposerDraftControllerTests: XCTestCase {
    func testPersistedDraftAndAttachmentPathsReadThroughStores() {
        let draftStore = FakeControllerComposerDraftStore(drafts: ["session-1": "saved draft"])
        let attachmentStore = FakeControllerComposerAttachmentDraftStore(attachments: [
            "session-1": ["/tmp/exists.png", "/tmp/missing.png"]
        ])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: attachmentStore,
            fileExists: { $0 == "/tmp/exists.png" }
        )

        XCTAssertEqual(controller.persistedDraft(for: "session-1"), "saved draft")
        XCTAssertEqual(controller.persistedDraft(for: "unknown"), "")
        XCTAssertEqual(controller.persistedAttachmentPaths(for: "session-1"), ["/tmp/exists.png"])
    }

    func testUpdateDraftAndAttachmentPathsWriteThroughStores() {
        let draftStore = FakeControllerComposerDraftStore()
        let attachmentStore = FakeControllerComposerAttachmentDraftStore()
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: attachmentStore
        )

        controller.updateDraft("hello", sessionID: "session-1")
        controller.updateAttachmentPaths(["/tmp/a.png", " /tmp/b.png "], sessionID: "session-1")

        XCTAssertEqual(draftStore.drafts["session-1"], "hello")
        XCTAssertEqual(attachmentStore.attachments["session-1"], ["/tmp/a.png", " /tmp/b.png "])
    }

    func testAppendTextTrimsMergesExistingDraftCreatesRequestAndPersists() {
        let draftStore = FakeControllerComposerDraftStore(drafts: ["session-1": "기존 메모"])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: FakeControllerComposerAttachmentDraftStore(),
            makeRequestID: { kind in "\(kind.rawValue)-id" }
        )

        let didAppend = controller.appendText("  /tmp/picky/shot-1.jpg\n이거 보여?  ", sessionID: "session-1")

        let expected = "기존 메모\n\n/tmp/picky/shot-1.jpg\n이거 보여?"
        XCTAssertTrue(didAppend)
        XCTAssertEqual(controller.request(for: "session-1"), PickyComposerDraftRequest(id: "append-id", text: expected))
        XCTAssertEqual(draftStore.drafts["session-1"], expected)
    }

    func testAppendTextIgnoresWhitespaceOnlyInput() {
        let draftStore = FakeControllerComposerDraftStore(drafts: ["session-1": "keep"])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: FakeControllerComposerAttachmentDraftStore()
        )

        XCTAssertFalse(controller.appendText(" \n\t ", sessionID: "session-1"))

        XCTAssertNil(controller.request(for: "session-1"))
        XCTAssertEqual(draftStore.drafts["session-1"], "keep")
    }

    func testReplaceTextTrimsCreatesRequestAndPersists() {
        let draftStore = FakeControllerComposerDraftStore(drafts: ["session-1": "old"])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: FakeControllerComposerAttachmentDraftStore(),
            makeRequestID: { kind in "\(kind.rawValue)-id" }
        )

        XCTAssertTrue(controller.replaceText("  revised message  ", sessionID: "session-1"))

        XCTAssertEqual(controller.request(for: "session-1"), PickyComposerDraftRequest(id: "replace-id", text: "revised message"))
        XCTAssertEqual(draftStore.drafts["session-1"], "revised message")
    }

    func testClearDraftRemovesRequestDraftAndAttachmentsForOneSession() {
        let draftStore = FakeControllerComposerDraftStore(drafts: [
            "session-1": "remove",
            "session-2": "keep"
        ])
        let attachmentStore = FakeControllerComposerAttachmentDraftStore(attachments: [
            "session-1": ["/tmp/remove.png"],
            "session-2": ["/tmp/keep.png"]
        ])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: attachmentStore,
            makeRequestID: { _ in "request-id" }
        )
        XCTAssertTrue(controller.replaceText("remove", sessionID: "session-1"))

        controller.clearDraft(sessionID: "session-1")

        XCTAssertNil(controller.request(for: "session-1"))
        XCTAssertNil(draftStore.drafts["session-1"])
        XCTAssertEqual(draftStore.drafts["session-2"], "keep")
        XCTAssertNil(attachmentStore.attachments["session-1"])
        XCTAssertEqual(attachmentStore.attachments["session-2"], ["/tmp/keep.png"])
    }

    func testConsumeRequestClearsOnlyMatchingRequestID() {
        let controller = PickySessionComposerDraftController(
            draftStore: FakeControllerComposerDraftStore(),
            attachmentStore: FakeControllerComposerAttachmentDraftStore(),
            makeRequestID: { _ in "current-id" }
        )
        XCTAssertTrue(controller.replaceText("draft", sessionID: "session-1"))

        controller.consumeRequest(sessionID: "session-1", requestID: "stale-id")
        XCTAssertNotNil(controller.request(for: "session-1"))

        controller.consumeRequest(sessionID: "session-1", requestID: "current-id")
        XCTAssertNil(controller.request(for: "session-1"))
    }

    func testPruneWithEmptyKnownSessionIDsKeepsPersistedDraftsAndAttachments() {
        let draftStore = FakeControllerComposerDraftStore(drafts: [
            "session-1": "unsent draft"
        ])
        let attachmentStore = FakeControllerComposerAttachmentDraftStore(attachments: [
            "session-1": ["/tmp/unsent.png"]
        ])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: attachmentStore,
            makeRequestID: { _ in "request-id" }
        )
        controller.primeRequest(sessionID: "session-1", requestID: "request-id", text: "unsent draft")

        controller.prune(knownSessionIDs: [])

        XCTAssertNil(controller.request(for: "session-1"))
        XCTAssertNil(draftStore.prunedKnownSessionIDs)
        XCTAssertNil(attachmentStore.prunedKnownSessionIDs)
        XCTAssertEqual(draftStore.drafts, ["session-1": "unsent draft"])
        XCTAssertEqual(attachmentStore.attachments, ["session-1": ["/tmp/unsent.png"]])
    }

    func testPrimeAndPruneRequestsAndStores() {
        let draftStore = FakeControllerComposerDraftStore(drafts: [
            "keep": "keep draft",
            "remove": "remove draft"
        ])
        let attachmentStore = FakeControllerComposerAttachmentDraftStore(attachments: [
            "keep": ["/tmp/keep.png"],
            "remove": ["/tmp/remove.png"]
        ])
        let controller = PickySessionComposerDraftController(
            draftStore: draftStore,
            attachmentStore: attachmentStore,
            makeRequestID: { _ in "unused" }
        )
        controller.primeRequest(sessionID: "keep", requestID: "request-keep", text: "keep request")
        controller.primeRequest(sessionID: "remove", requestID: "request-remove", text: "remove request")

        controller.prune(knownSessionIDs: ["keep"])

        XCTAssertEqual(controller.request(for: "keep"), PickyComposerDraftRequest(id: "request-keep", text: "keep request"))
        XCTAssertNil(controller.request(for: "remove"))
        XCTAssertEqual(draftStore.prunedKnownSessionIDs, ["keep"])
        XCTAssertEqual(attachmentStore.prunedKnownSessionIDs, ["keep"])
        XCTAssertEqual(draftStore.drafts, ["keep": "keep request"])
        XCTAssertEqual(attachmentStore.attachments, ["keep": ["/tmp/keep.png"]])
    }
}

private final class FakeControllerComposerDraftStore: PickyComposerDraftStoring {
    var drafts: [String: String]
    var prunedKnownSessionIDs: Set<String>?

    init(drafts: [String: String] = [:]) {
        self.drafts = drafts
    }

    func draft(for sessionID: String) -> String? {
        drafts[sessionID]
    }

    func setDraft(_ draft: String?, for sessionID: String) {
        if let draft, !draft.isEmpty {
            drafts[sessionID] = draft
        } else {
            drafts.removeValue(forKey: sessionID)
        }
    }

    func prune(knownSessionIDs: Set<String>) {
        prunedKnownSessionIDs = knownSessionIDs
        drafts = drafts.filter { knownSessionIDs.contains($0.key) }
    }
}

private final class FakeControllerComposerAttachmentDraftStore: PickyComposerAttachmentDraftStoring {
    var attachments: [String: [String]]
    var prunedKnownSessionIDs: Set<String>?

    init(attachments: [String: [String]] = [:]) {
        self.attachments = attachments
    }

    func attachmentPaths(for sessionID: String) -> [String] {
        attachments[sessionID] ?? []
    }

    func setAttachmentPaths(_ paths: [String], for sessionID: String) {
        if paths.isEmpty {
            attachments.removeValue(forKey: sessionID)
        } else {
            attachments[sessionID] = paths
        }
    }

    func prune(knownSessionIDs: Set<String>) {
        prunedKnownSessionIDs = knownSessionIDs
        attachments = attachments.filter { knownSessionIDs.contains($0.key) }
    }
}

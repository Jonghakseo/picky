//
//  PickyComposerDraftStoreTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyComposerDraftStoreTests {
    @Test func userDefaultsStorePersistsClearsAndPrunesDraftsBySessionID() throws {
        let suiteName = "PickyComposerDraftStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PickyUserDefaultsComposerDraftStore(defaults: defaults)
        store.setDraft("review this change", for: "session-1")
        store.setDraft("follow-up", for: "session-2")

        let reloaded = PickyUserDefaultsComposerDraftStore(defaults: defaults)
        #expect(reloaded.draft(for: "session-1") == "review this change")
        #expect(reloaded.draft(for: "session-2") == "follow-up")

        reloaded.setDraft("", for: "session-2")
        #expect(reloaded.draft(for: "session-2") == nil)

        reloaded.prune(knownSessionIDs: ["session-1"])
        #expect(reloaded.draft(for: "session-1") == "review this change")

        reloaded.prune(knownSessionIDs: [])
        #expect(reloaded.draft(for: "session-1") == nil)
    }

    @Test func sessionNoteStorePersistsAndClearsNotesBySessionID() throws {
        let suiteName = "PickySessionNoteStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PickyUserDefaultsSessionNoteStore(defaults: defaults)
        store.setNote("release checklist", for: "session-1")
        store.setNote("qa notes", for: "session-2")

        let reloaded = PickyUserDefaultsSessionNoteStore(defaults: defaults)
        #expect(reloaded.note(for: "session-1") == "release checklist")
        #expect(reloaded.note(for: "session-2") == "qa notes")

        reloaded.setNote("", for: "session-2")
        #expect(reloaded.note(for: "session-2") == nil)
        #expect(reloaded.note(for: "session-1") == "release checklist")
    }

    @Test func attachmentStorePersistsClearsAndPrunesPathsBySessionID() throws {
        let suiteName = "PickyComposerAttachmentDraftStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PickyUserDefaultsComposerAttachmentDraftStore(defaults: defaults)
        #expect(store.attachmentPaths(for: "session-1").isEmpty)

        store.setAttachmentPaths(["/tmp/a.png", "/tmp/b.txt"], for: "session-1")
        store.setAttachmentPaths(["  /tmp/c.log  ", ""], for: "session-2")

        let reloaded = PickyUserDefaultsComposerAttachmentDraftStore(defaults: defaults)
        #expect(reloaded.attachmentPaths(for: "session-1") == ["/tmp/a.png", "/tmp/b.txt"])
        // Empty/whitespace entries are dropped and surrounding whitespace trimmed.
        #expect(reloaded.attachmentPaths(for: "session-2") == ["/tmp/c.log"])

        // Setting an empty list clears the entry entirely.
        reloaded.setAttachmentPaths([], for: "session-1")
        #expect(reloaded.attachmentPaths(for: "session-1").isEmpty)

        // Prune drops anything not in the known set.
        reloaded.prune(knownSessionIDs: ["session-2"])
        #expect(reloaded.attachmentPaths(for: "session-2") == ["/tmp/c.log"])

        reloaded.prune(knownSessionIDs: [])
        #expect(reloaded.attachmentPaths(for: "session-2").isEmpty)
    }
}

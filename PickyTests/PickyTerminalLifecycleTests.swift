//
//  PickyTerminalLifecycleTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyTerminalLifecycleTests {
    @Test func terminalModelOwnsProcessDelegateWithoutRetainCycle() {
        weak var retainedDelegate: PickyTerminalProcessDelegate?

        do {
            let model = PickyTerminalModel(
                title: "Session",
                sessionFilePath: "/tmp/session.jsonl",
                cwd: "/tmp"
            )
            retainedDelegate = model.processDelegate
            #expect(retainedDelegate != nil)
        }

        #expect(retainedDelegate == nil)
    }

    @Test func shellModelOwnsProcessDelegateWithoutRetainCycle() {
        weak var retainedDelegate: PickyTerminalProcessDelegate?

        do {
            let model = PickyShellTerminalModel(
                title: "Shell",
                cwd: "/tmp"
            )
            retainedDelegate = model.processDelegate
            #expect(retainedDelegate != nil)
        }

        #expect(retainedDelegate == nil)
    }

    @Test func closingRecordLeavesActiveLookupBeforeProcessCleanupFinishes() throws {
        let store = PickyTerminalOverlayRecordStore<RecordToken>()
        let firstRecord = RecordToken()
        let firstID = ObjectIdentifier(firstRecord)
        store.insert(firstRecord, sessionID: "session-1", recordID: firstID)

        #expect(store.beginClosing(sessionID: "session-1", recordID: firstID))
        #expect(store.activeRecord(sessionID: "session-1") == nil)
        #expect(store.isClosing(recordID: firstID))

        let replacement = RecordToken()
        store.insert(replacement, sessionID: "session-1", recordID: ObjectIdentifier(replacement))
        store.finishClosing(recordID: firstID)

        let active = try #require(store.activeRecord(sessionID: "session-1"))
        #expect(active === replacement)
        #expect(!store.isClosing(recordID: firstID))
    }

    @Test func staleCloseCannotMoveReplacementRecordIntoClosingState() {
        let store = PickyTerminalOverlayRecordStore<RecordToken>()
        let firstRecord = RecordToken()
        let replacement = RecordToken()
        let firstID = ObjectIdentifier(firstRecord)
        let replacementID = ObjectIdentifier(replacement)

        store.insert(firstRecord, sessionID: "session-1", recordID: firstID)
        store.insert(replacement, sessionID: "session-1", recordID: replacementID)

        #expect(!store.beginClosing(sessionID: "session-1", recordID: firstID))
        #expect(store.activeRecord(sessionID: "session-1") === replacement)
        #expect(!store.isClosing(recordID: firstID))
    }
}

private final class RecordToken {}

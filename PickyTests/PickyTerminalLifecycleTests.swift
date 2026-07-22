//
//  PickyTerminalLifecycleTests.swift
//  PickyTests
//

import Darwin
import Foundation
import SwiftTerm
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

    @Test func closingSessionCallbackWaitsForActualRecordCleanup() {
        let store = PickyTerminalOverlayRecordStore<RecordToken>()
        let record = RecordToken()
        let recordID = ObjectIdentifier(record)
        store.insert(record, sessionID: "session-1", recordID: recordID)
        #expect(store.beginClosing(sessionID: "session-1", recordID: recordID))
        var callbackCount = 0

        store.onceClosingFinished(sessionID: "session-1") { callbackCount += 1 }

        #expect(store.isClosing(sessionID: "session-1"))
        #expect(callbackCount == 0)
        store.finishClosing(recordID: recordID)
        #expect(!store.isClosing(sessionID: "session-1"))
        #expect(callbackCount == 1)
    }

    @Test func terminalClosedBeforeDelayedAttachmentNeverStartsAProcess() {
        let model = PickyTerminalModel(
            title: "Terminal",
            sessionFilePath: "/tmp/session.jsonl",
            cwd: "/tmp"
        )
        let host = TerminalProcessHostStub(processID: 42)

        model.close()
        model.attachProcessHostForTesting(host)

        #expect(host.startCount == 0)
        #expect(host.processDelegate == nil)
    }

    @Test func terminalStartWithoutAProcessIDDoesNotHoldTheClosingGate() {
        let model = PickyTerminalModel(
            title: "Terminal",
            sessionFilePath: "/tmp/session.jsonl",
            cwd: "/tmp"
        )
        let host = TerminalProcessHostStub(processID: 0)
        var callbackCount = 0

        model.attachProcessHostForTesting(host)
        model.scheduleAfterActualProcessExit { callbackCount += 1 }

        #expect(host.startCount == 1)
        #expect(callbackCount == 1)
    }

    @Test func terminalCloseRetainsExitObservationUntilTheProcessActuallyExits() {
        var signals: [Int32] = []
        let terminator = PickyTerminalProcessTerminator(
            forceKillDelayNanoseconds: 1_000_000_000,
            signalProcess: { _, signal in signals.append(signal) }
        )
        let model = PickyTerminalModel(
            title: "Terminal",
            sessionFilePath: "/tmp/session.jsonl",
            cwd: "/tmp",
            processTerminator: terminator
        )
        var host: TerminalProcessHostStub? = TerminalProcessHostStub(processID: 42)
        weak var weakHost = host
        model.attachProcessHostForTesting(host!)
        var exitCallbackCount = 0
        model.scheduleAfterActualProcessExit { exitCallbackCount += 1 }

        model.close()
        host = nil

        #expect(signals == [SIGTERM])
        #expect(exitCallbackCount == 0)
        #expect(weakHost != nil)

        model.processExited(exitCode: 0)

        #expect(exitCallbackCount == 1)
        #expect(weakHost == nil)
    }

    @Test func terminalTerminatorEscalatesAndCancelsForceKillAfterObservedExit() async throws {
        var signals: [Int32] = []
        let identity = PickyTerminalProcessIdentity(startSeconds: 1, startMicroseconds: 2)
        let terminator = PickyTerminalProcessTerminator(
            forceKillDelayNanoseconds: 10_000_000,
            signalProcess: { _, signal in signals.append(signal) },
            processIdentity: { _ in identity }
        )
        terminator.terminate(processID: 42)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(signals == [SIGTERM, SIGKILL])

        signals.removeAll()
        terminator.terminate(processID: 43)
        terminator.processExited()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(signals == [SIGTERM])
    }

    @Test func terminalTerminatorDoesNotSignalAReusedPID() async throws {
        var signals: [Int32] = []
        var identity = PickyTerminalProcessIdentity(startSeconds: 1, startMicroseconds: 2)
        let terminator = PickyTerminalProcessTerminator(
            forceKillDelayNanoseconds: 10_000_000,
            signalProcess: { _, signal in signals.append(signal) },
            processIdentity: { _ in identity }
        )

        terminator.terminate(processID: 42)
        identity = PickyTerminalProcessIdentity(startSeconds: 3, startMicroseconds: 4)
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(signals == [SIGTERM])
    }

    @Test func processStartGateDefersAndCancelsPendingStarts() {
        let gate = PickyTerminalProcessStartGate()
        var starts: [String] = []
        gate.hold()

        gate.runWhenOpen { starts.append("first") }
        gate.runWhenOpen { starts.append("replacement") }
        #expect(starts.isEmpty)

        gate.open()
        #expect(starts == ["replacement"])

        gate.hold()
        gate.runWhenOpen { starts.append("cancelled") }
        gate.cancelPendingStart()
        gate.open()
        #expect(starts == ["replacement"])
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

@MainActor
private final class TerminalProcessHostStub: PickyTerminalProcessHosting {
    weak var processDelegate: LocalProcessTerminalViewDelegate?
    let processID: pid_t
    private(set) var startCount = 0

    init(processID: pid_t) {
        self.processID = processID
    }

    func startPickyProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    ) {
        startCount += 1
    }
}

private final class RecordToken {}

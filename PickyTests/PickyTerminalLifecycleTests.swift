//
//  PickyTerminalLifecycleTests.swift
//  PickyTests
//

import CoreGraphics
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import Picky

@MainActor
struct PickyTerminalLifecycleTests {
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

    @Test func shellSessionStartsTheSameProcessHostOnlyOnceAcrossRemounts() {
        let host = TerminalProcessHostStub(processID: 42)
        let session = PickyShellTerminalSession(
            sessionID: "shell-1",
            title: "Shell",
            cwd: "/tmp",
            fontScalePersister: PickyTerminalFontScalePersister(load: { 1 }, save: { _ in }),
            processHost: host
        )

        session.attach()
        session.attach()

        #expect(host.startCount == 1)
        #expect(host.processDelegate != nil)
    }

    @Test func closedShellDoesNotStartOrRetainADelayedProcessHostDelegate() {
        let model = PickyShellTerminalModel(title: "Shell", cwd: "/tmp")
        let host = TerminalProcessHostStub(processID: 42)

        model.close()
        model.attachProcessHost(host)

        #expect(host.startCount == 0)
        #expect(host.processDelegate == nil)
    }

    @Test func closingStartedShellTerminatesItsProcessHostExactlyOnce() {
        let model = PickyShellTerminalModel(title: "Shell", cwd: "/tmp")
        let host = TerminalProcessHostStub(processID: 42)
        model.attachProcessHost(host)

        model.close()
        model.close()

        #expect(host.startCount == 1)
        #expect(host.terminateCount == 1)
        #expect(host.processDelegate == nil)
    }

    @Test func swiftTermExplicitAndTerminalProtocolResponsesShareTheSameFinalSendPath() {
        let terminalView = SendCapturingLocalProcessTerminalView(frame: .zero)

        terminalView.send(txt: "explicit")
        terminalView.terminal.sendResponse(text: "terminal-protocol")

        // SwiftTerm invokes the same LocalProcessTerminalView override with the
        // same source object for both paths; it supplies no input-origin metadata.
        #expect(terminalView.sentPayloads == ["explicit", "terminal-protocol"])
        #expect(terminalView.sentSources.allSatisfy { $0 === terminalView })
    }

}

@MainActor
private final class TerminalProcessHostStub: PickyTerminalProcessHosting {
    weak var processDelegate: LocalProcessTerminalViewDelegate?
    let processID: pid_t
    private(set) var startCount = 0
    private(set) var terminateCount = 0

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

    func terminatePickyProcess() {
        terminateCount += 1
    }
}

private final class SendCapturingLocalProcessTerminalView: LocalProcessTerminalView {
    private(set) var sentPayloads: [String] = []
    private(set) var sentSources: [TerminalView] = []

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sentPayloads.append(String(decoding: data, as: UTF8.self))
        sentSources.append(source)
    }
}

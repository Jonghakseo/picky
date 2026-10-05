//
//  PickyRemoteHubTests.swift
//  PickyTests
//
//  The app side of remote access: which app action each phone request runs,
//  what the Mac must not do while it runs, and what the hub tells the gateway.
//

import Combine
import Foundation
import Testing
@testable import Picky

// MARK: - Fakes

@MainActor
private final class FakeRemoteSessions: PickyRemoteSessionActions {
    var createdCwds: [String] = []
    var readSessionIDs: [String] = []
    var archiveCalls: [(String, Bool)] = []
    var createError: Error?

    func createRemotePickle(cwd: String) async throws -> String {
        if let createError { throw createError }
        createdCwds.append(cwd)
        return "pickle-\(createdCwds.count)"
    }

    func markRemoteSessionRead(sessionID: String) {
        readSessionIDs.append(sessionID)
    }

    func setRemoteSessionArchived(sessionID: String, archived: Bool) async throws {
        archiveCalls.append((sessionID, archived))
    }
}

@MainActor
private final class FakeRemoteMainAgent: PickyRemoteMainAgentActions {
    var sentText: [String] = []
    var abortCount = 0
    var answers: [(String, JSONValue)] = []

    func submitMainFromRemote(text: String) async throws { sentText.append(text) }
    func abortMainFromRemote() async throws { abortCount += 1 }
    func answerMainQuestionFromRemote(requestID: String, value: JSONValue) async throws {
        answers.append((requestID, value))
    }
}

@MainActor
private final class FakeRemoteDictation: PickyRemoteDictationTranscribing {
    var result: Result<String, Error> = .success("hello from the phone")
    var requestedPaths: [String] = []

    func transcribe(filePath: String, mime: String) async throws -> String {
        requestedPaths.append(filePath)
        return try result.get()
    }
}

@MainActor
private final class FakeHubTransport: PickyRemoteHubTransport {
    var onMessage: ((PickyGatewayToHubMessage) -> Void)?
    var onConnectedChange: ((Bool) -> Void)?
    private(set) var sent: [PickyHubToGatewayMessage] = []
    private(set) var connectedURLs: [URL] = []
    private(set) var disconnectCount = 0

    func connect(url: URL, token: String) {
        connectedURLs.append(url)
    }

    func disconnect() {
        disconnectCount += 1
        onConnectedChange?(false)
    }

    func send(_ message: PickyHubToGatewayMessage) {
        sent.append(message)
    }

    func simulateConnected() {
        onConnectedChange?(true)
    }

    var sentTypes: [String] { sent.map(\.type) }

    func lastConfig() -> (publicUrl: String?, dictation: PickyRemoteDictationAvailability)? {
        for message in sent.reversed() {
            if case .config(let publicUrl, let dictation) = message { return (publicUrl, dictation) }
        }
        return nil
    }
}

@MainActor
private final class FakeGateway: PickyRemoteGatewayControlling {
    private(set) var state: PickyRemoteGatewayState = .stopped
    var onStateChange: ((PickyRemoteGatewayState) -> Void)?
    private(set) var startCalls: [(port: Int, token: String)] = []
    private(set) var stopCount = 0

    func start(port: Int, hubToken: String, appSupportRoot: URL) {
        startCalls.append((port, hubToken))
        transition(to: .starting)
    }

    func stop() {
        stopCount += 1
        transition(to: .stopped)
    }

    func stopAndWaitForExit() { stop() }

    func transition(to next: PickyRemoteGatewayState) {
        state = next
        onStateChange?(next)
    }
}

@MainActor
private final class FakeOverlaySource: PickyRemoteOverlaySource {
    var snapshot = PickyRemoteOverlaySnapshot.empty
    let subject = PassthroughSubject<PickyRemoteOverlaySnapshot, Never>()

    func currentRemoteOverlay() -> PickyRemoteOverlaySnapshot { snapshot }
    var remoteOverlayPublisher: AnyPublisher<PickyRemoteOverlaySnapshot, Never> { subject.eraseToAnyPublisher() }
}

@MainActor
private final class FakeTopologySource: PickyRemoteDaemonTopologySource {
    var topology = PickyRemoteDaemonTopology(token: "tok", primaryURL: "ws://127.0.0.1:17631", children: [])
    let subject = PassthroughSubject<PickyRemoteDaemonTopology, Never>()

    func currentRemoteDaemonTopology() -> PickyRemoteDaemonTopology { topology }
    var remoteDaemonTopologyPublisher: AnyPublisher<PickyRemoteDaemonTopology, Never> { subject.eraseToAnyPublisher() }
}

// MARK: - Request handler

@MainActor
struct PickyRemoteHubRequestHandlerTests {
    private func make() -> (PickyRemoteHubRequestHandler, FakeRemoteSessions, FakeRemoteMainAgent, FakeRemoteDictation) {
        let sessions = FakeRemoteSessions()
        let mainAgent = FakeRemoteMainAgent()
        let dictation = FakeRemoteDictation()
        return (
            PickyRemoteHubRequestHandler(sessions: sessions, mainAgent: mainAgent, dictation: dictation),
            sessions,
            mainAgent,
            dictation
        )
    }

    @Test func everyRequestReachesTheAppActionThatOwnsIt() async throws {
        let (handler, sessions, mainAgent, dictation) = make()

        let created = await handler.handle(requestId: "r1", request: .pickleCreate(cwd: "/tmp/work"))
        #expect(created == .ok(requestId: "r1", data: .object(["sessionId": .string("pickle-1")])))
        #expect(sessions.createdCwds == ["/tmp/work"])

        _ = await handler.handle(requestId: "r2", request: .mainSend(text: "hello"))
        _ = await handler.handle(requestId: "r3", request: .mainAbort)
        _ = await handler.handle(requestId: "r4", request: .mainAnswer(requestId: "q1", value: .string("yes")))
        #expect(mainAgent.sentText == ["hello"])
        #expect(mainAgent.abortCount == 1)
        #expect(mainAgent.answers.map(\.0) == ["q1"])

        _ = await handler.handle(requestId: "r5", request: .sessionMarkRead(sessionId: "s1"))
        _ = await handler.handle(requestId: "r6", request: .sessionArchive(sessionId: "s1", archived: true))
        #expect(sessions.readSessionIDs == ["s1"])
        #expect(sessions.archiveCalls.first?.0 == "s1")
        #expect(sessions.archiveCalls.first?.1 == true)

        let transcribed = await handler.handle(
            requestId: "r7",
            request: .dictationTranscribe(filePath: "/tmp/clip.m4a", mime: "audio/mp4")
        )
        #expect(transcribed == .ok(requestId: "r7", data: .object(["text": .string("hello from the phone")])))
        #expect(dictation.requestedPaths == ["/tmp/clip.m4a"])
    }

    /// The phone turns these codes into copy, so a dictation failure must not
    /// arrive as a generic error.
    @Test func failuresKeepTheirWireCode() async throws {
        let (handler, sessions, _, dictation) = make()
        dictation.result = .failure(PickyRemoteHubError(code: PickyRemoteHubErrorCode.macPermission, message: "needs permission"))
        let denied = await handler.handle(requestId: "r1", request: .dictationTranscribe(filePath: "/tmp/a.m4a", mime: "audio/mp4"))
        #expect(denied == .failure(requestId: "r1", code: PickyRemoteHubErrorCode.macPermission, message: "needs permission"))

        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        sessions.createError = Boom()
        let failed = await handler.handle(requestId: "r2", request: .pickleCreate(cwd: "/tmp"))
        #expect(failed == .failure(requestId: "r2", code: PickyRemoteHubErrorCode.failed, message: "boom"))
    }

    @Test func requestsAreRefusedWhenTheAppSideIsGone() async throws {
        let handler = PickyRemoteHubRequestHandler(sessions: nil, mainAgent: nil, dictation: nil)
        let response = await handler.handle(requestId: "r1", request: .mainSend(text: "hi"))
        guard case .failure(_, let code, _) = response else {
            Issue.record("Expected a failure, got \(response)")
            return
        }
        #expect(code == PickyRemoteHubErrorCode.macUnavailable)
    }
}

// MARK: - Main-agent adapter

@MainActor
struct PickyRemoteMainAgentAdapterTests {
    private final class Recorder {
        var steps: [String] = []
        var submissions: [PickyAgentSubmission] = []
        var notedContexts: [PickyContextPacket] = []
        var cancelSources: [PickyMainTurnCancellationSource] = []
        var cancelResult = true
        var answerError: Error?
    }

    private func make(_ recorder: Recorder) -> PickyRemoteMainAgentAdapter {
        PickyRemoteMainAgentAdapter(host: {
            PickyRemoteMainAgentAdapter.Host(
                noteSubmission: { context in
                    recorder.steps.append("note")
                    recorder.notedContexts.append(context)
                },
                submit: { submission in
                    recorder.steps.append("submit")
                    recorder.submissions.append(submission)
                },
                cancelMainTurn: { source in
                    recorder.cancelSources.append(source)
                    return recorder.cancelResult
                },
                answerQuestion: { _, _ in recorder.answerError }
            )
        })
    }

    /// Registration has to happen before the submission leaves: once the
    /// daemon replies for an unregistered context the Mac has already decided
    /// to show it.
    @Test func submissionRegistersTheRemoteOwnerBeforeItSends() async throws {
        let recorder = Recorder()
        try await make(recorder).submitMainFromRemote(text: "  ship it  ")

        #expect(recorder.steps == ["note", "submit"])
        let submission = try #require(recorder.submissions.first)
        #expect(submission.transcript == "ship it")
        #expect(submission.context.id == recorder.notedContexts.first?.id)
        // Nothing about this Mac's screen belongs in a phone turn.
        #expect(submission.context.screenshots.isEmpty)
        #expect(submission.context.activeApp == nil)
        #expect(submission.context.selectedText == nil)
        #expect(submission.context.warnings.contains("remote=true"))
    }

    @Test func emptyMessagesAreRejectedWithoutTouchingTheAgent() async {
        let recorder = Recorder()
        await #expect(throws: PickyRemoteHubError.self) {
            try await make(recorder).submitMainFromRemote(text: "   ")
        }
        #expect(recorder.steps.isEmpty)
    }

    @Test func stopFromThePhoneUsesTheMainCancelPathAndReportsRefusal() async throws {
        let recorder = Recorder()
        try await make(recorder).abortMainFromRemote()
        #expect(recorder.cancelSources == [.remote])

        recorder.cancelResult = false
        await #expect(throws: PickyRemoteHubError.self) {
            try await make(recorder).abortMainFromRemote()
        }
    }

    @Test func answerFailuresReachThePhone() async throws {
        let recorder = Recorder()
        try await make(recorder).answerMainQuestionFromRemote(requestID: "q1", value: .string("yes"))

        struct Boom: Error, LocalizedError { var errorDescription: String? { "no route" } }
        recorder.answerError = Boom()
        await #expect(throws: PickyRemoteHubError.self) {
            try await make(recorder).answerMainQuestionFromRemote(requestID: "q1", value: .string("yes"))
        }
    }

    @Test func actionsFailCleanlyWhenTheCompanionIsGone() async {
        let adapter = PickyRemoteMainAgentAdapter(host: { nil })
        await #expect(throws: PickyRemoteHubError.self) { try await adapter.submitMainFromRemote(text: "hi") }
        await #expect(throws: PickyRemoteHubError.self) { try await adapter.abortMainFromRemote() }
    }
}

// MARK: - Controller

@MainActor
struct PickyRemoteAccessControllerTests {
    @MainActor
    private final class Harness {
        let gateway = FakeGateway()
        let transport = FakeHubTransport()
        let overlay = FakeOverlaySource()
        let topology = FakeTopologySource()
        let sessions = FakeRemoteSessions()
        let mainAgent = FakeRemoteMainAgent()
        var readiness: PickyRemoteDictationReadiness = .ready
    }

    private func make(
        _ harness: Harness,
        settings: PickyRemoteAccessSettings = PickyRemoteAccessSettings(enabled: true, entrance: .cloudflare, cloudflareURL: "https://picky.example.com")
    ) -> PickyRemoteAccessController {
        PickyRemoteAccessController(
            settings: settings,
            gateway: harness.gateway,
            transport: harness.transport,
            overlaySource: harness.overlay,
            topologySource: harness.topology,
            requestHandler: PickyRemoteHubRequestHandler(
                sessions: harness.sessions,
                mainAgent: harness.mainAgent,
                dictation: nil
            ),
            dictationReadiness: { harness.readiness },
            tailscale: PickyTailscaleService(executableURL: nil),
            appSupportRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            appVersion: "1.2.3",
            macName: "Test Mac",
            tokenFactory: { "test-token" }
        )
    }

    @Test func enabledSettingsStartTheGatewayAndTheSocketFollowsItsReadyLine() {
        let harness = Harness()
        let controller = make(harness)

        #expect(harness.gateway.startCalls.map(\.port) == [17640])
        #expect(harness.transport.connectedURLs.isEmpty)

        harness.gateway.transition(to: .running(port: 17640))
        #expect(harness.transport.connectedURLs.map(\.absoluteString) == ["ws://127.0.0.1:17640/hub"])
        #expect(controller.isRunning)
    }

    @Test func remoteAccessStaysOffUntilTheUserTurnsItOn() {
        let harness = Harness()
        let controller = make(harness, settings: .defaults)
        #expect(harness.gateway.startCalls.isEmpty)

        controller.apply(settings: PickyRemoteAccessSettings(enabled: true))
        #expect(harness.gateway.startCalls.count == 1)

        controller.apply(settings: PickyRemoteAccessSettings(enabled: false))
        #expect(harness.gateway.stopCount == 1)
        #expect(harness.transport.disconnectCount == 1)
    }

    @Test func theHandshakeTellsTheGatewayEverythingItNeedsToServeAPhone() throws {
        let harness = Harness()
        harness.overlay.snapshot = PickyRemoteOverlaySnapshot(
            activeSessionIds: ["s1"],
            archivedSessionIds: [],
            unreadSessionIds: ["s1"],
            groups: [],
            folders: .empty
        )
        let controller = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        #expect(harness.transport.sentTypes == ["hub.hello", "hub.daemons", "hub.overlay", "hub.config"])
        let config = try #require(harness.transport.lastConfig())
        #expect(config.publicUrl == "https://picky.example.com")
        #expect(config.dictation == .availableNow)
        #expect(controller.isHubConnected)
    }

    /// The phone hides its mic button from this flag, so a permission granted
    /// (or a service switched) on the Mac has to be pushed, not polled.
    @Test func dictationChangesAreResentAsConfig() throws {
        let harness = Harness()
        let controller = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()
        let baseline = harness.transport.sent.count

        harness.readiness = .needsPermission
        controller.refreshDictation()
        #expect(harness.transport.sentTypes.count == baseline + 1)
        #expect(harness.transport.lastConfig()?.dictation == .unavailable(.macPermission))

        // Same readiness twice is not news.
        controller.refreshDictation()
        #expect(harness.transport.sentTypes.count == baseline + 1)
    }

    @Test func gatewayRequestsAreAnsweredOnTheSameSocket() async throws {
        let harness = Harness()
        let controller = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        harness.transport.onMessage?(.request(
            requestId: "req-1",
            deviceId: "dev-1",
            request: .sessionMarkRead(sessionId: "s1")
        ))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(harness.sessions.readSessionIDs == ["s1"])
        #expect(harness.transport.sent.last == .response(.ok(requestId: "req-1", data: nil)))
        #expect(controller.isHubConnected)
    }

    @Test func pairingAndDeviceUpdatesDriveWhatTheSettingsPageShows() throws {
        let harness = Harness()
        let controller = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        controller.startPairing()
        #expect(harness.transport.sentTypes.last == "hub.pairing.start")

        let expires = Date(timeIntervalSince1970: 2_000_000_000)
        harness.transport.onMessage?(.pairing(code: "K7QM-4XTR", expiresAt: expires, url: "https://picky.example.com/#pair=K7QM4XTR"))
        #expect(controller.pairing == .waiting(PickyRemotePairingSession(
            code: "K7QM-4XTR",
            expiresAt: expires,
            url: "https://picky.example.com/#pair=K7QM4XTR"
        )))

        harness.transport.onMessage?(.pairingEnded(reason: .paired, deviceName: "iPhone"))
        #expect(controller.pairing == .ended(reason: .paired, deviceName: "iPhone"))
        controller.dismissPairingResult()
        #expect(controller.pairing == .idle)

        harness.transport.onMessage?(.devices([
            PickyRemoteDevice(id: "d1", name: "iPhone", createdAt: expires, lastSeenAt: expires, online: true, pushEnabled: true),
            PickyRemoteDevice(id: "d2", name: "iPad", createdAt: expires, lastSeenAt: nil, online: false, pushEnabled: false)
        ]))
        #expect(controller.devices.count == 2)
        #expect(controller.onlineDeviceCount == 1)

        controller.revokeDevice(id: "d1")
        #expect(harness.transport.sent.last == .devicesRevoke(deviceId: "d1"))
        controller.renameDevice(id: "d2", name: "  ")
        #expect(harness.transport.sent.last == .devicesRevoke(deviceId: "d1"))
    }

    @Test func aMismatchedGatewayVersionIsReportedInsteadOfFailingRequestLater() {
        let harness = Harness()
        let controller = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        harness.transport.onMessage?(.hello(protocolVersion: PickyRemoteHubProtocol.version + 1, version: "9.9.9", port: 17640))
        guard case .failed = controller.gatewayState else {
            Issue.record("Expected a failed state, got \(controller.gatewayState)")
            return
        }
    }

    @Test func theLocalOnlyEntranceHasNoPublicURLButStillHasAnAddressToOpen() {
        let harness = Harness()
        let controller = make(harness, settings: PickyRemoteAccessSettings(enabled: false, entrance: .localOnly, port: 17641))
        #expect(controller.publicURL == nil)
        #expect(controller.entranceURL == "http://127.0.0.1:17641")
    }
}

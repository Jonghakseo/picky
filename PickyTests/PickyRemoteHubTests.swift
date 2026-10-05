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

    func simulateDisconnected() {
        onConnectedChange?(false)
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
private final class FakeQuickTunnel: PickyQuickTunnelControlling {
    private(set) var state: PickyQuickTunnelState = .stopped
    var onStateChange: ((PickyQuickTunnelState) -> Void)?
    private(set) var startPorts: [Int] = []
    private(set) var stopCount = 0
    private(set) var waitedStopCount = 0

    func start(port: Int) {
        startPorts.append(port)
        if state == .stopped { transition(to: .starting) }
    }

    func stop() {
        stopCount += 1
        transition(to: .stopped)
    }

    func stopAndWaitForExit() {
        waitedStopCount += 1
        transition(to: .stopped)
    }

    func transition(to next: PickyQuickTunnelState) {
        state = next
        onStateChange?(next)
    }
}

/// One websocket the hub can be driven over, with the frames the gateway would
/// have sent enqueued by the test.
private final class FakeHubSocket: PickyWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.Continuation
    private var iterator: AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.Iterator
    private var _sent: [String] = []
    private var _didCancel = false

    var sentTexts: [String] { lock.withLock { _sent } }
    var didCancel: Bool { lock.withLock { _didCancel } }

    init() {
        var continuation: AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.Continuation!
        let stream = AsyncStream<Result<URLSessionWebSocketTask.Message, Error>> { continuation = $0 }
        self.continuation = continuation
        self.iterator = stream.makeAsyncIterator()
    }

    struct Dropped: Error {}

    func deliverGatewayHello() {
        continuation.yield(.success(.string(
            "{\"type\":\"gateway.hello\",\"protocolVersion\":\(PickyRemoteHubProtocol.version),\"version\":\"1\",\"port\":17640}"
        )))
    }

    func drop() { continuation.yield(.failure(Dropped())) }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        lock.withLock { _sent.append(text) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let result = await iterator.next() else { throw CancellationError() }
        return try result.get()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { _didCancel = true }
        continuation.finish()
    }
}

private final class FakeHubSocketFactory: PickyWebSocketTaskMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeHubSocket] = []

    var sockets: [FakeHubSocket] { lock.withLock { _sockets } }

    func makeWebSocketTask(url: URL, token: String) -> PickyWebSocketTask {
        let socket = FakeHubSocket()
        lock.withLock { _sockets.append(socket) }
        return socket
    }
}

@MainActor
private final class FakeChildDaemons: PickyRemoteChildDaemonSource {
    private let subject = CurrentValueSubject<Set<String>, Never>([])
    private var endpoints: [String: (host: String, port: Int)] = [:]

    var remoteChildSessionIDs: Set<String> { subject.value }

    func remoteChildEndpoint(for sessionID: String) -> (host: String, port: Int)? { endpoints[sessionID] }

    var remoteChildDaemonChanges: AnyPublisher<Set<String>, Never> { subject.eraseToAnyPublisher() }

    /// What the pool does at spawn start: the session is active, the port is
    /// not known yet.
    func announceSpawn(_ sessionID: String) {
        subject.send(subject.value.union([sessionID]))
    }

    /// What the pool does when the child prints its listening line.
    func resolveEndpoint(_ sessionID: String, port: Int) {
        endpoints[sessionID] = ("127.0.0.1", port)
        subject.send(subject.value)
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
        let quickTunnel = FakeQuickTunnel()
        var readiness: PickyRemoteDictationReadiness = .ready
        var rememberedQuickTunnelURL: String?
        var openedURLs: [URL] = []
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
            quickTunnel: harness.quickTunnel,
            quickTunnelAddressMemory: PickyQuickTunnelAddressMemory(
                load: { harness.rememberedQuickTunnelURL },
                save: { harness.rememberedQuickTunnelURL = $0 }
            ),
            appSupportRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            appVersion: "1.2.3",
            macName: "Test Mac",
            tokenFactory: { "test-token" },
            openURL: { harness.openedURLs.append($0) }
        )
    }

    /// "Open in browser" opens exactly the link the gateway issued for it, and
    /// nothing else: not a link nobody asked for, not a non-loopback address.
    @Test func openInBrowserOpensOnlyTheRequestedLoopbackLink() {
        let harness = Harness()
        let controller = make(harness)
        let link = "http://127.0.0.1:17640/api/local-open?token=abc"

        // Not running yet: there is no gateway to ask.
        controller.openInBrowser()
        #expect(!harness.transport.sentTypes.contains("hub.localOpen.start"))

        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        // A link the Mac did not ask for is ignored.
        harness.transport.onMessage?(.localOpen(url: link))
        #expect(harness.openedURLs.isEmpty)

        controller.openInBrowser()
        controller.openInBrowser()
        #expect(harness.transport.sentTypes.filter { $0 == "hub.localOpen.start" }.count == 1)
        #expect(controller.isOpeningBrowser)
        harness.transport.onMessage?(.localOpen(url: link))
        #expect(harness.openedURLs.map(\.absoluteString) == [link])
        #expect(!controller.isOpeningBrowser)

        controller.openInBrowser()
        harness.transport.onMessage?(.localOpen(url: "https://evil.example/api/local-open?token=abc"))
        #expect(harness.openedURLs.count == 1)
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

    private static let temporary = PickyRemoteAccessSettings(enabled: true, entrance: .cloudflare, cloudflareMode: .quick)

    @Test func theTemporaryAddressComesFromPickysTunnelAndReachesTheGateway() throws {
        let harness = Harness()
        let controller = make(harness, settings: Self.temporary)
        #expect(harness.quickTunnel.startPorts == [17640])

        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()
        // No address yet: pairing waits, and the status says so without
        // asking the user to set anything up.
        #expect(controller.publicURL == nil)
        #expect(controller.isEntranceAddressPending)
        #expect(PickyHubRemotePairingAvailability.resolve(
            isRunning: controller.isRunning,
            isHubConnected: controller.isHubConnected,
            entrance: controller.settings.entrance,
            publicURL: controller.publicURL
        ) == .needsEntrance)

        harness.quickTunnel.transition(to: .running(url: "https://argued-libraries.trycloudflare.com"))
        #expect(controller.publicURL == "https://argued-libraries.trycloudflare.com")
        #expect(controller.entranceURL == "https://argued-libraries.trycloudflare.com")
        #expect(!controller.isEntranceAddressPending)
        let config = try #require(harness.transport.lastConfig())
        #expect(config.publicUrl == "https://argued-libraries.trycloudflare.com")
    }

    @Test func theTunnelFollowsTheSettingsAndOutlivesAGatewayRestart() {
        let harness = Harness()
        let controller = make(harness, settings: Self.temporary)
        harness.quickTunnel.transition(to: .running(url: "https://a-b.trycloudflare.com"))

        // A gateway restart must not cost the phone its address.
        harness.gateway.transition(to: .failed("exited"))
        harness.gateway.transition(to: .running(port: 17640))
        controller.restartGateway()
        #expect(harness.quickTunnel.stopCount == 0)
        #expect(controller.publicURL == "https://a-b.trycloudflare.com")

        var mine = Self.temporary
        mine.cloudflareMode = .custom
        mine.cloudflareURL = "https://picky.example.com"
        controller.apply(settings: mine)
        #expect(harness.quickTunnel.stopCount == 1)
        #expect(controller.publicURL == "https://picky.example.com")

        controller.apply(settings: Self.temporary)
        #expect(harness.quickTunnel.state == .starting)

        var off = Self.temporary
        off.enabled = false
        controller.apply(settings: off)
        #expect(harness.quickTunnel.stopCount == 2)

        let custom = make(Harness(), settings: PickyRemoteAccessSettings(enabled: true, entrance: .cloudflare, cloudflareURL: "https://picky.example.com"))
        #expect(custom.quickTunnelState == .stopped)
    }

    @Test func quittingStopsTheTunnelAndWaitsForIt() {
        let harness = Harness()
        let controller = make(harness, settings: Self.temporary)
        controller.stopForAppTermination()
        #expect(harness.quickTunnel.waitedStopCount == 1)
    }

    @Test func aNewTemporaryAddressAsksPairedPhonesToPairAgain() {
        let harness = Harness()
        harness.rememberedQuickTunnelURL = "https://old-words.trycloudflare.com"
        let controller = make(harness, settings: Self.temporary)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        harness.quickTunnel.transition(to: .running(url: "https://new-words.trycloudflare.com"))
        #expect(harness.rememberedQuickTunnelURL == "https://new-words.trycloudflare.com")
        // No phone holds the old address yet, so there is nothing to say.
        #expect(!controller.showsQuickTunnelAddressChange)

        let seen = Date(timeIntervalSince1970: 2_000_000_000)
        harness.transport.onMessage?(.devices([
            PickyRemoteDevice(id: "d1", name: "Fold", createdAt: seen, lastSeenAt: seen, online: false, pushEnabled: false)
        ]))
        #expect(controller.showsQuickTunnelAddressChange)

        // Pairing through the new address is what resolves it.
        harness.transport.onMessage?(.pairingEnded(reason: .paired, deviceName: "Fold"))
        #expect(!controller.showsQuickTunnelAddressChange)

        // The same address coming back (a reconnect inside one run) is no change.
        harness.quickTunnel.transition(to: .starting)
        harness.quickTunnel.transition(to: .running(url: "https://new-words.trycloudflare.com"))
        #expect(!controller.showsQuickTunnelAddressChange)
    }

    @Test func theLocalOnlyEntranceHasNoPublicURLButStillHasAnAddressToOpen() {
        let harness = Harness()
        let controller = make(harness, settings: PickyRemoteAccessSettings(enabled: false, entrance: .localOnly, port: 17641))
        #expect(controller.publicURL == nil)
        #expect(controller.entranceURL == "http://127.0.0.1:17641")
    }

    /// A gateway restart drops the socket and the gateway forgets every daemon
    /// link and projection it had. If the second connection only repeated the
    /// hello, the phone would show an empty room list until the dock happened
    /// to change.
    @Test func aReconnectResendsTheWholeSnapshotEvenWhenNothingChanged() {
        let harness = Harness()
        _ = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()
        #expect(harness.transport.sentTypes == ["hub.hello", "hub.daemons", "hub.overlay", "hub.config"])

        harness.transport.simulateDisconnected()
        harness.transport.simulateConnected()
        #expect(harness.transport.sentTypes == [
            "hub.hello", "hub.daemons", "hub.overlay", "hub.config",
            "hub.hello", "hub.daemons", "hub.overlay", "hub.config"
        ])
    }

    /// Saving a new port replaces the gateway process. Leaving the socket
    /// attached to the old one meant the hub kept talking to a process that was
    /// on its way out.
    @Test func changingThePortDropsTheSocketBeforeTheNewGatewayStarts() {
        let harness = Harness()
        let controller = make(harness)
        harness.gateway.transition(to: .running(port: 17640))
        harness.transport.simulateConnected()

        controller.apply(settings: PickyRemoteAccessSettings(
            enabled: true,
            entrance: .cloudflare,
            cloudflareURL: "https://picky.example.com",
            port: 17650
        ))
        #expect(harness.transport.disconnectCount == 1)
        #expect(harness.gateway.stopCount == 1)
        #expect(harness.gateway.startCalls.map(\.port) == [17640, 17650])
    }
}

// MARK: - Hub socket

@MainActor
struct PickyRemoteHubClientTests {
    /// `resume()` returns long before the upgrade succeeds, and it returns just
    /// the same for a 401 or a dead port. Anything the controller sends in that
    /// window is silently thrown away.
    @Test func theSocketCountsAsConnectedOnlyAfterTheGatewayAnswers() async throws {
        let factory = FakeHubSocketFactory()
        let client = PickyRemoteHubClient(factory: factory)
        var changes: [Bool] = []
        client.onConnectedChange = { changes.append($0) }

        client.connect(url: URL(string: "ws://127.0.0.1:17640/hub")!, token: "t")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.isConnected == false)
        #expect(changes.isEmpty)

        client.send(.pairingStart)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(factory.sockets.first?.sentTexts.isEmpty == true)

        factory.sockets.first?.deliverGatewayHello()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.isConnected)
        #expect(changes == [true])
    }

    /// The launcher restarts the gateway while a reconnect from the drop is
    /// still pending. That reconnect used to open a second socket behind the
    /// fresh one; the gateway keeps only the newest hub socket, so the
    /// handshake sent on the one it replaced was lost.
    @Test func aPendingReconnectDoesNotOpenASocketBehindAFreshConnection() async throws {
        let factory = FakeHubSocketFactory()
        let client = PickyRemoteHubClient(factory: factory)
        var changes: [Bool] = []
        client.onConnectedChange = { changes.append($0) }
        let url = URL(string: "ws://127.0.0.1:17640/hub")!

        client.connect(url: url, token: "t")
        factory.sockets[0].deliverGatewayHello()
        try await Task.sleep(nanoseconds: 100_000_000)

        factory.sockets[0].drop()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.isConnected == false)

        // The gateway came back and the controller reconnects immediately.
        client.connect(url: url, token: "t")
        factory.sockets[1].deliverGatewayHello()
        // Past the first reconnect delay (0.5 s), so a surviving reconnect task
        // would have opened a third socket by now.
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(factory.sockets.count == 2)
        #expect(client.isConnected)
        // One connection, one handshake: the controller sends it on each rising edge.
        #expect(changes == [true, false, true])
    }
}

// MARK: - Daemon topology

@MainActor
struct PickyRemoteDaemonTopologyProviderTests {
    /// A child is in `activeChildSessionIds` from the moment it is spawned, but
    /// its port only exists once it prints its listening line. Without a second
    /// publish the gateway keeps routing that Pickle to the primary daemon, and
    /// a Pickle created from the phone times out.
    @Test func theTopologyIsPublishedAgainWhenAChildEndpointResolves() {
        let pool = FakeChildDaemons()
        let provider = PickyRemoteDaemonTopologyProvider(pool: pool, token: "tok", primaryPort: 17631)
        var published: [PickyRemoteDaemonTopology] = []
        let subscription = provider.remoteDaemonTopologyPublisher.sink { published.append($0) }
        defer { subscription.cancel() }

        pool.announceSpawn("s1")
        #expect(published.last?.children.isEmpty == true)

        pool.resolveEndpoint("s1", port: 51234)
        #expect(published.last?.children == [PickyRemoteDaemonChild(sessionId: "s1", url: "ws://127.0.0.1:51234")])
        #expect(provider.currentRemoteDaemonTopology().children.count == 1)
    }
}

// MARK: - Gateway process policy

@MainActor
struct PickyRemoteGatewayLauncherPolicyTests {
    @Test func aBusyPortIsRecognizedFromTheGatewaysOwnLine() {
        #expect(PickyRemoteGatewayLauncher.portInUse(from: "PICKY_GATEWAY_PORT_IN_USE:17640") == 17640)
        #expect(PickyRemoteGatewayLauncher.portInUse(from: "  PICKY_GATEWAY_PORT_IN_USE:17640  ") == 17640)
        #expect(PickyRemoteGatewayLauncher.portInUse(from: "gateway: something else") == nil)
    }

    /// Retrying into an occupied port repeats the same failure every 30 seconds
    /// and never tells the user what to do, so a port conflict ends the restart
    /// loop until the settings change.
    @Test func aPortConflictStopsTheRestartLoopAndOtherExitsDoNot() {
        #expect(
            PickyRemoteGatewayExitDecision.resolve(status: 1, desiredPort: 17640, reportedPortConflict: 17640)
                == .portInUse(port: 17640)
        )
        // stderr can be lost; the exit code carries the same meaning.
        #expect(
            PickyRemoteGatewayExitDecision.resolve(status: 3, desiredPort: 17640, reportedPortConflict: nil)
                == .portInUse(port: 17640)
        )
        #expect(
            PickyRemoteGatewayExitDecision.resolve(status: 1, desiredPort: 17640, reportedPortConflict: nil)
                == .restart(status: 1)
        )
        #expect(
            PickyRemoteGatewayExitDecision.resolve(status: 0, desiredPort: nil, reportedPortConflict: nil)
                == .stopped
        )
    }

    /// App termination waits for the gateway. A gateway stuck in its SIGTERM
    /// handler would otherwise hold the main thread forever, so the wait has a
    /// deadline and SIGKILL after it.
    @Test func aGatewayThatIgnoresSIGTERMIsKilledAfterTheGracePeriod() {
        var clock = Date(timeIntervalSince1970: 0)
        var sleeps: [TimeInterval] = []
        let needsKill = PickyRemoteGatewayTermination.needsKillAfterGracePeriod(
            isRunning: { true },
            now: { clock },
            sleep: { interval in
                clock = clock.addingTimeInterval(interval)
                sleeps.append(interval)
            }
        )
        #expect(needsKill)
        #expect(sleeps.isEmpty == false)
        #expect(sleeps.reduce(0, +) >= PickyRemoteGatewayTermination.gracePeriod)
    }

    @Test func aGatewayThatExitsOnItsOwnIsNotKilled() {
        var polls = 0
        var clock = Date(timeIntervalSince1970: 0)
        let needsKill = PickyRemoteGatewayTermination.needsKillAfterGracePeriod(
            isRunning: {
                polls += 1
                return polls <= 3
            },
            now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) }
        )
        #expect(needsKill == false)
        #expect(clock.timeIntervalSince1970 < PickyRemoteGatewayTermination.gracePeriod)
    }
}

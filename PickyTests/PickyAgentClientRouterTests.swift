//
//  PickyAgentClientRouterTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
private final class StubAgentClient: PickyAgentClient {
    let id: String
    let events: AsyncStream<PickyClientEvent>
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var sentCommands: [PickyCommandEnvelope] = []
    /// Optional hook fired while `send` is in flight. Tests use it to emit a
    /// daemon `type="error"` event for the in-flight command before `send`
    /// returns — mirroring agentd's behavior of unicasting rejections on the
    /// same socket in the same turn. After the hook runs, `Task.yield()` is
    /// called so the router's event forwarder gets a chance to observe the
    /// emitted error before the caller proceeds to await its rejection.
    var onSendInject: ((PickyCommandEnvelope) -> Void)?
    /// Optional asynchronous hook for tests that must keep a send suspended
    /// until another lifecycle action has completed.
    var onSendSuspend: ((PickyCommandEnvelope) async -> Void)?
    /// Optional error the stub throws from `send`. Lets tests simulate
    /// transport failure (websocket disconnected, encoding error, etc.) so we
    /// can verify that `sendAwaitingError` propagates the throw to its caller
    /// instead of swallowing it as silent success.
    var sendShouldThrow: Error?
    /// Error thrown after `onSendSuspend` returns. Kept separate from
    /// `sendShouldThrow` so tests can model a transport that dies while a
    /// send is suspended without changing the pre-send failure behavior.
    var sendShouldThrowAfterSuspend: Error?

    init(id: String) {
        self.id = id
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { connectCalls += 1; continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "\(id)-receipt", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        if let sendShouldThrow { throw sendShouldThrow }
        sentCommands.append(command)
        if let onSendInject {
            onSendInject(command)
            // Only yield when the test asked for an in-flight injection:
            // a forced actor turn lets the router's event forwarder pick
            // up the freshly emitted event before the caller proceeds.
            // Yielding unconditionally would change scheduling for the
            // many existing tests that rely on `send` being effectively
            // synchronous.
            await Task.yield()
        }
        if let onSendSuspend {
            await onSendSuspend(command)
        }
        if let sendShouldThrowAfterSuspend { throw sendShouldThrowAfterSuspend }
    }
    func disconnect() { disconnectCalls += 1; continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

@MainActor
private final class RouterErrorRecorder {
    private(set) var errorsByCommandId: [String: PickyErrorEvent] = [:]

    func record(_ event: PickyClientEvent) {
        guard case .protocolEvent(let envelope) = event,
              case .error(let error) = envelope.event,
              let commandId = error.commandId else { return }
        errorsByCommandId[commandId] = error
    }

    func error(for commandId: String) -> PickyErrorEvent? {
        errorsByCommandId[commandId]
    }
}

@MainActor
private final class StubClientFactory: PickyAgentClientFactoryProtocol {
    private(set) var madeClients: [(endpoint: URL, token: String, client: StubAgentClient)] = []

    func makeClient(endpoint: URL, token: String) -> PickyAgentClient {
        let client = StubAgentClient(id: "child-\(endpoint.absoluteString)")
        madeClients.append((endpoint, token, client))
        return client
    }
}

@MainActor
private final class StubLauncherFactoryForRouter: PickyAgentDaemonLauncherMaking {
    let agentdRoot: URL
    private(set) var runners: [String: RouterPoolStubRunner] = [:]

    init(agentdRoot: URL) { self.agentdRoot = agentdRoot }

    func makeLauncher(
        configuration: PickyAgentDaemonConfiguration,
        stdoutLineObserver: @escaping (String) -> Void
    ) -> PickyAgentDaemonLauncher {
        var rerouted = configuration
        rerouted.workingDirectory = agentdRoot
        let runner = RouterPoolStubRunner()
        let launcher = PickyAgentDaemonLauncher(
            configuration: rerouted,
            runner: runner,
            executableChecker: RouterAlwaysExists(),
            stdoutLineObserver: stdoutLineObserver
        )
        let sessionId: String
        if case .child(let id, _, _) = configuration.role { sessionId = id } else { sessionId = "primary" }
        runners[sessionId] = runner
        return launcher
    }

    func emitReady(for sessionId: String) {
        guard let runner = runners[sessionId] else { return }
        runner.emitReady(port: 49000 + runner.id)
    }

    func waitForRunner(sessionId: String, timeoutMs: Int = 2_000) async throws -> RouterPoolStubRunner {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let runner = runners[sessionId], runner.launchCount > 0 { return runner }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw RouterRunnerWaitTimeout(sessionId: sessionId)
    }
}

private struct RouterRunnerWaitTimeout: Error { let sessionId: String }

final class RouterPoolStubRunner: PickyProcessRunning {
    private static var nextId = 0
    let id: Int
    var terminationHandler: ((Int32) -> Void)?
    private var stdout: ((Data) -> Void)?
    private(set) var launchCount = 0
    init() {
        Self.nextId += 1
        id = Self.nextId
    }
    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws {
        self.stdout = stdout
        launchCount += 1
    }
    func terminate() {}
    func emitReady(port: Int) { stdout?(Data("picky-agentd listening on 127.0.0.1:\(port)\n".utf8)) }
    func emitTermination(exitCode: Int32) { terminationHandler?(exitCode) }
}

private struct RouterAlwaysExists: PickyExecutableChecking {
    func executableExists(named name: String, environment: [String: String]) -> Bool { true }
    func executableVersion(named name: String, environment: [String: String], workingDirectory: URL) -> String? {
        name == "node" ? "v22.19.0" : nil
    }
}

private func makeStubAgentdPackage(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "{}".write(to: url.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let dist = url.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "console.log('stub');\n".write(to: dist.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
}

private func makeSessionUpdatedEvent(id: String, title: String = "Pickle", status: PickySessionStatus = .running, finalAnswer: String? = nil) -> PickyEventEnvelope {
    PickyEventEnvelope(
        id: "event-session-\(id)",
        protocolVersion: pickyAgentProtocolVersion,
        timestamp: Date(),
        event: .sessionUpdated(PickyAgentSession(
            id: id,
            title: title,
            status: status,
            cwd: "/tmp/ws",
            createdAt: Date(),
            updatedAt: Date(),
            finalAnswer: finalAnswer,
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        ))
    )
}

private func makeSessionSnapshotEvent(id: String, title: String = "Pickle", status: PickySessionStatus = .completed) -> PickyEventEnvelope {
    PickyEventEnvelope(
        id: "event-snapshot-\(id)",
        protocolVersion: pickyAgentProtocolVersion,
        timestamp: Date(),
        event: .sessionSnapshot([
            PickyAgentSession(
                id: id,
                title: title,
                status: status,
                cwd: "/tmp/ws",
                createdAt: Date(),
                updatedAt: Date(),
                logs: [],
                tools: [],
                artifacts: [],
                changedFiles: []
            )
        ])
    )
}

private func makeEmptySessionSnapshotEvent() -> PickyEventEnvelope {
    PickyEventEnvelope(
        id: "event-snapshot-empty",
        protocolVersion: pickyAgentProtocolVersion,
        timestamp: Date(),
        event: .sessionSnapshot([])
    )
}

private func makePickleBridgeRequestEvent(operation: String, sessionId: String? = nil, text: String? = nil, prompt: String? = nil, cwd: String? = nil) throws -> PickyEventEnvelope {
    var fields = "\"operation\": \"\(operation)\""
    if let sessionId { fields += ", \"sessionId\": \"\(sessionId)\"" }
    if let text { fields += ", \"text\": \"\(text)\"" }
    if let prompt { fields += ", \"prompt\": \"\(prompt)\"" }
    if let cwd { fields += ", \"cwd\": \"\(cwd)\"" }
    let json = """
    {
      "id": "event-bridge",
      "protocolVersion": "2026-05-09",
      "timestamp": "2026-05-01T00:00:00.000Z",
      "type": "pickleBridgeRequested",
      "requestId": "bridge-request-1",
      \(fields)
    }
    """
    return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(json.utf8))
}

private func makeExternalEntryRequestEvent(
    requestId: String = "external-entry-1",
    kind: String = "submitMain",
    text: String? = "hello from cli",
    title: String? = nil,
    instructions: String? = nil,
    cwd: String? = nil
) throws -> PickyEventEnvelope {
    let payload: [String: Any] = [
        "id": "event-external-entry",
        "protocolVersion": "2026-05-09",
        "timestamp": "2026-05-01T00:00:00.000Z",
        "type": "externalEntryRequested",
        "requestId": requestId,
        "kind": kind,
    ].merging([
        "text": text as Any,
        "title": title as Any,
        "instructions": instructions as Any,
        "cwd": cwd as Any,
    ].filter { ($0.value as? String) != nil }, uniquingKeysWith: { _, new in new })
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: data)
}

private func makePushToTalkControlRequestEvent(
    requestId: String = "ptt-control-1",
    action: String = "press"
) throws -> PickyEventEnvelope {
    let payload: [String: Any] = [
        "id": "event-ptt-control",
        "protocolVersion": "2026-05-09",
        "timestamp": "2026-05-01T00:00:00.000Z",
        "type": "pushToTalkControlRequested",
        "requestId": requestId,
        "action": action,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: data)
}

private func makePickleHandoffRequestEvent() throws -> PickyEventEnvelope {
    let json = """
    {
      "id": "event-handoff",
      "protocolVersion": "2026-05-09",
      "timestamp": "2026-05-01T00:00:00.000Z",
      "type": "pickleHandoffRequested",
      "requestId": "handoff-request-1",
      "context": {
        "id": "context-handoff",
        "source": "text",
        "capturedAt": "2026-05-01T00:00:00.000Z",
        "transcript": "Sentry 봐줘",
        "cwd": "/tmp/product/backend",
        "screenshots": [],
        "inkMarks": [],
        "warnings": []
      },
      "title": "조사 피클",
      "instructions": "Sentry 확인",
      "cwd": "/tmp/product/backend"
    }
    """
    return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(json.utf8))
}

@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

@MainActor
struct PickyAgentClientRouterTests {
    @Test func returnsPrimaryClientForNilSessionId() {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        let client = router.client(for: nil)
        #expect((client as? StubAgentClient)?.id == "primary")
    }

    @Test func returnsPrimaryClientWhenNoChildForSessionId() {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        let client = router.client(for: "unknown-session")
        #expect((client as? StubAgentClient)?.id == "primary")
    }

    @Test func connectIsIdempotentForSharedHUDAndCompanionOwners() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())

        await router.connect()
        await router.connect()

        #expect(primary.connectCalls == 1)
    }

    @Test func reRegistersAppCapabilitiesWhenPrimaryReconnects() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())

        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }
        let registrationsBeforeReconnect = primary.sentCommands.filter { $0.type == .registerAppCapabilities }.count

        primary.emit(.connected)
        try await waitUntil { primary.sentCommands.filter { $0.type == .registerAppCapabilities }.count > registrationsBeforeReconnect }

        let registrations = primary.sentCommands.filter { $0.type == .registerAppCapabilities }
        #expect(registrations.count == registrationsBeforeReconnect + 1)
        #expect(registrations.last?.capabilities == ["pickleHandoff", "pickleBridge", "externalEntry", "pushToTalkControl"])
    }

    @Test func sendsCompleteExternalEntryWithCapturedContextWhenProviderResolves() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        router.externalEntryContextProvider = { request in
            #expect(request.text == "hello from cli")
            #expect(request.kind == .submitMain)
            return PickyContextPacket(
                id: "context-cli-stub",
                source: "cli",
                capturedAt: Date(timeIntervalSince1970: 0),
                transcript: request.text,
                selectedText: nil,
                cwd: "/tmp/cli-cwd",
                activeApp: nil,
                activeWindow: nil,
                browser: nil,
                screenshots: [],
                inkMarks: [],
                warnings: []
            )
        }

        await router.connect()
        primary.emit(.protocolEvent(try makeExternalEntryRequestEvent()))

        try await waitUntil { primary.sentCommands.contains { $0.type == .completeExternalEntryRequest } }
        let completion = try #require(primary.sentCommands.first { $0.type == .completeExternalEntryRequest })
        #expect(completion.requestId == "external-entry-1")
        #expect(completion.errorMessage == nil)
        #expect(completion.context?.id == "context-cli-stub")
        #expect(completion.context?.source == "cli")
    }

    @Test func sendsCompleteExternalEntryWithErrorMessageWhenProviderThrows() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        struct StubFailure: LocalizedError { var errorDescription: String? { "capture refused" } }
        router.externalEntryContextProvider = { _ in throw StubFailure() }

        await router.connect()
        primary.emit(.protocolEvent(try makeExternalEntryRequestEvent()))

        try await waitUntil { primary.sentCommands.contains { $0.type == .completeExternalEntryRequest } }
        let completion = try #require(primary.sentCommands.first { $0.type == .completeExternalEntryRequest })
        #expect(completion.requestId == "external-entry-1")
        #expect(completion.context == nil)
        #expect(completion.errorMessage == "capture refused")
    }

    @Test func sendsCompletePushToTalkControlWhenHandlerRuns() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        var observedAction: PickyPushToTalkControlAction?
        router.pushToTalkControlHandler = { request in
            observedAction = request.action
        }

        await router.connect()
        primary.emit(.protocolEvent(try makePushToTalkControlRequestEvent(action: "press")))

        try await waitUntil { primary.sentCommands.contains { $0.type == .completePushToTalkControlRequest } }
        let completion = try #require(primary.sentCommands.first { $0.type == .completePushToTalkControlRequest })
        #expect(observedAction == .press)
        #expect(completion.requestId == "ptt-control-1")
        #expect(completion.errorMessage == nil)
    }

    @Test func sendsCompletePushToTalkControlWithErrorMessageWhenHandlerThrows() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        struct StubFailure: LocalizedError { var errorDescription: String? { "button refused" } }
        router.pushToTalkControlHandler = { _ in throw StubFailure() }

        await router.connect()
        primary.emit(.protocolEvent(try makePushToTalkControlRequestEvent(action: "release")))

        try await waitUntil { primary.sentCommands.contains { $0.type == .completePushToTalkControlRequest } }
        let completion = try #require(primary.sentCommands.first { $0.type == .completePushToTalkControlRequest })
        #expect(completion.requestId == "ptt-control-1")
        #expect(completion.errorMessage == "button refused")
    }

    @Test func registersAppCapabilitiesWhenChildConnectsForPickleBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-capability", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-capability")
        poolFactory.emitReady(for: "pickle-capability")
        _ = try await spawned

        let child = try #require(clientFactory.madeClients.first?.client)
        try await waitUntil { child.sentCommands.contains { $0.type == .registerAppCapabilities } }
        let registration = try #require(child.sentCommands.first { $0.type == .registerAppCapabilities })
        #expect(registration.capabilities == ["pickleHandoff", "pickleBridge", "externalEntry", "pushToTalkControl"])
        #expect(primary.sentCommands.filter { $0.type == .registerAppCapabilities }.isEmpty)
    }

    @Test func spawnChildClientReturnsCachedClientOnRepeatLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-9", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-9")
        poolFactory.emitReady(for: "pickle-9")
        let firstClient = try await spawned

        let cachedClient = router.client(for: "pickle-9")
        #expect((firstClient as? StubAgentClient)?.id == (cachedClient as? StubAgentClient)?.id)
        #expect(clientFactory.madeClients.count == 1)
    }

    @Test func queuesChildInputUntilSessionLeavesQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-boot", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-boot")
        poolFactory.emitReady(for: "pickle-boot")
        let spawnedClient = try await spawned
        let child = try #require(spawnedClient as? StubAgentClient)

        let sawQueued = Task<Void, Never> {
            for await event in router.events {
                if case .protocolEvent(let envelope) = event,
                   case .sessionUpdated(let session) = envelope.event,
                   session.id == "pickle-boot",
                   session.status == .queued {
                    return
                }
            }
        }
        child.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-boot", status: .queued)))
        await sawQueued.value

        try await router.send(PickyCommandEnvelope(id: "cmd-follow-queued", type: .followUp, sessionId: "pickle-boot", text: "too early"))
        #expect(!child.sentCommands.contains { $0.id == "cmd-follow-queued" })

        child.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-boot", status: .running)))
        try await waitUntil { child.sentCommands.contains { $0.id == "cmd-follow-queued" } }
    }

    @Test func forwardsChildEventsThroughMergedEventStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)
        let forwarded = Task<PickyClientEvent?, Never> {
            for await event in router.events {
                if event == .recoverableError("child forwarded") { return event }
            }
            return nil
        }

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-events", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-events")
        poolFactory.emitReady(for: "pickle-events")
        _ = try await spawned
        clientFactory.madeClients.first?.client.emit(.recoverableError("child forwarded"))

        #expect(await forwarded.value == .recoverableError("child forwarded"))
    }

    @Test func sendReconnectsExistingChildEndpointWhenCachedClientWasDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-reconnect", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-reconnect")
        poolFactory.emitReady(for: "pickle-reconnect")
        let firstClient = try await spawned as? StubAgentClient
        #expect(firstClient?.connectCalls == 1)

        router.disconnect()
        #expect(pool.endpoint(for: "pickle-reconnect") != nil)

        try await router.send(PickyCommandEnvelope(id: "cmd-follow", type: .followUp, sessionId: "pickle-reconnect", text: "continue"))

        #expect(clientFactory.madeClients.count == 2)
        let secondClient = clientFactory.madeClients.last?.client
        #expect(secondClient?.connectCalls == 1)
        #expect(secondClient?.sentCommands.map(\.id) == ["cmd-follow"])
    }

    @Test func handlesPrimaryPickleHandoffRequestBySpawningChildAndCompletingPrimaryRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(
            primaryClient: primary,
            pool: pool,
            clientFactory: clientFactory,
            handoffPickleSessionIdFactory: { "pickle-handoff" }
        )

        await router.connect()
        async let runner = poolFactory.waitForRunner(sessionId: "pickle-handoff")
        primary.emit(.protocolEvent(try makePickleHandoffRequestEvent()))
        _ = try await runner
        poolFactory.emitReady(for: "pickle-handoff")
        try await waitUntil { clientFactory.madeClients.first?.client.sentCommands.contains(where: { $0.type == .createPickleFromHandoff }) == true }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!primary.sentCommands.contains(where: { $0.type == .completePickleHandoff }))

        let childCommand = try #require(clientFactory.madeClients.first?.client.sentCommands.first { $0.type == .createPickleFromHandoff })
        #expect(childCommand.context?.id == "context-handoff")
        #expect(childCommand.title == "조사 피클")
        #expect(childCommand.instructions == "Sentry 확인")
        #expect(childCommand.cwd == "/tmp/product/backend")

        clientFactory.madeClients.first?.client.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-handoff", title: "조사 피클")))
        try await waitUntil { primary.sentCommands.contains(where: { $0.type == .completePickleHandoff }) }
        let completion = try #require(primary.sentCommands.first(where: { $0.type == .completePickleHandoff }))
        #expect(completion.requestId == "handoff-request-1")
        #expect(completion.sessionId == "pickle-handoff")
        #expect(completion.title == "조사 피클")
        #expect(completion.cwd == "/tmp/product/backend")
    }

    @Test func handlesChildPickleCompletionBridgeRequestByNotifyingPrimaryAndAckingChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-completion", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-completion")
        poolFactory.emitReady(for: "pickle-completion")
        _ = try await spawned
        let child = try #require(clientFactory.madeClients.first?.client)

        child.emit(.protocolEvent(try makePickleBridgeRequestEvent(
            operation: "notifyMainOfPickleCompletion",
            sessionId: "pickle-completion",
            prompt: "Pickle finished prompt",
            cwd: "/tmp/ws"
        )))

        try await waitUntil { primary.sentCommands.contains { $0.type == .notifyMainOfPickleCompletion } }
        let notify = try #require(primary.sentCommands.first { $0.type == .notifyMainOfPickleCompletion })
        #expect(notify.sessionId == "pickle-completion")
        #expect(notify.prompt == "Pickle finished prompt")
        #expect(notify.cwd == "/tmp/ws")

        try await waitUntil { child.sentCommands.contains { $0.type == .completePickleBridgeRequest } }
        let ack = try #require(child.sentCommands.first { $0.type == .completePickleBridgeRequest })
        #expect(ack.requestId == "bridge-request-1")
        #expect(ack.delivered == true)
        #expect(primary.sentCommands.allSatisfy { $0.type != .completePickleBridgeRequest })
    }

    @Test func releaseChildDisconnectsAndAsksPoolToTerminate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-r", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-r")
        poolFactory.emitReady(for: "pickle-r")
        let client = try await spawned
        let stubClient = client as? StubAgentClient

        router.releaseChild(sessionId: "pickle-r")
        #expect(stubClient?.disconnectCalls == 1)
        #expect(pool.endpoint(for: "pickle-r") == nil)
    }

    @Test func sendFailsExplicitlyWhenKnownChildEndpointIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-missing", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-missing")
        poolFactory.emitReady(for: "pickle-missing")
        _ = try await spawned
        router.releaseChild(sessionId: "pickle-missing")

        do {
            try await router.send(PickyCommandEnvelope(type: .steer, sessionId: "pickle-missing", text: "continue"))
            Issue.record("Expected missing child endpoint error")
        } catch let error as PickyAgentClientRouterError {
            #expect(error == .missingChildEndpoint(sessionId: "pickle-missing"))
        }
        #expect(primary.sentCommands.isEmpty)
    }

    @Test func sendRespawnsRetiredChildSessionFromCacheBeforeForwardingInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)
        await router.connect()

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-restored", cwd: "/tmp/ws")
        let firstRunner = try await poolFactory.waitForRunner(sessionId: "pickle-restored")
        poolFactory.emitReady(for: "pickle-restored")
        _ = try await spawned
        router.releaseChild(sessionId: "pickle-restored")
        primary.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-restored", status: .completed)))
        await Task.yield()

        async let sent: Void = router.send(PickyCommandEnvelope(type: .followUp, sessionId: "pickle-restored", text: "continue"))
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let runner = poolFactory.runners["pickle-restored"], runner !== firstRunner, runner.launchCount > 0 {
                poolFactory.emitReady(for: "pickle-restored")
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await sent

        #expect(clientFactory.madeClients.count == 2)
        #expect(clientFactory.madeClients.last?.client.sentCommands.last?.type == .followUp)
        #expect(clientFactory.madeClients.last?.client.sentCommands.last?.sessionId == "pickle-restored")
        #expect(primary.sentCommands.allSatisfy { $0.type != .followUp && $0.type != .steer })
    }

    @Test func queuesInputWhileRestoredChildSessionIsBootingEvenWhenCachedStatusIsCompleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)
        await router.connect()

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-boot-completed", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-boot-completed")
        primary.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-boot-completed", status: .completed)))
        await Task.yield()

        try await router.send(PickyCommandEnvelope(type: .followUp, sessionId: "pickle-boot-completed", text: "continue"))
        poolFactory.emitReady(for: "pickle-boot-completed")
        _ = try await spawned
        guard let child = clientFactory.madeClients.last?.client else {
            Issue.record("Expected spawned child client")
            return
        }
        child.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-boot-completed", status: .completed)))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !clientFactory.madeClients.contains(where: { made in
            made.client.sentCommands.contains(where: { $0.type == .followUp })
        }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let drainedFollowUp = clientFactory.madeClients.contains { made in
            made.client.sentCommands.contains { command in
                command.type == .followUp && command.sessionId == "pickle-boot-completed"
            }
        }
        #expect(drainedFollowUp)
    }

    @Test func pickleBridgeListIncludesPrimarySnapshotSessions() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())

        await router.connect()
        let sawSnapshot = Task<Bool, Never> {
            for await event in router.events {
                if case .protocolEvent(let envelope) = event,
                   case .sessionSnapshot(let sessions) = envelope.event,
                   sessions.contains(where: { $0.id == "legacy-pickle" }) {
                    return true
                }
            }
            return false
        }
        primary.emit(.protocolEvent(makeSessionSnapshotEvent(id: "legacy-pickle", title: "Legacy Pickle")))
        #expect(await sawSnapshot.value)

        primary.emit(.protocolEvent(try makePickleBridgeRequestEvent(operation: "listSessions")))
        try await waitUntil { primary.sentCommands.contains(where: { $0.type == .completePickleBridgeRequest && $0.sessions?.first?.id == "legacy-pickle" }) }
    }

    @Test func pickleBridgeListEvictsOnlySessionsAbsentFromEmittingDaemonSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        await router.connect()
        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "child-session", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "child-session")
        poolFactory.emitReady(for: "child-session")
        _ = try await spawned
        guard let child = clientFactory.madeClients.first?.client else {
            Issue.record("Expected spawned child client")
            return
        }

        primary.emit(.protocolEvent(makeSessionUpdatedEvent(id: "primary-session")))
        child.emit(.protocolEvent(makeSessionUpdatedEvent(id: "child-session")))
        primary.emit(.protocolEvent(makeEmptySessionSnapshotEvent()))
        primary.emit(.protocolEvent(try makePickleBridgeRequestEvent(operation: "listSessions")))

        try await waitUntil {
            primary.sentCommands.contains { $0.type == .completePickleBridgeRequest }
        }
        let sessions = try #require(primary.sentCommands.last { $0.type == .completePickleBridgeRequest }?.sessions)
        #expect(!sessions.contains { $0.id == "primary-session" })
        #expect(sessions.contains { $0.id == "child-session" })
    }

    @Test func handlesPickleBridgeListAndSteerThroughChildSessionCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        await router.connect()
        try await Task.sleep(nanoseconds: 20_000_000)
        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-bridge", cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: "pickle-bridge")
        poolFactory.emitReady(for: "pickle-bridge")
        _ = try await spawned
        let sawChildSession = Task<Bool, Never> {
            for await event in router.events {
                if case .protocolEvent(let envelope) = event,
                   case .sessionUpdated(let session) = envelope.event,
                   session.id == "pickle-bridge" {
                    return true
                }
            }
            return false
        }
        clientFactory.madeClients.first?.client.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-bridge", title: "Bridge", finalAnswer: "done")))
        #expect(await sawChildSession.value)

        primary.emit(.protocolEvent(try makePickleBridgeRequestEvent(operation: "listSessions")))
        try await waitUntil { primary.sentCommands.contains(where: { $0.type == .completePickleBridgeRequest && $0.sessions?.first?.id == "pickle-bridge" }) }

        primary.emit(.protocolEvent(try makePickleBridgeRequestEvent(operation: "steer", sessionId: "pickle-bridge", text: "delta")))
        try await waitUntil { clientFactory.madeClients.first?.client.sentCommands.contains(where: { $0.type == .steer && $0.text == "delta" }) == true }
        try await waitUntil { primary.sentCommands.filter { $0.type == .completePickleBridgeRequest }.count >= 2 }
    }

    @Test func queuedDrainReportsUnsentCommandWhenChildExitsDuringFirstSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-drain-exit", cwd: "/tmp/ws")
        let runner = try await poolFactory.waitForRunner(sessionId: "pickle-drain-exit")
        poolFactory.emitReady(for: "pickle-drain-exit")
        let child = try #require(try await spawned as? StubAgentClient)
        child.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-drain-exit", status: .queued)))
        await Task.yield()

        let first = PickyCommandEnvelope(id: "cmd-drain-first", type: .followUp, sessionId: "pickle-drain-exit", text: "first")
        let second = PickyCommandEnvelope(id: "cmd-drain-second", type: .steer, sessionId: "pickle-drain-exit", text: "second")
        child.onSendSuspend = { command in
            guard command.id == first.id else { return }
            runner.emitTermination(exitCode: 9)
            // Keep the first send in flight until the child-exit callback
            // has examined the drain. The first send was already accepted;
            // later sends through the now-dead transport fail.
            try? await waitUntil { child.disconnectCalls == 1 }
            child.sendShouldThrow = PickyAgentClientError.disconnected
        }

        async let firstResult: PickyErrorEvent? = router.sendAwaitingError(first, timeout: 0.5)
        await Task.yield()
        // Wide deadline: the drain's child_unavailable rejection resolves this
        // immediately; a short window misreads a slow main-actor hop as success.
        async let secondResult: PickyErrorEvent? = router.sendAwaitingError(second, timeout: 5)
        await Task.yield()
        child.emit(.protocolEvent(makeSessionUpdatedEvent(id: "pickle-drain-exit", status: .running)))

        let secondError = try await secondResult
        let firstError = try await firstResult
        #expect(secondError?.commandId == second.id)
        #expect(secondError?.code == "child_unavailable")
        #expect(firstError == nil)
        #expect(child.sentCommands.filter { $0.id == first.id }.count == 1)
        #expect(!child.sentCommands.contains { $0.id == second.id })
    }

    @Test func oldDrainCannotMutateRespawnedChildGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)
        let sessionId = "pickle-generation-race"
        let errorRecorder = RouterErrorRecorder()
        let eventStream = router.events
        let errorObserver = Task {
            for await event in eventStream {
                errorRecorder.record(event)
            }
        }

        async let initialSpawn: PickyAgentClient = router.spawnChildClient(sessionId: sessionId, cwd: "/tmp/ws")
        let oldRunner = try await poolFactory.waitForRunner(sessionId: sessionId)
        poolFactory.emitReady(for: sessionId)
        let oldChild = try #require(try await initialSpawn as? StubAgentClient)
        oldChild.emit(.protocolEvent(makeSessionUpdatedEvent(id: sessionId, status: .queued)))
        await Task.yield()

        let oldFirst = PickyCommandEnvelope(id: "old-drain-first", type: .followUp, sessionId: sessionId, text: "old first")
        let oldSecond = PickyCommandEnvelope(id: "old-drain-second", type: .steer, sessionId: sessionId, text: "old second")
        var allowOldSendToUnwind = false
        oldChild.onSendSuspend = { command in
            guard command.id == oldFirst.id else { return }
            oldRunner.emitTermination(exitCode: 9)
            try? await waitUntil { oldChild.disconnectCalls == 1 }
            while !allowOldSendToUnwind { await Task.yield() }
            oldChild.sendShouldThrowAfterSuspend = PickyAgentClientError.disconnected
        }

        // Enqueue synchronously so the test does not depend on when an
        // `async let` begins executing under full-suite load.
        try await router.send(oldFirst)
        try await router.send(oldSecond)
        oldChild.emit(.protocolEvent(makeSessionUpdatedEvent(id: sessionId, status: .running)))
        try await waitUntil { oldChild.disconnectCalls == 1 }

        async let respawn: PickyAgentClient = router.spawnChildClient(sessionId: sessionId, cwd: "/tmp/ws")
        try await waitUntil {
            poolFactory.runners[sessionId] !== oldRunner && (poolFactory.runners[sessionId]?.launchCount ?? 0) > 0
        }
        poolFactory.emitReady(for: sessionId)
        let newChild = try #require(try await respawn as? StubAgentClient)
        let newRunner = try #require(poolFactory.runners[sessionId])
        newChild.emit(.protocolEvent(makeSessionUpdatedEvent(id: sessionId, status: .queued)))
        await Task.yield()

        let newFirst = PickyCommandEnvelope(id: "new-drain-first", type: .followUp, sessionId: sessionId, text: "new first")
        let newSecond = PickyCommandEnvelope(id: "new-drain-second", type: .steer, sessionId: sessionId, text: "new second")
        var allowNewSendToComplete = false
        newChild.onSendSuspend = { command in
            guard command.id == newFirst.id else { return }
            while !allowNewSendToComplete { await Task.yield() }
        }
        try await router.send(newFirst)
        try await router.send(newSecond)
        newChild.emit(.protocolEvent(makeSessionUpdatedEvent(id: sessionId, status: .running)))
        try await waitUntil { newChild.sentCommands.contains { $0.id == newFirst.id } }

        // Let the old send throw only after the same session id owns a new,
        // suspended drain. Its cleanup must neither requeue old commands nor
        // erase the new drain's active remainder.
        allowOldSendToUnwind = true
        try await waitUntil {
            errorRecorder.error(for: oldFirst.id) != nil && errorRecorder.error(for: oldSecond.id) != nil
        }
        #expect(errorRecorder.error(for: oldFirst.id)?.code == "child_unavailable")
        #expect(errorRecorder.error(for: oldSecond.id)?.code == "child_unavailable")
        #expect(!newChild.sentCommands.contains { $0.id == oldFirst.id || $0.id == oldSecond.id })

        newRunner.emitTermination(exitCode: 9)
        try await waitUntil { errorRecorder.error(for: newSecond.id) != nil }
        #expect(errorRecorder.error(for: newSecond.id)?.code == "child_unavailable")
        #expect(errorRecorder.error(for: newSecond.id)?.commandId == newSecond.id)

        allowNewSendToComplete = true
        await Task.yield()
        router.disconnect()
        await errorObserver.value
    }

    @Test func queuedBootingChildCommandReportsErrorWhenChildExitsBeforeDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let primary = StubAgentClient(id: "primary")
        let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: poolFactory
        )
        let clientFactory = StubClientFactory()
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)

        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: "pickle-exit", cwd: "/tmp/ws")
        let runner = try await poolFactory.waitForRunner(sessionId: "pickle-exit")
        poolFactory.emitReady(for: "pickle-exit")
        let child = try #require(try await spawned as? StubAgentClient)

        let command = PickyCommandEnvelope(id: "cmd-dropped-on-exit", type: .followUp, sessionId: "pickle-exit", text: "continue")
        async let awaitingError: PickyErrorEvent? = router.sendAwaitingError(command, timeout: 0.5)
        await Task.yield()
        runner.emitTermination(exitCode: 9)

        let error = try await awaitingError
        #expect(error?.commandId == command.id)
        #expect(error?.code == "child_unavailable")
        #expect(!child.sentCommands.contains { $0.id == command.id })
    }

    @Test func sendAwaitingErrorReturnsRejectionWhenDaemonEmitsMatchingError() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        let command = PickyCommandEnvelope(type: .steer, sessionId: "session-X", text: "hello")
        async let awaiter: PickyErrorEvent? = router.sendAwaitingError(command, timeout: 2.0)

        try await waitUntil { primary.sentCommands.contains { $0.id == command.id } }
        primary.emit(.protocolEvent(makeErrorEnvelope(commandId: command.id, message: "Unknown session: session-X")))

        let rejection = try await awaiter
        #expect(rejection?.commandId == command.id)
        #expect(rejection?.message == "Unknown session: session-X")
        #expect(rejection?.code == "bad_message")
    }

    @Test func sendAwaitingErrorReturnsNilOnTimeoutWhenNoMatchingErrorArrives() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        let command = PickyCommandEnvelope(type: .steer, sessionId: "session-Y", text: "hi")
        let rejection = try await router.sendAwaitingError(command, timeout: 0.05)

        #expect(rejection == nil)
        #expect(primary.sentCommands.contains { $0.id == command.id })
    }

    @Test func sendAwaitingErrorRethrowsTransportFailures() async throws {
        // Regression: when the underlying transport fails (websocket dead,
        // encoding error, missing-child-endpoint, …) `sendAwaitingError`
        // must propagate the throw so the caller's existing `catch` can
        // surface a real error to the user. Previously the router caught
        // the send failure and resumed with `nil`, which callers interpret
        // as "no rejection → success" — re-creating the silent-success bug
        // this entire path was added to fix.
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        primary.sendShouldThrow = PickyAgentClientError.disconnected
        let command = PickyCommandEnvelope(type: .steer, sessionId: "session-broken", text: "x")

        await #expect(throws: PickyAgentClientError.disconnected) {
            _ = try await router.sendAwaitingError(command, timeout: 0.5)
        }
    }

    @Test func newSubscriberReceivesLastKnownConnectionStateImmediately() async throws {
        // Regression: HUD starts before Companion in `PickyApp`, so by the
        // time Companion subscribes to the shared router's events the
        // primary client may have already emitted `.connected`. Without a
        // replay of the most recent lifecycle state, Companion never sees
        // `.connected` and its bootstrap handler (which fetches the model
        // list and main-agent messages) never runs — leaving the model
        // picker stuck on "loading".
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        // Wait for the primary `.connected` event to be broadcast through
        // the router's forwarder.
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        let lateSubscriber = router.events

        async let receivedConnected: Bool = {
            for await event in lateSubscriber {
                if case .connected = event { return true }
            }
            return false
        }()

        // Give the replay yield a moment, then close the stream so the
        // for-await terminates whether or not the replay happened.
        try await Task.sleep(nanoseconds: 200_000_000)
        router.disconnect()

        let didReceive = await receivedConnected
        #expect(didReceive)
    }

    @Test func sendAwaitingErrorCatchesRejectionEvenWhenEmittedDuringSend() async throws {
        // Regression: agentd unicasts `type="error"` on the same socket
        // *during* command handling, so on a hot localhost connection the
        // rejection event can be forwarded into the router's event stream
        // before the caller of `sendAwaitingError` has installed its pending
        // handler. The handler must therefore be registered *before* the send
        // is dispatched.
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        let command = PickyCommandEnvelope(type: .steer, sessionId: "session-fast", text: "x")
        // Emit the matching error event while `send` is still on the
        // call stack (and before the awaiter installs its handler under
        // the buggy ordering). `StubAgentClient.send` then `Task.yield()`s
        // so the forwarder task can run and "miss" the handler if the
        // ordering is wrong.
        primary.onSendInject = { [weak primary] cmd in
            primary?.emit(.protocolEvent(makeErrorEnvelope(commandId: cmd.id, message: "fast reject")))
        }

        let rejection = try await router.sendAwaitingError(command, timeout: 0.5)
        #expect(rejection?.commandId == command.id)
        #expect(rejection?.message == "fast reject")
    }

    @Test func routerEventsBroadcastToMultipleSubscribers() async throws {
        // Regression: PickyApp wires the HUD viewModel and CompanionManager
        // to the same router so they share a single primary daemon socket.
        // Both subscribe to `router.events`, so the router must fan an
        // arriving event out to every active for-await loop. A single-
        // consumer AsyncStream would silently drop one of the subscribers.
        //
        // Both subscribers run concurrently via `async let` so they observe
        // the same emitted event. After emit we schedule a `router.disconnect()`
        // so the streams finish in bounded time — AsyncStream does NOT honor
        // task cancellation by itself, so without a `finish()`-triggering
        // disconnect the for-await loops would hang forever even when wrapped
        // in a task group.
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        let subscriberA = router.events
        let subscriberB = router.events

        async let resultA: Bool = {
            for await event in subscriberA {
                if case .protocolEvent(let envelope) = event,
                   case .sessionUpdated(let session) = envelope.event,
                   session.id == "session-broadcast" {
                    return true
                }
            }
            return false
        }()
        async let resultB: Bool = {
            for await event in subscriberB {
                if case .protocolEvent(let envelope) = event,
                   case .sessionUpdated(let session) = envelope.event,
                   session.id == "session-broadcast" {
                    return true
                }
            }
            return false
        }()

        // Yield a moment so both for-await loops attach to the stream
        // before the broadcast event is emitted.
        try await Task.sleep(nanoseconds: 50_000_000)
        primary.emit(.protocolEvent(makeSessionUpdatedEvent(id: "session-broadcast")))
        // Give the forwarder + subscribers a moment, then close the streams
        // so the for-await loops terminate even if they did not receive the
        // broadcast event (single-subscriber AsyncStream case).
        try await Task.sleep(nanoseconds: 200_000_000)
        router.disconnect()

        let receivedByA = await resultA
        let receivedByB = await resultB
        #expect(receivedByA)
        #expect(receivedByB)
    }

    @Test func sendAwaitingErrorIgnoresErrorEventsForUnrelatedCommandIds() async throws {
        let primary = StubAgentClient(id: "primary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(token: "tok", appSupportRoot: root)
        )
        let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: StubClientFactory())
        await router.connect()
        try await waitUntil { primary.sentCommands.contains { $0.type == .registerAppCapabilities } }

        let command = PickyCommandEnvelope(type: .steer, sessionId: "session-Z", text: "hey")
        async let awaiter: PickyErrorEvent? = router.sendAwaitingError(command, timeout: 0.15)

        try await waitUntil { primary.sentCommands.contains { $0.id == command.id } }
        // Unrelated command's error must not unblock the awaiter.
        primary.emit(.protocolEvent(makeErrorEnvelope(commandId: "cmd-OTHER", message: "some other failure")))

        let rejection = try await awaiter
        #expect(rejection == nil)
    }

    // MARK: - broadcast

    @Test func broadcastTargetCountIncludesPrimaryAndCachedChildren() async throws {
        let setup = try await setUpRouterWithChildren(sessionIds: ["pickle-a", "pickle-b"])
        #expect(setup.router.broadcastTargetCount == 3)
    }

    @Test func broadcastSendsCommandToPrimaryAndAllChildren() async throws {
        let setup = try await setUpRouterWithChildren(sessionIds: ["pickle-a", "pickle-b"])
        let command = PickyCommandEnvelope(type: .reloadPlugins)
        let delivered = try await setup.router.broadcast(command)

        #expect(delivered == 3)
        #expect(setup.primary.sentCommands.contains { $0.id == command.id && $0.type == .reloadPlugins })
        for child in setup.children {
            #expect(child.sentCommands.contains { $0.id == command.id && $0.type == .reloadPlugins })
        }
    }

    @Test func broadcastReportsActualDeliveryCountWhenChildFails() async throws {
        let setup = try await setUpRouterWithChildren(sessionIds: ["pickle-good", "pickle-bad"])
        if let badChild = setup.children.last {
            badChild.sendShouldThrow = PickyAgentClientError.disconnected
        }

        let command = PickyCommandEnvelope(type: .reloadPlugins)
        let delivered = try await setup.router.broadcast(command)

        #expect(delivered == 2)
    }

    @Test func broadcastThrowsWhenEveryTargetFails() async throws {
        let setup = try await setUpRouterWithChildren(sessionIds: ["pickle-x"])
        setup.primary.sendShouldThrow = PickyAgentClientError.disconnected
        for child in setup.children { child.sendShouldThrow = PickyAgentClientError.disconnected }

        do {
            _ = try await setup.router.broadcast(PickyCommandEnvelope(type: .reloadPlugins))
            Issue.record("expected broadcast to throw when all targets fail")
        } catch {
            // Pass — first error propagated.
        }
    }
}

private struct RouterBroadcastSetup {
    let router: PickyAgentClientRouter
    let primary: StubAgentClient
    let children: [StubAgentClient]
}

@MainActor
private func setUpRouterWithChildren(sessionIds: [String]) async throws -> RouterBroadcastSetup {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-router-\(UUID().uuidString)", isDirectory: true)
    let agentd = root.appendingPathComponent("agentd", isDirectory: true)
    try makeStubAgentdPackage(at: agentd)
    let primary = StubAgentClient(id: "primary")
    let poolFactory = StubLauncherFactoryForRouter(agentdRoot: agentd)
    let pool = PickyAgentDaemonPool(
        configuration: PickyAgentDaemonPool.Configuration(
            token: "tok",
            appSupportRoot: root,
            environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
            bundleResourceURL: nil
        ),
        factory: poolFactory
    )
    let clientFactory = StubClientFactory()
    let router = PickyAgentClientRouter(primaryClient: primary, pool: pool, clientFactory: clientFactory)
    await router.connect()

    var children: [StubAgentClient] = []
    for sessionId in sessionIds {
        async let spawned: PickyAgentClient = router.spawnChildClient(sessionId: sessionId, cwd: "/tmp/ws")
        _ = try await poolFactory.waitForRunner(sessionId: sessionId)
        poolFactory.emitReady(for: sessionId)
        let resolved = try await spawned
        guard let stub = resolved as? StubAgentClient else {
            throw PickyAgentClientError.disconnected
        }
        children.append(stub)
    }
    return RouterBroadcastSetup(router: router, primary: primary, children: children)
}

private func makeErrorEnvelope(commandId: String, code: String = "bad_message", message: String) -> PickyEventEnvelope {
    PickyEventEnvelope(
        id: "event-error-\(commandId)",
        protocolVersion: pickyAgentProtocolVersion,
        timestamp: Date(),
        event: .error(PickyErrorEvent(code: code, message: message, commandId: commandId))
    )
}

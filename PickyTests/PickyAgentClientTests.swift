//
//  PickyAgentClientTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakeWebSocketTask: PickyWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private let incomingContinuation: AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.Continuation
    private var incomingIterator: AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.Iterator
    private var _sentMessages: [URLSessionWebSocketTask.Message] = []
    private var _didResume = false
    private var _didCancel = false

    var sentMessages: [URLSessionWebSocketTask.Message] { lock.withLock { _sentMessages } }
    var didResume: Bool { lock.withLock { _didResume } }
    var didCancel: Bool { lock.withLock { _didCancel } }

    init() {
        var continuation: AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.Continuation!
        let incoming = AsyncStream<Result<URLSessionWebSocketTask.Message, Error>> { continuation = $0 }
        incomingContinuation = continuation
        incomingIterator = incoming.makeAsyncIterator()
    }

    func enqueue(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        incomingContinuation.yield(result)
    }

    func enqueue(contentsOf results: [Result<URLSessionWebSocketTask.Message, Error>]) {
        results.forEach(enqueue)
    }

    func resume() { lock.withLock { _didResume = true } }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { _sentMessages.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let result = await incomingIterator.next() else { throw CancellationError() }
        return try result.get()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { _didCancel = true }
        incomingContinuation.finish()
    }
}

private final class FakeWebSocketFactory: PickyWebSocketTaskMaking {
    let task: FakeWebSocketTask
    private(set) var requestedURL: URL?
    private(set) var requestedToken: String?

    init(task: FakeWebSocketTask) { self.task = task }

    func makeWebSocketTask(url: URL, token: String) -> PickyWebSocketTask {
        requestedURL = url
        requestedToken = token
        return task
    }
}

private enum EventJSON {
    static func hello() -> String {
        """
        {"id":"event-hello","protocolVersion":"\(pickyAgentProtocolVersion)","timestamp":"2026-05-01T00:00:00.000Z","type":"hello","serverName":"picky-agentd","supportedProtocolVersions":["\(pickyAgentProtocolVersion)"]}
        """
    }
}

private func nextPickyAgentClientEvent(
    from stream: AsyncStream<PickyClientEvent>
) async throws -> PickyClientEvent? {
    try await withPickyTestTimeout("picky-agent client event") {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

struct PickyAgentClientTests {
    @Test func connectsToLocalhostWithTokenAndSendsListSessions() async throws {
        let task = FakeWebSocketTask()
        task.enqueue(.success(.string(EventJSON.hello())))
        let factory = FakeWebSocketFactory(task: task)
        let client = WebSocketPickyAgentClient(
            configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01),
            factory: factory
        )
        await client.connect()
        if case .connected? = try await nextPickyAgentClientEvent(from: client.events) {} else { Issue.record("Expected connected after hello") }
        try await client.send(PickyCommandEnvelope(id: "cmd-list-001", type: .listSessions))

        #expect(task.didResume)
        #expect(factory.requestedURL?.host == "127.0.0.1")
        #expect(factory.requestedURL?.query?.contains("token=secret") == true)
        #expect(factory.requestedToken == "secret")
        guard case .string(let text) = task.sentMessages.first else {
            Issue.record("Expected string command")
            return
        }
        #expect(text.contains("\"type\":\"listSessions\"") || text.contains("\"type\" : \"listSessions\""))
    }

    @Test func sendWaitsForHelloWhenCommandFollowsConnectImmediately() async throws {
        let task = FakeWebSocketTask()
        let client = WebSocketPickyAgentClient(
            configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01, connectionReadyTimeout: 1),
            factory: FakeWebSocketFactory(task: task)
        )

        await client.connect()
        let sendTask = Task {
            try await client.send(PickyCommandEnvelope(id: "cmd-list-after-connect", type: .listSessions))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(task.sentMessages.isEmpty)

        task.enqueue(.success(.string(EventJSON.hello())))
        try await withPickyTestTimeout("command send after hello") {
            try await sendTask.value
        }

        #expect(task.sentMessages.count == 1)
    }

    @Test func encodesRewindAndDiffCommands() throws {
        let encoder = JSONEncoder.pickyAgentProtocolEncoder()

        let listData = try encoder.encode(PickyCommandEnvelope(id: "cmd-rewind-list", type: .listRewindTargets, sessionId: "session-1"))
        let listJSON = try #require(String(data: listData, encoding: .utf8))
        #expect(listJSON.contains("\"type\":\"listRewindTargets\"") || listJSON.contains("\"type\" : \"listRewindTargets\""))
        #expect(listJSON.contains("\"sessionId\":\"session-1\"") || listJSON.contains("\"sessionId\" : \"session-1\""))
        #expect(listJSON.contains("\"protocolVersion\":\"\(pickyAgentProtocolVersion)\"") || listJSON.contains("\"protocolVersion\" : \"\(pickyAgentProtocolVersion)\""))

        let rewindData = try encoder.encode(PickyCommandEnvelope(id: "cmd-rewind", type: .rewindSession, sessionId: "session-1", entryId: "entry-3"))
        let rewindJSON = try #require(String(data: rewindData, encoding: .utf8))
        #expect(rewindJSON.contains("\"type\":\"rewindSession\"") || rewindJSON.contains("\"type\" : \"rewindSession\""))
        #expect(rewindJSON.contains("\"sessionId\":\"session-1\"") || rewindJSON.contains("\"sessionId\" : \"session-1\""))
        #expect(rewindJSON.contains("\"entryId\":\"entry-3\"") || rewindJSON.contains("\"entryId\" : \"entry-3\""))

        let diffData = try encoder.encode(PickySessionDiffCommand(id: "cmd-diff", sessionId: "session-1", requestId: "request-diff", view: .staged))
        let diffJSON = try #require(String(data: diffData, encoding: .utf8))
        #expect(diffJSON.contains("\"type\":\"getSessionDiff\"") || diffJSON.contains("\"type\" : \"getSessionDiff\""))
        #expect(diffJSON.contains("\"view\":\"staged\"") || diffJSON.contains("\"view\" : \"staged\""))
        #expect(diffJSON.contains("\"requestId\":\"request-diff\"") || diffJSON.contains("\"requestId\" : \"request-diff\""))

        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(PickySessionDiffCommand.self, from: Data("""
            {"id":"cmd-diff-missing-request","protocolVersion":"2026-07-23","type":"getSessionDiff","sessionId":"session-1","view":"staged"}
            """.utf8))
        }
    }

    @Test func encodesAndDecodesSessionRuntimePickerProtocol() throws {
        let encoder = JSONEncoder.pickyAgentProtocolEncoder()
        let command = try encoder.encode(PickyCommandEnvelope(id: "cmd-runtime-model", type: .setSessionModel, sessionId: "session-1", provider: "openai-codex", modelId: "gpt-5.5"))
        let commandJSON = try #require(String(data: command, encoding: .utf8))
        #expect(commandJSON.contains("\"type\":\"setSessionModel\"") || commandJSON.contains("\"type\" : \"setSessionModel\""))
        #expect(commandJSON.contains("\"provider\":\"openai-codex\"") || commandJSON.contains("\"provider\" : \"openai-codex\""))

        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let event = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-runtime-options","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:02.000Z","type":"sessionRuntimeOptionsSnapshot","sessionId":"session-1","requestId":"cmd-runtime-options","models":[{"provider":"openai-codex","modelId":"gpt-5.5","displayName":"GPT-5.5","pattern":"openai-codex/gpt-5.5"}],"thinkingLevels":["low","high"],"currentModel":{"provider":"openai-codex","modelId":"gpt-5.5"}}
        """.utf8))
        if case .sessionRuntimeOptionsSnapshot(let sessionID, let requestID, let models, let allModels, let globalScope, let projectScope, let effectiveScope, let thinkingLevels, let currentModel) = event.event {
            #expect(sessionID == "session-1")
            #expect(requestID == "cmd-runtime-options")
            #expect(models.map(\.pattern) == ["openai-codex/gpt-5.5"])
            #expect(allModels == nil)
            #expect(globalScope == nil)
            #expect(projectScope == nil)
            #expect(effectiveScope == nil)
            #expect(thinkingLevels == [.low, .high])
            #expect(currentModel == PickySessionRuntimeModelIdentity(provider: "openai-codex", modelId: "gpt-5.5"))
        } else { Issue.record("Expected sessionRuntimeOptionsSnapshot") }
    }

    @Test func decodesRuntimeScopeMetadataAndEncodesGlobalScopeCommand() throws {
        let encoder = JSONEncoder.pickyAgentProtocolEncoder()
        let command = try encoder.encode(PickyCommandEnvelope(
            id: "cmd-global-model-scope",
            type: .setGlobalModelScope,
            mode: .exact,
            patterns: ["openai-codex/gpt-5.5"],
            expectedRevision: "opaque-revision"
        ))
        let commandJSON = try #require(String(data: command, encoding: .utf8))
        #expect(commandJSON.contains("\"mode\":\"exact\"") || commandJSON.contains("\"mode\" : \"exact\""))
        #expect(commandJSON.contains("\"expectedRevision\":\"opaque-revision\"") || commandJSON.contains("\"expectedRevision\" : \"opaque-revision\""))

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-runtime-scope","protocolVersion":"2026-08-25","timestamp":"2026-05-01T00:00:02.000Z","type":"sessionRuntimeOptionsSnapshot","sessionId":"session-1","requestId":"cmd-runtime-options","models":[{"provider":"openai-codex","modelId":"gpt-5.5","displayName":"openai-codex/gpt-5.5","pattern":"openai-codex/gpt-5.5"}],"allModels":[{"provider":"openai-codex","modelId":"gpt-5.5","displayName":"openai-codex/gpt-5.5","pattern":"openai-codex/gpt-5.5"}],"globalScope":{"mode":"exact","patterns":["openai-codex/gpt-5.5"],"editable":true,"revision":"opaque-revision","resolvedModelIds":["openai-codex/gpt-5.5"]},"projectScope":{"mode":"all","patterns":[],"editable":true},"effectiveScope":{"mode":"all","patterns":[],"editable":true},"thinkingLevels":["low"]}
        """.utf8))
        guard case .sessionRuntimeOptionsSnapshot(_, _, _, let allModels, let globalScope, let projectScope, let effectiveScope, _, _) = event.event else {
            Issue.record("Expected sessionRuntimeOptionsSnapshot")
            return
        }
        #expect(allModels?.count == 1)
        #expect(globalScope?.revision == "opaque-revision")
        #expect(globalScope?.resolvedModelIds == ["openai-codex/gpt-5.5"])
        #expect(projectScope?.mode == .all)
        #expect(effectiveScope?.mode == .all)
    }

    @Test func runtimeOptionsRequestIgnoresStaleSessionAndRequestResponses() async throws {
        let task = FakeWebSocketTask()
        task.enqueue(.success(.string(EventJSON.hello())))
        let client = WebSocketPickyAgentClient(
            configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01),
            factory: FakeWebSocketFactory(task: task)
        )
        await client.connect()
        _ = try await nextPickyAgentClientEvent(from: client.events)

        let request = Task { try await client.listSessionRuntimeOptions(sessionId: "session-1") }
        try await withPickyTestTimeout("runtime options command") {
            while task.sentMessages.isEmpty { await Task.yield() }
        }
        guard case .string(let commandJSON) = try #require(task.sentMessages.last),
              let commandData = commandJSON.data(using: .utf8),
              let command = try? JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: commandData)
        else {
            Issue.record("Expected runtime options command")
            return
        }

        task.enqueue(.success(.string("""
        {"id":"event-runtime-stale-session","protocolVersion":"\(pickyAgentProtocolVersion)","timestamp":"2026-05-01T00:00:02.000Z","type":"sessionRuntimeOptionsSnapshot","sessionId":"session-other","requestId":"\(command.id)","models":[{"provider":"stale","modelId":"model","displayName":"Stale","pattern":"stale/model"}],"thinkingLevels":["low"]}
        """)))
        task.enqueue(.success(.string("""
        {"id":"event-runtime-stale-request","protocolVersion":"\(pickyAgentProtocolVersion)","timestamp":"2026-05-01T00:00:02.000Z","type":"sessionRuntimeOptionsSnapshot","sessionId":"session-1","requestId":"other-request","models":[{"provider":"stale","modelId":"model","displayName":"Stale","pattern":"stale/model"}],"thinkingLevels":["low"]}
        """)))
        task.enqueue(.success(.string("""
        {"id":"event-runtime-current","protocolVersion":"\(pickyAgentProtocolVersion)","timestamp":"2026-05-01T00:00:02.000Z","type":"sessionRuntimeOptionsSnapshot","sessionId":"session-1","requestId":"\(command.id)","models":[{"provider":"openai-codex","modelId":"gpt-5.5","displayName":"GPT-5.5","pattern":"openai-codex/gpt-5.5"}],"thinkingLevels":["low","high"],"currentModel":{"provider":"openai-codex","modelId":"gpt-5.5"}}
        """)))

        let options = try await request.value
        #expect(options.models.map(\.provider) == ["openai-codex"])
        #expect(options.currentModel == PickySessionRuntimeModelIdentity(provider: "openai-codex", modelId: "gpt-5.5"))
    }

    @Test func decodesRewindAndDiffEvents() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let targets = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-rewind-targets","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:02.000Z","type":"rewindTargetsSnapshot","sessionId":"session-1","requestId":"cmd-rewind-list","targets":[{"entryId":"entry-1","text":"첫 요청","createdAt":"2026-05-01T00:00:00.000Z"},{"entryId":"entry-2","text":"다음 요청","createdAt":null}]}
        """.utf8))
        if case .rewindTargetsSnapshot(let sessionId, let requestId, let rewindTargets) = targets.event {
            #expect(sessionId == "session-1")
            #expect(requestId == "cmd-rewind-list")
            #expect(rewindTargets == [
                PickyRewindTarget(entryId: "entry-1", text: "첫 요청", createdAt: Date(timeIntervalSince1970: 1_777_593_600)),
                PickyRewindTarget(entryId: "entry-2", text: "다음 요청", createdAt: nil)
            ])
        } else { Issue.record("Expected rewindTargetsSnapshot") }

        let diff = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-diff","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:03.000Z","type":"sessionDiffResult","sessionId":"session-1","view":"unstaged","isGitRepo":true,"files":[{"path":"Picky/App.swift","status":"modified","additions":4,"deletions":2,"diff":"@@ -1 +1 @@\\n-old\\n+new","truncated":false}],"filesTruncated":false,"requestId":"cmd-diff"}
        """.utf8))
        if case .sessionDiffResult(let result) = diff.event {
            #expect(result.sessionId == "session-1")
            #expect(result.view == .unstaged)
            #expect(result.files.first?.status == .modified)
            #expect(result.files.first?.additions == 4)
            #expect(result.requestID == "cmd-diff")
        } else { Issue.record("Expected sessionDiffResult") }

        #expect(throws: DecodingError.self) {
            try decoder.decode(PickyEventEnvelope.self, from: Data("""
            {"id":"event-diff-missing-request","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:03.000Z","type":"sessionDiffResult","sessionId":"session-1","view":"unstaged","isGitRepo":true,"files":[],"filesTruncated":false}
            """.utf8))
        }

        let rewound = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-rewound","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:03.000Z","type":"sessionRewound","sessionId":"session-1","editorText":"다시 작성할 요청","removedIds":["message-2","message-3"]}
        """.utf8))
        if case .sessionRewound(let sessionId, let editorText, let removedIds) = rewound.event {
            #expect(sessionId == "session-1")
            #expect(editorText == "다시 작성할 요청")
            #expect(removedIds == ["message-2", "message-3"])
        } else { Issue.record("Expected sessionRewound") }
    }

    @Test func doesNotSendBeforeHelloOpensWebSocket() async throws {
        let task = FakeWebSocketTask()
        let client = WebSocketPickyAgentClient(
            configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01, connectionReadyTimeout: 0.01),
            factory: FakeWebSocketFactory(task: task)
        )

        await client.connect()
        await #expect(throws: PickyAgentClientError.disconnected) {
            try await client.send(PickyCommandEnvelope(id: "cmd-list-early", type: .listSessions))
        }
        #expect(task.sentMessages.isEmpty)
    }

    @Test func submitRoutesTaskForQuickReplyOrHandOff() async throws {
        let task = FakeWebSocketTask()
        task.enqueue(.success(.string(EventJSON.hello())))
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        await client.connect()
        if case .connected? = try await nextPickyAgentClientEvent(from: client.events) {} else { Issue.record("Expected connected after hello") }
        let context = PickyContextPacket(
            id: "context-route",
            source: "voice",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "마이크 테스트",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )

        let receipt = try await client.submit(PickyAgentSubmission(transcript: "마이크 테스트", context: context))

        #expect(receipt.message.isEmpty)
        guard case .string(let text) = task.sentMessages.first else {
            Issue.record("Expected string command")
            return
        }
        #expect(text.contains("\"type\":\"routeTask\"") || text.contains("\"type\" : \"routeTask\""))
    }

    @Test func receivesHelloAndSessionUpdatedEvents() async throws {
        let task = FakeWebSocketTask()
        task.enqueue(contentsOf: [
            .success(.string(EventJSON.hello())),
            .success(.string("""
            {"id":"event-session","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionUpdated","session":{"id":"session-1","title":"Work","status":"running","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
            """))
        ])
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        await client.connect()

        _ = try await nextPickyAgentClientEvent(from: client.events) // connected
        let hello = try await nextPickyAgentClientEvent(from: client.events)
        let session = try await nextPickyAgentClientEvent(from: client.events)

        if case .protocolEvent(let event)? = hello {
            #expect(event.event == .hello(PickyHelloEvent(serverName: "picky-agentd", supportedProtocolVersions: [pickyAgentProtocolVersion])))
        } else { Issue.record("Expected hello") }

        if case .protocolEvent(let event)? = session,
           case .sessionUpdated(let pickySession) = event.event {
            #expect(pickySession.id == "session-1")
            #expect(pickySession.status == .running)
        } else { Issue.record("Expected sessionUpdated") }
    }

    @Test func encodesPackageCommandsAndDecodesUpdateEvents() throws {
        let encoder = JSONEncoder.pickyAgentProtocolEncoder()
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        let install = try String(decoding: encoder.encode(PickyCommandEnvelope(
            id: "cmd-package-install",
            type: .installPackage,
            source: "npm:@example/plugin"
        )), as: UTF8.self)
        let remove = try String(decoding: encoder.encode(PickyCommandEnvelope(
            id: "cmd-package-remove",
            type: .removePackage,
            source: "npm:@example/plugin"
        )), as: UTF8.self)
        let check = try String(decoding: encoder.encode(PickyCommandEnvelope(
            id: "cmd-package-check",
            type: .checkPackageUpdates
        )), as: UTF8.self)
        let update = try String(decoding: encoder.encode(PickyCommandEnvelope(
            id: "cmd-package-update",
            type: .updatePackage,
            source: "npm:@example/plugin"
        )), as: UTF8.self)
        #expect(install.contains("\"type\":\"installPackage\"") || install.contains("\"type\" : \"installPackage\""))
        #expect(remove.contains("\"type\":\"removePackage\"") || remove.contains("\"type\" : \"removePackage\""))
        #expect(check.contains("\"type\":\"checkPackageUpdates\"") || check.contains("\"type\" : \"checkPackageUpdates\""))
        #expect(update.contains("\"type\":\"updatePackage\"") || update.contains("\"type\" : \"updatePackage\""))
        let decodedInstall = try decoder.decode(PickyCommandEnvelope.self, from: Data(install.utf8))
        #expect(decodedInstall.source == "npm:@example/plugin")

        let available = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-package-updates","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:01.000Z","type":"packageUpdatesAvailable","commandId":"cmd-package-check","sources":["npm:@example/plugin"],"failed":true}
        """.utf8))
        if case .packageUpdatesAvailable(let event) = available.event {
            #expect(event.commandId == "cmd-package-check")
            #expect(event.sources == ["npm:@example/plugin"])
            #expect(event.failed == true)
        } else { Issue.record("Expected packageUpdatesAvailable") }

        let progress = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-package-progress","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:02.000Z","type":"packageOperationProgress","requestId":"cmd-package-install","operation":"install","source":"npm:@example/plugin","message":"Installing npm:@example/plugin..."}
        """.utf8))
        if case .packageOperationProgress(let event) = progress.event {
            #expect(event.requestId == "cmd-package-install")
            #expect(event.operation == .install)
            #expect(event.source == "npm:@example/plugin")
        } else { Issue.record("Expected packageOperationProgress") }

        let completion = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-package-completed","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:03.000Z","type":"packageOperationCompleted","requestId":"cmd-package-update","operation":"update","source":"npm:@example/plugin","ok":false,"errorMessage":"npm was not found"}
        """.utf8))
        if case .packageOperationCompleted(let event) = completion.event {
            #expect(event.requestId == "cmd-package-update")
            #expect(event.operation == .update)
            #expect(event.ok == false)
            #expect(event.errorMessage == "npm was not found")
        } else { Issue.record("Expected packageOperationCompleted") }
    }

    @Test func decodesMainActivityAndMainExtensionUiEvents() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        let activity = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-main-activity","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:00.000Z","type":"mainActivityUpdated","activity":{"kind":"tool","toolCallId":"tool-1","toolName":"read","status":"running","argsPreview":"{\\"path\\":\\"Picky/Overlay/BlueCursorView.swift\\"}"}}
        """.utf8))
        if case .mainActivityUpdated(let mainActivity) = activity.event {
            #expect(mainActivity == PickyMainActivity(
                kind: .tool,
                toolCallId: "tool-1",
                toolName: "read",
                status: "running",
                argsPreview: #"{"path":"Picky/Overlay/BlueCursorView.swift"}"#
            ))
        } else { Issue.record("Expected mainActivityUpdated") }

        let clear = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-main-activity-clear","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:00.000Z","type":"mainActivityUpdated"}
        """.utf8))
        if case .mainActivityUpdated(let mainActivity) = clear.event {
            #expect(mainActivity == nil)
        } else { Issue.record("Expected cleared mainActivityUpdated") }

        let request = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-main-question","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:00.000Z","type":"mainExtensionUiRequested","request":{"id":"question-1","sessionId":"picky-main","method":"askUserQuestion","title":"Proceed?","description":"Choose an option.","questions":[{"id":"choice","type":"radio","options":["yes","no"]}],"createdAt":"2026-05-01T00:00:00.000Z"}}
        """.utf8))
        if case .mainExtensionUiRequested(let mainRequest) = request.event {
            #expect(mainRequest.id == "question-1")
            #expect(mainRequest.sessionId == "picky-main")
            #expect(mainRequest.method == "askUserQuestion")
            #expect(mainRequest.questions?.first?.options?.map(\.value) == ["yes", "no"])
        } else { Issue.record("Expected mainExtensionUiRequested") }

        let cancelled = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-main-question-cancelled","protocolVersion":"2026-07-23","timestamp":"2026-05-01T00:00:00.000Z","type":"mainExtensionUiCancelled","requestId":"question-1"}
        """.utf8))
        if case .mainExtensionUiCancelled(let requestId) = cancelled.event {
            #expect(requestId == "question-1")
        } else { Issue.record("Expected mainExtensionUiCancelled") }
    }

    @Test func encodesAnswerMainExtensionUiCommandWithoutSessionId() throws {
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(PickyCommandEnvelope(
            id: "cmd-main-answer",
            type: .answerMainExtensionUi,
            requestId: "question-1",
            value: .object(["choice": .string("yes")])
        ))
        let rawCommand = try #require(String(data: data, encoding: .utf8))
        let command = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(rawCommand.contains("\"sessionId\"") == false)
        #expect(command.type == .answerMainExtensionUi)
        #expect(command.requestId == "question-1")
        #expect(command.sessionId == nil)
        #expect(command.value == .object(["choice": .string("yes")]))
    }

    @Test func malformedEventIsRecoverable() async throws {
        let task = FakeWebSocketTask()
        task.enqueue(contentsOf: [.success(.string(EventJSON.hello())), .success(.string("not-json"))])
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        await client.connect()
        _ = try await nextPickyAgentClientEvent(from: client.events)
        _ = try await nextPickyAgentClientEvent(from: client.events)
        let event = try await nextPickyAgentClientEvent(from: client.events)

        if case .recoverableError(let message)? = event {
            #expect(!message.isEmpty)
        } else { Issue.record("Expected recoverable error") }
    }
}

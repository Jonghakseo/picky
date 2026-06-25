//
//  PickyAgentClientTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakeWebSocketTask: PickyWebSocketTask {
    var sentMessages: [URLSessionWebSocketTask.Message] = []
    var receiveResults: [Result<URLSessionWebSocketTask.Message, Error>] = []
    var didResume = false
    var didCancel = false

    func resume() { didResume = true }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { sentMessages.append(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        while receiveResults.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        return try receiveResults.removeFirst().get()
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { didCancel = true }
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
        {"id":"event-hello","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"hello","serverName":"picky-agentd","supportedProtocolVersions":["2026-05-09"]}
        """
    }
}

struct PickyAgentClientTests {
    @Test func connectsToLocalhostWithTokenAndSendsListSessions() async throws {
        let task = FakeWebSocketTask()
        task.receiveResults = [.success(.string(EventJSON.hello()))]
        let factory = FakeWebSocketFactory(task: task)
        let client = WebSocketPickyAgentClient(
            configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01),
            factory: factory
        )
        var iterator = client.events.makeAsyncIterator()

        await client.connect()
        if case .connected? = await iterator.next() {} else { Issue.record("Expected connected after hello") }
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

        task.receiveResults.append(.success(.string(EventJSON.hello())))
        try await sendTask.value

        #expect(task.sentMessages.count == 1)
    }

    @Test func encodesRewindCommands() throws {
        let encoder = JSONEncoder.pickyAgentProtocolEncoder()

        let listData = try encoder.encode(PickyCommandEnvelope(id: "cmd-rewind-list", type: .listRewindTargets, sessionId: "session-1"))
        let listJSON = try #require(String(data: listData, encoding: .utf8))
        #expect(listJSON.contains("\"type\":\"listRewindTargets\"") || listJSON.contains("\"type\" : \"listRewindTargets\""))
        #expect(listJSON.contains("\"sessionId\":\"session-1\"") || listJSON.contains("\"sessionId\" : \"session-1\""))
        #expect(listJSON.contains("\"protocolVersion\":\"2026-05-09\"") || listJSON.contains("\"protocolVersion\" : \"2026-05-09\""))

        let rewindData = try encoder.encode(PickyCommandEnvelope(id: "cmd-rewind", type: .rewindSession, sessionId: "session-1", entryId: "entry-3"))
        let rewindJSON = try #require(String(data: rewindData, encoding: .utf8))
        #expect(rewindJSON.contains("\"type\":\"rewindSession\"") || rewindJSON.contains("\"type\" : \"rewindSession\""))
        #expect(rewindJSON.contains("\"sessionId\":\"session-1\"") || rewindJSON.contains("\"sessionId\" : \"session-1\""))
        #expect(rewindJSON.contains("\"entryId\":\"entry-3\"") || rewindJSON.contains("\"entryId\" : \"entry-3\""))
    }

    @Test func decodesRewindEvents() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let targets = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-rewind-targets","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:02.000Z","type":"rewindTargetsSnapshot","sessionId":"session-1","requestId":"cmd-rewind-list","targets":[{"entryId":"entry-1","text":"첫 요청","createdAt":"2026-05-01T00:00:00.000Z"},{"entryId":"entry-2","text":"다음 요청","createdAt":null}]}
        """.utf8))
        if case .rewindTargetsSnapshot(let sessionId, let requestId, let rewindTargets) = targets.event {
            #expect(sessionId == "session-1")
            #expect(requestId == "cmd-rewind-list")
            #expect(rewindTargets == [
                PickyRewindTarget(entryId: "entry-1", text: "첫 요청", createdAt: Date(timeIntervalSince1970: 1_777_593_600)),
                PickyRewindTarget(entryId: "entry-2", text: "다음 요청", createdAt: nil)
            ])
        } else { Issue.record("Expected rewindTargetsSnapshot") }

        let rewound = try decoder.decode(PickyEventEnvelope.self, from: Data("""
        {"id":"event-rewound","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:03.000Z","type":"sessionRewound","sessionId":"session-1","editorText":"다시 작성할 요청","removedIds":["message-2","message-3"]}
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
        task.receiveResults = [.success(.string(EventJSON.hello()))]
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        var iterator = client.events.makeAsyncIterator()
        await client.connect()
        if case .connected? = await iterator.next() {} else { Issue.record("Expected connected after hello") }
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
        task.receiveResults = [
            .success(.string(EventJSON.hello())),
            .success(.string("""
            {"id":"event-session","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionUpdated","session":{"id":"session-1","title":"Work","status":"running","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
            """))
        ]
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        let stream = client.events.makeAsyncIterator()
        await client.connect()

        var iterator = stream
        _ = await iterator.next() // connected
        let hello = await iterator.next()
        let session = await iterator.next()

        if case .protocolEvent(let event)? = hello {
            #expect(event.event == .hello(PickyHelloEvent(serverName: "picky-agentd", supportedProtocolVersions: ["2026-05-09"])))
        } else { Issue.record("Expected hello") }

        if case .protocolEvent(let event)? = session,
           case .sessionUpdated(let pickySession) = event.event {
            #expect(pickySession.id == "session-1")
            #expect(pickySession.status == .running)
        } else { Issue.record("Expected sessionUpdated") }
    }

    @Test func malformedEventIsRecoverable() async throws {
        let task = FakeWebSocketTask()
        task.receiveResults = [.success(.string(EventJSON.hello())), .success(.string("not-json"))]
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        var iterator = client.events.makeAsyncIterator()
        await client.connect()
        _ = await iterator.next()
        _ = await iterator.next()
        let event = await iterator.next()

        if case .recoverableError(let message)? = event {
            #expect(!message.isEmpty)
        } else { Issue.record("Expected recoverable error") }
    }
}

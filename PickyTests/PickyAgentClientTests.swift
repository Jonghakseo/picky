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

struct PickyAgentClientTests {
    @Test func connectsToLocalhostWithTokenAndSendsListSessions() async throws {
        let task = FakeWebSocketTask()
        let factory = FakeWebSocketFactory(task: task)
        let client = WebSocketPickyAgentClient(
            configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01),
            factory: factory
        )

        await client.connect()
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

    @Test func receivesHelloAndSessionUpdatedEvents() async throws {
        let task = FakeWebSocketTask()
        task.receiveResults = [
            .success(.string("""
            {"id":"event-hello","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:00.000Z","type":"hello","serverName":"picky-agentd","supportedProtocolVersions":["2026-05-01"]}
            """)),
            .success(.string("""
            {"id":"event-session","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionUpdated","session":{"id":"session-1","title":"Work","status":"running","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
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
            #expect(event.event == .hello(PickyHelloEvent(serverName: "picky-agentd", supportedProtocolVersions: ["2026-05-01"])))
        } else { Issue.record("Expected hello") }

        if case .protocolEvent(let event)? = session,
           case .sessionUpdated(let pickySession) = event.event {
            #expect(pickySession.id == "session-1")
            #expect(pickySession.status == .running)
        } else { Issue.record("Expected sessionUpdated") }
    }

    @Test func malformedEventIsRecoverable() async throws {
        let task = FakeWebSocketTask()
        task.receiveResults = [.success(.string("not-json"))]
        let client = WebSocketPickyAgentClient(configuration: .init(port: 19001, token: "secret", reconnectDelay: 0.01), factory: FakeWebSocketFactory(task: task))
        var iterator = client.events.makeAsyncIterator()
        await client.connect()
        _ = await iterator.next()
        let event = await iterator.next()

        if case .recoverableError(let message)? = event {
            #expect(!message.isEmpty)
        } else { Issue.record("Expected recoverable error") }
    }
}

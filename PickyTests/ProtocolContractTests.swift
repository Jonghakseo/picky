//
//  ProtocolContractTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct ProtocolContractTests {
    @Test func decodesEveryProtocolFixture() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixtures = try fixtureURLs(in: "contracts/protocol")
        #expect(!fixtures.isEmpty)

        for fixture in fixtures {
            let data = try Data(contentsOf: fixture)
            if fixture.lastPathComponent.hasSuffix(".event.json") {
                _ = try decoder.decode(PickyEventEnvelope.self, from: data)
            } else {
                _ = try decoder.decode(PickyCommandEnvelope.self, from: data)
            }
        }
    }

    @Test func ignoresUnknownFutureFields() throws {
        let json = """
        {
          "id":"event-future-001",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"sessionLogAppended",
          "sessionId":"session-001",
          "line":"hello",
          "futureField":{"nested":true}
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .sessionLogAppended(sessionId: "session-001", line: "hello"))
    }

    @Test func preservesUnknownEventTypeForLogging() throws {
        let json = """
        {
          "id":"event-future-002",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"newFutureEvent",
          "details":"kept recoverable"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .unknown(type: "newFutureEvent"))
    }

    @Test func encodesRouteTaskCommandWithContractVersion() throws {
        let context = PickyContextPacket(
            id: "context-test-001",
            source: "text",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "Summarize",
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
        let command = PickyCommandEnvelope(id: "cmd-test-001", type: .routeTask, context: context)
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(decoded.protocolVersion == pickyAgentProtocolVersion)
        #expect(decoded.type == .routeTask)
        #expect(decoded.context?.id == "context-test-001")
    }

    @Test func decodesQuickReplyEvent() throws {
        let json = """
        {
          "id":"event-quick-001",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"quickReply",
          "contextId":"context-1",
          "text":"바로 답변"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .quickReply(PickyQuickReplyEvent(contextId: "context-1", text: "바로 답변")))
    }

    @Test func decodesQuickReplyMetadataEvent() throws {
        let json = """
        {
          "id":"event-quick-002",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"quickReply",
          "contextId":"session-1",
          "text":"완료했어요",
          "originSource":"voiceFollowUp",
          "replyKind":"sideCompletion",
          "sessionId":"session-1"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .quickReply(PickyQuickReplyEvent(
            contextId: "session-1",
            text: "완료했어요",
            originSource: .voiceFollowUp,
            replyKind: .sideCompletion,
            sessionId: "session-1"
        )))
    }

    @Test func decodesInvalidQuickReplyMetadataSafely() throws {
        let json = """
        {
          "id":"event-quick-003",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"quickReply",
          "contextId":"context-1",
          "text":"바로 답변",
          "originSource":"voice-follow-up",
          "replyKind":"side-completion",
          "inputId":"not-a-uuid"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .quickReply(PickyQuickReplyEvent(
            contextId: "context-1",
            text: "바로 답변",
            originSource: .voiceFollowUp,
            replyKind: .sideCompletion,
            inputId: nil
        )))
    }

    @Test func decodesMainAgentMessagesEvents() throws {
        let snapshotJSON = """
        {
          "id":"event-main-messages-001",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"mainMessagesSnapshot",
          "messages":[{"role":"user","text":"안녕","createdAt":"2026-05-01T00:00:00.000Z"}]
        }
        """.data(using: .utf8)!
        let appendedJSON = """
        {
          "id":"event-main-message-001",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-01T00:00:01.000Z",
          "type":"mainMessageAppended",
          "message":{"role":"assistant","text":"바로 답변","createdAt":"2026-05-01T00:00:01.000Z"}
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: snapshotJSON)
        let appended = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: appendedJSON)

        guard case .mainMessagesSnapshot(let messages) = snapshot.event else {
            Issue.record("Expected main messages snapshot")
            return
        }
        guard case .mainMessageAppended(let message) = appended.event else {
            Issue.record("Expected appended main message")
            return
        }
        #expect(messages.first?.role == .user)
        #expect(messages.first?.text == "안녕")
        #expect(message.role == .assistant)
        #expect(message.text == "바로 답변")
    }

    @Test func decodesAskUserQuestionFormEvent() throws {
        let fixture = try #require(try fixtureURLs(in: "contracts/protocol").first { $0.lastPathComponent == "extension-ui-form-request.event.json" })
        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: try Data(contentsOf: fixture))

        guard case .extensionUiRequest(let request) = event.event else {
            Issue.record("Expected extension UI request")
            return
        }
        #expect(request.method == "askUserQuestion")
        #expect(request.title == "메모리 저장 확인")
        #expect(request.description == "저장할 항목과 범위를 선택하세요.")
        #expect(request.questions?.map(\.type) == [.radio, .checkbox, .text])
        #expect(request.questions?.first?.options?.last?.description == "현재 프로젝트에만 적용")
        #expect(request.questions?[1].defaultValue == .array([.string("rule")]))
    }

    @Test func decodesSessionWithoutNewFields() throws {
        let json = """
        {
          "id":"event-legacy-session",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionUpdated",
          "session":{
            "id":"session-legacy",
            "title":"Legacy session",
            "status":"running",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "updatedAt":"2026-05-05T00:00:01.000Z",
            "logs":[],
            "tools":[],
            "artifacts":[],
            "changedFiles":[]
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionUpdated(let session) = envelope.event else {
            Issue.record("Expected sessionUpdated")
            return
        }
        #expect(session.messages.isEmpty)
        #expect(session.queuedSteers.isEmpty)
        #expect(session.queuedFollowUps.isEmpty)
        #expect(session.steeringMode == .oneAtATime)
        #expect(session.followUpMode == .oneAtATime)
        #expect(session.activitySummary == .zero)
        #expect(session.piSessionFilePath == nil)
    }

    @Test func decodesExplicitPiSessionFilePath() throws {
        let json = """
        {
          "id":"event-session-file",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionUpdated",
          "session":{
            "id":"session-with-file",
            "title":"Session with file",
            "status":"running",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "updatedAt":"2026-05-05T00:00:01.000Z",
            "piSessionFilePath":"/tmp/explicit-pi-session.jsonl",
            "logs":[],
            "tools":[],
            "artifacts":[],
            "changedFiles":[]
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionUpdated(let session) = envelope.event else {
            Issue.record("Expected sessionUpdated")
            return
        }
        #expect(session.piSessionFilePath == "/tmp/explicit-pi-session.jsonl")
    }

    @Test func decodesSessionMessageAppendedEvent() throws {
        let json = """
        {
          "id":"event-message-appended",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionMessageAppended",
          "sessionId":"session-001",
          "message":{
            "id":"message-001",
            "kind":"agent_text",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "originatedBy":"main_agent",
            "text":"Done",
            "assistantRun":{"model":"anthropic/claude-opus-4-7","thinkingLevel":"xhigh"}
          },
          "seq":7
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionMessageAppended(let sessionId, let message, let seq) = envelope.event else {
            Issue.record("Expected sessionMessageAppended")
            return
        }
        #expect(sessionId == "session-001")
        #expect(message.id == "message-001")
        #expect(message.kind == .agentText)
        #expect(message.originatedBy == .mainAgent)
        #expect(message.text == "Done")
        #expect(message.assistantRun?.displayText == "opus-4-7 xhigh")
        #expect(seq == 7)
    }

    @Test func decodesAgentActivitySessionMessage() throws {
        let json = """
        {
          "id":"event-activity-message",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionMessageAppended",
          "sessionId":"session-001",
          "message":{
            "id":"message-activity-001",
            "kind":"agent_activity",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "activitySnapshot":{"edit":1,"bash":2,"thinking":3,"other":4}
          },
          "seq":8
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionMessageAppended(_, let message, let seq) = envelope.event else {
            Issue.record("Expected sessionMessageAppended")
            return
        }
        #expect(message.kind == .agentActivity)
        #expect(message.activitySnapshot == PickyActivitySummary(edit: 1, bash: 2, thinking: 3, other: 4))
        #expect(seq == 8)
    }

    @Test func decodesSessionQueueUpdatedWithoutModes() throws {
        let json = """
        {
          "id":"event-queue-updated",
          "protocolVersion":"2026-05-05",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionQueueUpdated",
          "sessionId":"session-001",
          "steering":[{"text":"steer","enqueuedAt":"2026-05-05T00:00:00.000Z"}],
          "followUp":[],
          "seq":8
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionQueueUpdated(let sessionId, let steering, let followUp, let steeringMode, let followUpMode, let seq) = envelope.event else {
            Issue.record("Expected sessionQueueUpdated")
            return
        }
        #expect(sessionId == "session-001")
        #expect(steering.map(\.text) == ["steer"])
        #expect(followUp.isEmpty)
        #expect(steeringMode == nil)
        #expect(followUpMode == nil)
        #expect(seq == 8)
    }

    @Test func encodesClearQueueCommand() throws {
        let command = PickyCommandEnvelope(id: "cmd-clear", type: .clearQueue, sessionId: "session-001", kind: .all)
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(decoded.protocolVersion == pickyAgentProtocolVersion)
        #expect(decoded.type == .clearQueue)
        #expect(decoded.sessionId == "session-001")
        #expect(decoded.kind == .all)
    }
}

func fixtureURLs(in relativeDirectory: String) throws -> [URL] {
    var directory = URL(fileURLWithPath: #filePath)
    while directory.pathComponents.count > 1 {
        directory.deleteLastPathComponent()
        let candidate = directory.appendingPathComponent(relativeDirectory, isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
    return []
}

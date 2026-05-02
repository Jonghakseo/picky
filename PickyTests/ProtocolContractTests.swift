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
          "protocolVersion":"2026-05-01",
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
          "protocolVersion":"2026-05-01",
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
          "protocolVersion":"2026-05-01",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"quickReply",
          "contextId":"context-1",
          "text":"바로 답변"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .quickReply(PickyQuickReplyEvent(contextId: "context-1", text: "바로 답변")))
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

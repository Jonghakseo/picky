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

    @Test func encodesCreateTaskCommandWithContractVersion() throws {
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
        let command = PickyCommandEnvelope(id: "cmd-test-001", type: .createTask, context: context)
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(decoded.protocolVersion == pickyAgentProtocolVersion)
        #expect(decoded.type == .createTask)
        #expect(decoded.context?.id == "context-test-001")
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

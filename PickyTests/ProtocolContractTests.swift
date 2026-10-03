//
//  ProtocolContractTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct ProtocolContractTests {
    @Test func asyncControlWirePreservesRequestAndOwnerApprovalIdentity() throws {
        let urls = try fixtureURLs(in: "contracts/protocol")
        func data(_ name: String) throws -> Data {
            try Data(contentsOf: #require(urls.first { $0.lastPathComponent == name }))
        }
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let contextCommand = try decoder.decode(PickyCommandEnvelope.self, from: data("get-async-control-context.command.json"))
        let envelope = try decoder.decode(PickyCommandEnvelope.self, from: data("async-task-command.command.json"))
        let nested = try #require(envelope.command)
        #expect(envelope.type == .asyncTaskCommand)
        #expect(envelope.id != nested.requestId)
        #expect(try decoder.decode(PickyCommandEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
        let contextEvent = try decoder.decode(PickyEventEnvelope.self, from: data("async-control-context.event.json"))
        guard case .asyncControlContext(let context) = contextEvent.event else { Issue.record("Missing context decoder"); return }
        #expect(context.requestId == contextCommand.id)
        #expect(context.hasCompleteCoverage)
        #expect(context.requiresArchiveChoice == false)
        let resultEvent = try decoder.decode(PickyEventEnvelope.self, from: data("async-task-command-result.event.json"))
        guard case .asyncTaskCommandResult(let result) = resultEvent.event else { Issue.record("Missing nested result decoder"); return }
        #expect(result.requestId == nested.requestId)
        #expect(result.operationId != result.requestId)
        #expect(result.releaseApproval == context.releasePrepared)
        #expect(result.workRevision == result.releaseApproval?.workRevision)
        #expect(result.workRevision > nested.workRevision)
        #expect(result.controlGeneration == result.releaseApproval?.controlGeneration)
    }

    @Test(arguments: ["prepare", "execute"])
    func quiescentArchiveCommandsRoundTrip(requirement: String) throws {
        let urls = try fixtureURLs(in: "contracts/protocol")
        let url = try #require(urls.first { $0.lastPathComponent == "async-task-archive-\(requirement)-quiescent.command.json" })
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let envelope = try decoder.decode(PickyCommandEnvelope.self, from: Data(contentsOf: url))
        #expect(envelope.command?.requireQuiescence == true)
        #expect(try decoder.decode(PickyCommandEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
        var legacy = envelope
        legacy.command?.requireQuiescence = nil
        let encoded = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((object["command"] as? [String: Any])?["requireQuiescence"] == nil)
        #expect(try decoder.decode(PickyCommandEnvelope.self, from: encoded).command?.requireQuiescence == nil)
        var explicit = envelope
        explicit.command?.requireQuiescence = false
        #expect(try decoder.decode(PickyCommandEnvelope.self, from: JSONEncoder().encode(explicit)) == explicit)
    }

    @Test func exposesCurrentProtocolVersion() {
        #expect(pickyAgentProtocolVersion == "2026-08-25")
    }

    @Test func decodesStructuredQuestionHistoryAndLegacyResults() throws {
        let url = try #require(try fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "tool-history-detail-result.event.json"
        })
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let result = try decoder.decode(PickyToolHistoryDetailResult.self, from: data)
        let structured = try #require(result.structuredResult)
        let answer = try #require(JSONSerialization.jsonObject(with: Data(structured.utf8)) as? [String: Any])
        let value = try #require(answer["value"] as? [String: Any])
        #expect(value["choices"] as? [String] == ["first, second", "third"])
        #expect(value["notes"] as? String == "line one\nline two | exact")
        #expect(answer["cancelled"] as? Bool == false)

        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "structuredResult")
        let legacyResult = try decoder.decode(PickyToolHistoryDetailResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(legacyResult.structuredResult == nil)
        #expect(legacyResult.text == result.text)
    }

    @Test func decodesJSONToolResultMetadataAndLegacyPayloads() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixture = try #require(try fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-projection-tool-json-result.event.json"
        })
        let envelope = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: fixture))
        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .toolUpsert(let tool) = transaction.mutations.first else {
            Issue.record("Expected a toolUpsert projection mutation")
            return
        }
        #expect(tool.preview == #"{"items":[..."#)
        #expect(tool.resultPreview == #"{"items":[..."#)
        #expect(tool.resultJSONPreview == #"{"items":[]}"#)
        #expect(tool.resultPreviewTruncated == true)
        #expect(tool.resultPreviewRepaired == true)

        let legacy = #"{"toolCallId":"legacy","name":"read","status":"succeeded","resultPreview":"plain"}"#
        let legacyTool = try decoder.decode(PickyToolActivity.self, from: Data(legacy.utf8))
        #expect(legacyTool.resultJSONPreview == nil)
        #expect(legacyTool.resultPreviewTruncated == nil)
        #expect(legacyTool.resultPreviewRepaired == nil)
    }

    @Test func decodesExtensionCustomTypeOnSystemMessages() throws {
        let url = try #require(try fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-projection-message-custom-type.event.json"
        })
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder()
            .decode(PickyEventEnvelope.self, from: Data(contentsOf: url))

        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .messageAppend(let message) = transaction.mutations.first else {
            Issue.record("Expected a messageAppend projection mutation")
            return
        }
        #expect(message.customType == "bash-async-completion")

        let untagged = #"{"id":"m","kind":"system","createdAt":"2026-05-05T00:00:00.000Z","text":"plain"}"#
        let legacy = try JSONDecoder.pickyAgentProtocolDecoder()
            .decode(PickySessionMessage.self, from: Data(untagged.utf8))
        #expect(legacy.customType == nil)
    }

    @Test func decodesPickyAuthoredMessagePresentationFromFixture() throws {
        let url = try #require(try fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-projection-message-presentation.event.json"
        })
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder()
            .decode(PickyEventEnvelope.self, from: Data(contentsOf: url))

        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .messageAppend(let message) = transaction.mutations.first else {
            Issue.record("Expected a messageAppend projection mutation")
            return
        }
        #expect(message.presentation?.code == .sessionCompactionFailed)
        #expect(message.presentation?.params?.detail == "Summarization request timed out.")
        #expect(message.presentation?.params?.contextTokens == 190_000)
        #expect(message.presentation?.params?.contextWindowTokens == 200_000)
        // The English wording stays on the message for the CLI and for clients that do not
        // know the code.
        #expect(message.text?.hasPrefix("Auto-compaction failed") == true)

        let untagged = #"{"id":"m","kind":"system","createdAt":"2026-05-05T00:00:00.000Z","text":"plain"}"#
        let legacy = try JSONDecoder.pickyAgentProtocolDecoder()
            .decode(PickySessionMessage.self, from: Data(untagged.utf8))
        #expect(legacy.presentation == nil)
    }

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

    @Test func decodesLegacyHubStatisticsSnapshotWithClassificationDisabled() throws {
        let json = Data("""
        {
          "id":"event-hub-statistics-legacy",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-09-01T00:00:00.000Z",
          "type":"hubStatisticsResult",
          "commandId":"cmd-hub-statistics",
          "ok":true,
          "snapshot":{"generatedAt":"2026-09-01T00:00:00.000Z","records":[],"usageSamples":[],"pendingClassificationCount":0}
        }
        """.utf8)
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)

        guard case .hubStatisticsResult(let result) = envelope.event else {
            Issue.record("Expected hubStatisticsResult event")
            return
        }
        #expect(result.snapshot?.classificationEnabled == false)
    }

    @Test func decodesArtifactWithRawBacktickURL() throws {
        let json = """
        {
          "id":"artifact-preview",
          "kind":"link",
          "title":"Preview",
          "url":"https://pull-request-web-4483.preview.creatrip.com`/`",
          "updatedAt":"2026-05-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let artifact = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyArtifact.self, from: json)

        #expect(artifact.id == "artifact-preview")
    }

    @Test func keepsProjectionSnapshotsWithArtifactsContainingRawBacktickURLs() throws {
        let json = """
        {
          "id":"event-projection-backtick-url",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-01T00:00:01.000Z",
          "type":"sessionProjectionSnapshot",
          "sessionId":"session-backtick-url",
          "epoch":"epoch-001",
          "revision":3,
          "complete":true,
          "omittedFields":[],
          "projection":{
            "id":"session-backtick-url",
            "title":"Session with preview link",
            "status":"completed",
            "cwd":"/tmp/backtick",
            "createdAt":"2026-05-01T00:00:00.000Z",
            "updatedAt":"2026-05-01T00:00:01.000Z",
            "logs":[],
            "tools":[],
            "artifacts":[{
              "id":"artifact-preview",
              "kind":"link",
              "title":"Preview",
              "url":"https://pull-request-web-4483.preview.creatrip.com`/`",
              "updatedAt":"2026-05-01T00:00:00.000Z"
            }],
            "changedFiles":[]
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)

        guard case .sessionProjectionSnapshot(let snapshot) = envelope.event else {
            Issue.record("Expected sessionProjectionSnapshot")
            return
        }
        #expect(snapshot.sessionId == "session-backtick-url")
        #expect(snapshot.projection.artifacts.count == 1)
        #expect(snapshot.projection.artifacts.first?.id == "artifact-preview")
    }

    @Test func dropsProjectionSnapshotsWhoseSessionCannotDecode() throws {
        let json = """
        {
          "id":"event-projection-undecodable",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-01T00:00:01.000Z",
          "type":"sessionProjectionSnapshot",
          "sessionId":"session-b",
          "epoch":"epoch-001",
          "revision":1,
          "complete":true,
          "omittedFields":[],
          "projection":{"id":"session-b","title":"B","status":42,"createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        // One poisoned record is isolated to its own session frame instead of
        // blanking the dock, so the app simply ignores the unknown event.
        #expect(envelope.event == .unknown(type: "sessionProjectionSnapshot"))
    }

    @Test func ignoresUnknownFutureFields() throws {
        let json = """
        {
          "id":"event-future-001",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-001",
          "epoch":"epoch-001",
          "baseRevision":0,
          "revision":1,
          "mutations":[{"type":"logAppend","line":"hello"}],
          "futureField":{"nested":true}
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionProjectionTransaction(let transaction) = event.event else {
            Issue.record("Expected sessionProjectionTransaction")
            return
        }
        #expect(transaction.sessionId == "session-001")
        #expect(transaction.mutations == [.logAppend(line: "hello")])
    }

    @Test func decodesSessionReplyWritingUpdatedEvent() throws {
        let json = { (writing: String) in
            """
            {
              "id":"event-reply-writing",
              "protocolVersion":"2026-07-23",
              "timestamp":"2026-05-01T00:00:00.000Z",
              "type":"sessionReplyWritingUpdated",
              "sessionId":"session-001",
              "writing":\(writing)
            }
            """.data(using: .utf8)!
        }
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        #expect(try decoder.decode(PickyEventEnvelope.self, from: json("true")).event
            == .sessionReplyWritingUpdated(sessionId: "session-001", writing: true))
        #expect(try decoder.decode(PickyEventEnvelope.self, from: json("false")).event
            == .sessionReplyWritingUpdated(sessionId: "session-001", writing: false))
    }

    @Test func decodesSessionToolCallPreparingUpdatedEvent() throws {
        let json = """
        {
          "id":"event-tool-call-preparing",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"sessionToolCallPreparingUpdated",
          "sessionId":"session-001",
          "preparing":true
        }
        """.data(using: .utf8)!

        #expect(try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json).event
            == .sessionToolCallPreparingUpdated(sessionId: "session-001", preparing: true))
    }

    @Test func preservesUnknownEventTypeForLogging() throws {
        let json = """
        {
          "id":"event-future-002",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"newFutureEvent",
          "details":"kept recoverable"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .unknown(type: "newFutureEvent"))
    }

    @Test func decodesExternalEntryAcceptedEvent() throws {
        let json = """
        {
          "id":"event-external-accepted-001",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"externalEntryAccepted",
          "commandId":"cli-1",
          "kind":"createPickle",
          "contextId":"context-cli-1",
          "sessionId":"session-cli-1"
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(envelope.event == .externalEntryAccepted(PickyExternalEntryAcceptedEvent(
            commandId: "cli-1",
            kind: .createPickle,
            contextId: "context-cli-1",
            sessionId: "session-cli-1",
            group: nil
        )))
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

    @Test func decodesDurableCompletionEnvelopeAndLegacyCompletionCommand() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixture = try #require(try fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "notify-main-of-pickle-completion.command.json"
        })
        let durable = try decoder.decode(PickyCommandEnvelope.self, from: Data(contentsOf: fixture))
        let legacy = try decoder.decode(PickyCommandEnvelope.self, from: Data(#"{"id":"cmd-legacy","protocolVersion":"2026-08-25","type":"notifyMainOfPickleCompletion","sessionId":"session-legacy","prompt":"done"}"#.utf8))

        #expect(durable.completionId == "session-001:8")
        #expect(durable.title == "Investigate notification routing")
        #expect(durable.status == .completed)
        #expect(durable.summary == "Notification routing is complete.")
        #expect(durable.notifyMainOnCompletion == true)
        #expect(durable.notifyMacOSOnCompletion == true)
        #expect(legacy.completionId == nil)
        #expect(legacy.status == nil)
    }

    @Test func normalizesLegacyCompletionBridgeUsingProjectedSessionMetadata() throws {
        let request = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyPickleBridgeRequest.self,
            from: Data(#"{"requestId":"legacy-bridge-42","operation":"notifyMainOfPickleCompletion","sessionId":"session-legacy","prompt":"done"}"#.utf8)
        )
        let projected = PickyAgentSession(
            id: "session-legacy",
            title: "Projected Pickle",
            status: PickySessionStatus.completed,
            cwd: "/tmp/project",
            createdAt: Date(),
            updatedAt: Date(),
            lastSummary: "Projected summary",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            notifyMainOnCompletion: true
        )

        let envelope = try #require(request.completionEnvelope(projectedSession: projected))
        #expect(envelope.completionId == "legacy:legacy-bridge-42")
        #expect(envelope.title == "Projected Pickle")
        #expect(envelope.summary == "Projected summary")
        #expect(envelope.notifyMainOnCompletion)
        #expect(envelope.notifyMacOSOnCompletion == false)
        #expect(envelope.status == .completed)
    }

    @Test func normalizesLegacyCompletionBridgeWithoutProjectionAsMainOnly() throws {
        let request = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyPickleBridgeRequest.self,
            from: Data(#"{"requestId":"legacy-missing-projection","operation":"notifyMainOfPickleCompletion","sessionId":"session-legacy","prompt":"done"}"#.utf8)
        )

        let envelope = try #require(request.completionEnvelope(projectedSession: nil))
        #expect(envelope.completionId == "legacy:legacy-missing-projection")
        #expect(envelope.title == "session-legacy")
        #expect(envelope.notifyMainOnCompletion)
        #expect(envelope.notifyMacOSOnCompletion == false)
    }

    @Test func encodesSetupPackageCommand() throws {
        let command = PickyCommandEnvelope(
            id: "cmd-package-setup",
            type: .setupPackage,
            source: "npm:@ryan_nookpi/pi-extension-cron"
        )

        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyCommandEnvelope.self,
            from: JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        )

        #expect(decoded.type == .setupPackage)
        #expect(decoded.source == "npm:@ryan_nookpi/pi-extension-cron")
    }

    @Test func decodesSetupCompletionAndLegacyPackageCompletion() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let setupJSON = Data(#"{"id":"event-package-setup","protocolVersion":"2026-08-25","timestamp":"2026-08-25T00:00:00.000Z","type":"packageOperationCompleted","requestId":"cmd-package-setup","operation":"setup","source":"npm:@ryan_nookpi/pi-extension-cron","ok":false,"errorMessage":"LaunchAgent did not load","packageChanged":false}"#.utf8)
        let legacyJSON = Data(#"{"id":"event-package-install","protocolVersion":"2026-08-25","timestamp":"2026-08-25T00:00:00.000Z","type":"packageOperationCompleted","requestId":"cmd-package-install","operation":"install","source":"npm:@example/plugin","ok":true}"#.utf8)

        let setup = try decoder.decode(PickyEventEnvelope.self, from: setupJSON)
        let legacy = try decoder.decode(PickyEventEnvelope.self, from: legacyJSON)

        guard case .packageOperationCompleted(let setupResult) = setup.event,
              case .packageOperationCompleted(let legacyResult) = legacy.event else {
            Issue.record("Expected package completion events")
            return
        }
        #expect(setupResult.operation == .setup)
        #expect(setupResult.packageChanged == false)
        #expect(legacyResult.packageChanged == nil)
    }

    @Test func encodesArmedPickleVisualDslCapability() throws {
        let context = PickyContextPacket(
            id: "context-armed-pickle",
            source: "text-follow-up",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "show this",
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
        let command = PickyCommandEnvelope(
            id: "cmd-armed-pickle",
            type: .followUp,
            context: context,
            sessionId: "pickle-1",
            text: "show this",
            visualDslEnabled: true
        )
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(decoded.visualDslEnabled == true)
        #expect(decoded.context?.id == "context-armed-pickle")
    }

    @Test func encodesAutocompleteQueryAndApplyCommandsWithUTF16CursorMetadata() throws {
        let query = PickyCommandEnvelope(
            id: "cmd-autocomplete-query",
            type: .autocompleteQuery,
            sessionId: "session-1",
            generation: 3,
            lines: [">w"],
            cursorLine: 0,
            cursorCol: 2,
            draftRevision: 4,
            draftFingerprint: "draft-4"
        )
        let apply = PickyCommandEnvelope(
            id: "cmd-autocomplete-apply",
            type: .autocompleteApply,
            sessionId: "session-1",
            generation: 3,
            lines: [">w"],
            cursorLine: 0,
            cursorCol: 2,
            draftRevision: 4,
            draftFingerprint: "draft-4",
            item: PickyAutocompleteItem(value: ">worker", label: ">worker"),
            prefix: ">w"
        )
        let encoder = JSONEncoder.pickyAgentProtocolEncoder()
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        let decodedQuery = try decoder.decode(PickyCommandEnvelope.self, from: encoder.encode(query))
        let decodedApply = try decoder.decode(PickyCommandEnvelope.self, from: encoder.encode(apply))

        #expect(decodedQuery.cursorCol == 2)
        #expect(decodedQuery.draftFingerprint == "draft-4")
        #expect(decodedApply.item == PickyAutocompleteItem(value: ">worker", label: ">worker"))
        #expect(decodedApply.prefix == ">w")
    }

    @Test func decodesAutocompleteSnapshots() throws {
        let data = try Data(contentsOf: try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "autocomplete-suggestions.event.json"
        }))
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: data)

        guard case .autocompleteSuggestionsSnapshot(let snapshot) = envelope.event else {
            Issue.record("Expected autocompleteSuggestionsSnapshot")
            return
        }
        #expect(snapshot.generation == 3)
        #expect(snapshot.prefix == ">w")
        #expect(snapshot.items == [PickyAutocompleteItem(
            value: ">worker",
            label: ">worker",
            description: "Delegate to worker"
        )])
    }

    @Test func decodesMainTurnSettledFixtureWithContextID() throws {
        let fixture = try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "main-turn-settled.event.json"
        })

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(contentsOf: fixture))

        guard case .mainTurnSettled(let contextID) = envelope.event else {
            Issue.record("Expected mainTurnSettled event")
            return
        }
        #expect(contextID == "context-overlay-only-001")
    }

    @Test func encodesAndDecodesPickleCommand() throws {
        let command = PickyCommandEnvelope(id: "cmd-pickle", type: .createEmptyPickleSession)
        let data = try JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        let encoded = String(data: data, encoding: .utf8)
        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: data)

        #expect(encoded?.contains("\"type\":\"createEmptyPickleSession\"") == true)
        #expect(decoded.type == .createEmptyPickleSession)
        #expect(decoded.notifyMainOnCompletion == nil)

        let enabled = PickyCommandEnvelope(
            id: "cmd-handoff",
            type: .createPickleFromHandoff,
            context: PickyContextPacket(id: "context-handoff", source: "system", capturedAt: Date(), transcript: nil, selectedText: nil, cwd: nil, activeApp: nil, activeWindow: nil, browser: nil, screenshots: [], warnings: []),
            title: "Handoff",
            instructions: "Continue",
            notifyMainOnCompletion: true,
            notifyMacOSOnCompletion: true
        )
        let enabledData = try JSONEncoder.pickyAgentProtocolEncoder().encode(enabled)
        let enabledDecoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: enabledData)
        #expect(enabledDecoded.notifyMainOnCompletion == true)
        #expect(enabledDecoded.notifyMacOSOnCompletion == true)
    }

    @Test func decodesPayloadBackedSessionEvents() throws {
        let queueJSON = """
        {
          "id":"event-queue",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-07-19T00:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-queue",
          "epoch":"epoch-001",
          "baseRevision":6,
          "revision":7,
          "mutations":[{
            "type":"queueSet",
            "queuedSteers":[{"id":"steer-1","text":"slow down","enqueuedAt":"2026-07-19T00:00:00.000Z"}],
            "queuedFollowUps":[{"id":"follow-1","text":"then report","enqueuedAt":"2026-07-19T00:00:01.000Z"}],
            "scheduledMessages":[],
            "steeringMode":"one-at-a-time",
            "followUpMode":"all"
          }]
        }
        """.data(using: .utf8)!
        let terminalJSON = """
        {
          "id":"event-terminal-sync",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-07-19T00:00:00.000Z",
          "type":"terminalSessionSyncOutcome",
          "sessionId":"session-terminal",
          "baselineFound":true,
          "importedMessageCount":2,
          "activeLastMessageId":"message-last",
          "baselinePiMessageId":"pi-baseline"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let queue = try decoder.decode(PickyEventEnvelope.self, from: queueJSON)
        let terminal = try decoder.decode(PickyEventEnvelope.self, from: terminalJSON)

        if case .sessionProjectionTransaction(let transaction) = queue.event,
           case .queueSet(let steering, let followUp, _, let steeringMode, let followUpMode) = transaction.mutations.first {
            #expect(transaction.sessionId == "session-queue")
            #expect(steering.map(\.text) == ["slow down"])
            #expect(followUp.map(\.text) == ["then report"])
            #expect(steeringMode == .oneAtATime)
            #expect(followUpMode == .all)
            #expect(transaction.revision == 7)
        } else {
            Issue.record("Expected a queueSet projection mutation")
        }
        #expect(terminal.event == .terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome(
            sessionId: "session-terminal",
            baselineFound: true,
            importedMessageCount: 2,
            activeLastMessageId: "message-last",
            baselinePiMessageId: "pi-baseline"
        )))
    }

    @Test func decodesTodoStateFromProjectionFixture() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixture = try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-projection-todo-set.event.json"
        })

        let envelope = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: fixture))

        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .todoSet(let decodedTodoState) = transaction.mutations.first else {
            Issue.record("Expected a todoSet projection mutation")
            return
        }
        let todoState = try #require(decodedTodoState)
        #expect(todoState.completedCount == 1)
        #expect(todoState.tasks.count == 2)
        #expect(todoState.tasks[1].status == .inProgress)
        #expect(todoState.tasks[1].activeForm == "Implementing HUD projection")
        #expect(todoState.tasks[1].notes == "Keep the overlay read-only")
    }

    @Test func decodesSlimTodoStateUpdatesIncludingClear() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let updateJSON = """
        {
          "id":"event-session-todo-update",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-07-14T01:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-001",
          "epoch":"epoch-001",
          "baseRevision":8,
          "revision":9,
          "mutations":[{"type":"todoSet","todoState":{"tasks":[{"id":"todo-1","content":"Implement HUD","status":"in_progress","activeForm":"Implementing HUD"}],"updatedAt":"2026-07-14T01:00:00.000Z"}}]
        }
        """.data(using: .utf8)!
        let clearJSON = """
        {
          "id":"event-session-todo-clear",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-07-14T01:01:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-001",
          "epoch":"epoch-001",
          "baseRevision":9,
          "revision":10,
          "mutations":[{"type":"todoSet","todoState":null}]
        }
        """.data(using: .utf8)!

        let update = try decoder.decode(PickyEventEnvelope.self, from: updateJSON)
        let clear = try decoder.decode(PickyEventEnvelope.self, from: clearJSON)

        guard case .sessionProjectionTransaction(let updateTransaction) = update.event,
              case .todoSet(let todoState) = updateTransaction.mutations.first else {
            Issue.record("Expected a todoSet projection mutation")
            return
        }
        #expect(updateTransaction.sessionId == "session-001")
        #expect(todoState?.tasks.first?.activeForm == "Implementing HUD")
        #expect(updateTransaction.revision == 9)

        guard case .sessionProjectionTransaction(let clearTransaction) = clear.event else {
            Issue.record("Expected sessionProjectionTransaction")
            return
        }
        #expect(clearTransaction.mutations == [.todoSet(nil)])
        #expect(clearTransaction.revision == 10)
    }

    @Test func decodesQuickReplyEvent() throws {
        let json = """
        {
          "id":"event-quick-001",
          "protocolVersion":"2026-07-23",
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
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"quickReply",
          "contextId":"session-1",
          "text":"완료했어요",
          "originSource":"voiceFollowUp",
          "replyKind":"pickleCompletion",
          "sessionId":"session-1"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .quickReply(PickyQuickReplyEvent(
            contextId: "session-1",
            text: "완료했어요",
            originSource: .voiceFollowUp,
            replyKind: .pickleCompletion,
            sessionId: "session-1"
        )))
    }

    @Test func decodesInvalidQuickReplyMetadataSafely() throws {
        let json = """
        {
          "id":"event-quick-003",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"quickReply",
          "contextId":"context-1",
          "text":"바로 답변",
          "originSource":"voice-follow-up",
          "replyKind":"pickle-completion",
          "inputId":"not-a-uuid"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        #expect(event.event == .quickReply(PickyQuickReplyEvent(
            contextId: "context-1",
            text: "바로 답변",
            originSource: .voiceFollowUp,
            replyKind: .pickleCompletion,
            inputId: nil
        )))
    }

    @Test func decodesProgressiveVisualNarrationSegmentFixtures() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixtures = try fixtureURLs(in: "contracts/protocol")
        let preparedURL = try #require(fixtures.first { $0.lastPathComponent == "main-visual-narration-segment-prepared.event.json" })
        let sentenceURL = try #require(fixtures.first { $0.lastPathComponent == "main-visual-narration-segment-sentence.event.json" })
        let committedURL = try #require(fixtures.first { $0.lastPathComponent == "main-visual-narration-segment-committed.event.json" })

        let prepared = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: preparedURL))
        let sentence = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: sentenceURL))
        let committed = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: committedURL))

        guard case .mainVisualNarrationSegmentPrepared(let preparedEvent) = prepared.event else {
            Issue.record("Expected prepared visual narration segment")
            return
        }
        #expect(preparedEvent.identity.contextId == "context-visual-001")
        #expect(preparedEvent.identity.contextGeneration == 3)
        #expect(preparedEvent.identity.turnToken == "main-turn-7")
        #expect(preparedEvent.identity.segmentId == "segment-001")
        #expect(preparedEvent.identity.ordinal == 0)
        guard case .annotations(let request) = preparedEvent.visual else {
            Issue.record("Expected prepared annotation visual")
            return
        }
        #expect(request.annotations.first?.label == "첫 영역")

        #expect(sentence.event == .mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: preparedEvent.identity,
                index: 0,
                text: "첫 문장입니다.",
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
        #expect(committed.event == .mainVisualNarrationSegmentCommitted(
            PickyVisualNarrationSegmentCommittedEvent(
                identity: preparedEvent.identity,
                text: "첫 문장입니다. 둘째 문장입니다.",
                sentenceCount: 2,
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
    }

    @Test func decodesMainAgentMessagesEvents() throws {
        let snapshotJSON = """
        {
          "id":"event-main-messages-001",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:00.000Z",
          "type":"mainMessagesSnapshot",
          "messages":[{"role":"user","text":"안녕","createdAt":"2026-05-01T00:00:00.000Z"}]
        }
        """.data(using: .utf8)!
        let appendedJSON = """
        {
          "id":"event-main-message-001",
          "protocolVersion":"2026-07-23",
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

    @Test func decodesNotifySessionMessageSeverity() throws {
        let json = """
        {
          "id":"event-notify-message",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-1",
          "epoch":"epoch-001",
          "baseRevision":2,
          "revision":3,
          "mutations":[{"type":"messageAppend","message":{
            "id":"notify-1",
            "kind":"system",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "text":"Extension warning",
            "notifyType":"warning"
          }}]
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionProjectionTransaction(let transaction) = event.event,
              case .messageAppend(let message) = transaction.mutations.first else {
            Issue.record("Expected a messageAppend projection mutation")
            return
        }
        #expect(message.notifyType == .warning)
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

    @Test func ignoresRetiredPointerRadiusField() throws {
        let legacy = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyEventEnvelope.self,
            from: pointerOverlayEventData(extraRequestField: #""r":24,"#)
        )
        let current = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyEventEnvelope.self,
            from: pointerOverlayEventData()
        )

        #expect(legacy == current)
    }

    @Test func treatsOmittedAndFalseAnnotationSpotlightAsEquivalentVisualDefaults() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let omitted = try annotationOverlayRequest(
            from: decoder,
            annotation: #"{"id":"annotation-1","shape":"rect","x":10,"y":20,"w":30,"h":40}"#
        )
        let explicitFalse = try annotationOverlayRequest(
            from: decoder,
            annotation: #"{"id":"annotation-1","shape":"rect","x":10,"y":20,"w":30,"h":40,"spotlight":false}"#
        )
        let omittedAnnotation = try #require(omitted.annotations.first)
        let explicitFalseAnnotation = try #require(explicitFalse.annotations.first)

        #expect(omittedAnnotation.spotlight == nil)
        #expect(explicitFalseAnnotation.spotlight == false)
        #expect((omittedAnnotation.spotlight ?? false) == (explicitFalseAnnotation.spotlight ?? false))
    }

    @Test func decodesStructuredPATHCommands() throws {
        let request = try annotationOverlayRequest(
            from: JSONDecoder.pickyAgentProtocolDecoder(),
            annotation: #"{"id":"annotation-path","shape":"path","commands":[{"type":"move","x":10,"y":20},{"type":"cubic","c1x":30,"c1y":40,"c2x":50,"c2y":60,"x":70,"y":80}],"label":"Trend"}"#
        )
        let annotation = try #require(request.annotations.first)

        #expect(annotation.shape == .path)
        #expect(annotation.commands == [
            PickyAnnotationPathCommand(type: .move, x: 10, y: 20),
            PickyAnnotationPathCommand(type: .cubic, x: 70, y: 80, c1x: 30, c1y: 40, c2x: 50, c2y: 60),
        ])
        #expect(annotation.label == "Trend")
    }

    @Test func ignoresRetiredAnnotationTTLField() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let legacy = try annotationOverlayRequest(
            from: decoder,
            annotation: #"{"id":"annotation-1","shape":"rect","x":10,"y":20,"w":30,"h":40,"ttlMs":5000}"#
        )
        let current = try annotationOverlayRequest(
            from: decoder,
            annotation: #"{"id":"annotation-1","shape":"rect","x":10,"y":20,"w":30,"h":40}"#
        )

        #expect(legacy == current)
    }

    @Test func rejectsRetiredAnnotationCircleAndTargetShapes() {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        for shape in ["circle", "target"] {
            #expect(throws: DecodingError.self) {
                _ = try decoder.decode(
                    PickyEventEnvelope.self,
                    from: annotationOverlayEventData(annotation: "{\"id\":\"annotation-\\(shape)\",\"shape\":\"\\(shape)\"}")
                )
            }
        }
    }

    @Test func decodesSessionWithoutNewFields() throws {
        let json = """
        {
          "id":"event-legacy-session",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionProjectionSnapshot",
          "sessionId":"session-legacy",
          "epoch":"epoch-001",
          "revision":1,
          "complete":true,
          "omittedFields":[],
          "projection":{
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
        guard case .sessionProjectionSnapshot(let snapshot) = envelope.event else {
            Issue.record("Expected sessionProjectionSnapshot")
            return
        }
        let session = snapshot.projection
        #expect(session.messages.isEmpty)
        #expect(session.queuedSteers.isEmpty)
        #expect(session.queuedFollowUps.isEmpty)
        #expect(session.steeringMode == .oneAtATime)
        #expect(session.followUpMode == .oneAtATime)
        #expect(session.activitySummary == .zero)
        #expect(session.todoState == nil)
        #expect(session.piSessionFilePath == nil)
    }

    @Test func decodesExplicitPiSessionFilePath() throws {
        let json = """
        {
          "id":"event-session-file",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionProjectionSnapshot",
          "sessionId":"session-with-file",
          "epoch":"epoch-001",
          "revision":1,
          "complete":true,
          "omittedFields":[],
          "projection":{
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
        guard case .sessionProjectionSnapshot(let snapshot) = envelope.event else {
            Issue.record("Expected sessionProjectionSnapshot")
            return
        }
        #expect(snapshot.projection.piSessionFilePath == "/tmp/explicit-pi-session.jsonl")
    }

    @Test func decodesSessionMessageAppendedEvent() throws {
        let json = """
        {
          "id":"event-message-appended",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-001",
          "epoch":"epoch-001",
          "baseRevision":6,
          "revision":7,
          "mutations":[{"type":"messageAppend","message":{
            "id":"message-001",
            "kind":"agent_text",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "originatedBy":"main_agent",
            "text":"Done",
            "assistantRun":{"model":"openai-codex/gpt-5.6","thinkingLevel":"max"}
          }}]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .messageAppend(let message) = transaction.mutations.first else {
            Issue.record("Expected a messageAppend projection mutation")
            return
        }
        let seq = transaction.revision
        #expect(transaction.sessionId == "session-001")
        #expect(message.id == "message-001")
        #expect(message.kind == .agentText)
        #expect(message.originatedBy == .mainAgent)
        #expect(message.text == "Done")
        #expect(message.assistantRun?.displayText == "gpt-5.6 max")
        #expect(seq == 7)
    }

    @Test func decodesLegacyActivitySummaryWithoutTodoOrSubagentCounts() throws {
        let legacy = try JSONDecoder().decode(
            PickyActivitySummary.self,
            from: Data(#"{"read":1,"bash":2,"edit":3,"write":4,"thinking":5,"other":6}"#.utf8)
        )

        #expect(legacy == PickyActivitySummary(
            edit: 3,
            bash: 2,
            thinking: 5,
            other: 6,
            read: 1,
            write: 4
        ))
        #expect(legacy.todo == 0)
        #expect(legacy.subagent == 0)
    }

    @Test func decodesAgentActivitySessionMessage() throws {
        let json = """
        {
          "id":"event-activity-message",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-001",
          "epoch":"epoch-001",
          "baseRevision":7,
          "revision":8,
          "mutations":[{"type":"messageAppend","message":{
            "id":"message-activity-001",
            "kind":"agent_activity",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "activitySnapshot":{"edit":1,"bash":2,"thinking":3,"other":4,"todo":5,"subagent":6}
          }}]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .messageAppend(let message) = transaction.mutations.first else {
            Issue.record("Expected a messageAppend projection mutation")
            return
        }
        let seq = transaction.revision
        #expect(message.kind == .agentActivity)
        #expect(message.activitySnapshot == PickyActivitySummary(
            edit: 1,
            bash: 2,
            thinking: 3,
            other: 4,
            todo: 5,
            subagent: 6
        ))
        #expect(seq == 8)
    }

    @Test func decodesQueueMutationWithoutScheduledMessages() throws {
        let json = """
        {
          "id":"event-queue-updated",
          "protocolVersion":"2026-08-25",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionProjectionTransaction",
          "sessionId":"session-001",
          "epoch":"epoch-001",
          "baseRevision":7,
          "revision":8,
          "mutations":[{
            "type":"queueSet",
            "queuedSteers":[{"text":"steer","enqueuedAt":"2026-05-05T00:00:00.000Z"}],
            "queuedFollowUps":[],
            "steeringMode":"one-at-a-time",
            "followUpMode":"one-at-a-time"
          }]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .queueSet(let steering, let followUp, let scheduled, let steeringMode, let followUpMode) = transaction.mutations.first else {
            Issue.record("Expected a queueSet projection mutation")
            return
        }
        #expect(transaction.sessionId == "session-001")
        #expect(steering.map(\.text) == ["steer"])
        #expect(steering.first?.attachedImagesCount == nil)
        #expect(followUp.isEmpty)
        #expect(steeringMode == .oneAtATime)
        #expect(followUpMode == .oneAtATime)
        // A daemon without delayed-action projection omits the field entirely.
        #expect(scheduled.isEmpty)
        #expect(transaction.revision == 8)
    }

    @Test func decodesQueuedDisplayTextAndAttachedImageCountFromFixture() throws {
        let fixture = try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-projection-transaction.event.json"
        })
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyEventEnvelope.self,
            from: Data(contentsOf: fixture)
        )

        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .queueSet(let steering, let followUp, _, _, _) = transaction.mutations.first(where: { if case .queueSet = $0 { return true } else { return false } }) else {
            Issue.record("Expected a queueSet projection mutation")
            return
        }
        #expect(steering.map(\.attachedImagesCount) == [2])
        #expect(followUp.map(\.attachedImagesCount) == [nil])
        // The envelope stays in `text` for runtime matching while the app shows the
        // instruction agentd resolved; an entry without `displayText` falls back to `text`.
        #expect(steering.map(\.userFacingText) == ["Prioritize tests"])
        #expect(steering.first?.text.hasPrefix("# Picky steering message") == true)
        #expect(followUp.map(\.displayText) == [nil])
        #expect(followUp.map(\.userFacingText) == ["Summarize after completion"])
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

    @Test func encodesProjectionSnapshotRecoveryCommand() throws {
        let command = PickyCommandEnvelope(
            id: "cmd-projection-recovery",
            type: .getSessionProjectionSnapshot,
            sessionId: "session-001",
            requestId: "recovery-001"
        )

        let decoded = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyCommandEnvelope.self,
            from: JSONEncoder.pickyAgentProtocolEncoder().encode(command)
        )
        #expect(decoded.type == .getSessionProjectionSnapshot)
        #expect(decoded.sessionId == "session-001")
        #expect(decoded.requestId == "recovery-001")
        #expect(decoded.protocolVersion == pickyAgentProtocolVersion)
    }

    @Test func decodesProjectionMetaPatchWithAbsentNullAndValueUpdates() throws {
        let patch = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickySessionMetaPatch.self,
            from: Data(#"{"title":"Renamed Pickle","cwd":null,"messageJournalAvailable":true}"#.utf8)
        )

        #expect(patch.id == .unchanged)
        #expect(patch.title == .set("Renamed Pickle"))
        #expect(patch.cwd == .clear)
        #expect(patch.messageJournalAvailable == .set(true))
        #expect(patch.archived == .unchanged)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.pickyAgentProtocolDecoder().decode(
                PickySessionMetaPatch.self,
                from: Data(#"{"id":null}"#.utf8)
            )
        }
    }

    @Test func decodesLastRequestClearFixtureAsExplicitClear() throws {
        let fixture = try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-projection-last-request-clear.event.json"
        })
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder()
            .decode(PickyEventEnvelope.self, from: Data(contentsOf: fixture))
        guard case .sessionProjectionTransaction(let transaction) = envelope.event,
              case .metaPatch(let patch) = transaction.mutations.first else {
            Issue.record("Expected lastRequest meta patch")
            return
        }
        #expect(patch.lastRequest == .clear)
        #expect(patch.title == .unchanged)
    }

    @Test func decodesProjectionFixturesIntoNamedDormantEvents() throws {
        let fixtures = try fixtureURLs(in: "contracts/protocol")
        let transactionFixture = try #require(fixtures.first { $0.lastPathComponent == "session-projection-transaction.event.json" })
        let snapshotFixture = try #require(fixtures.first { $0.lastPathComponent == "session-projection-snapshot.event.json" })
        let completionFixture = try #require(fixtures.first { $0.lastPathComponent == "session-projection-bootstrap-complete.event.json" })
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        let transaction = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: transactionFixture))
        let snapshot = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: snapshotFixture))
        let completion = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: completionFixture))

        guard case .sessionProjectionTransaction(let value) = transaction.event else {
            Issue.record("Expected sessionProjectionTransaction")
            return
        }
        #expect(value.sessionId == "session-001")
        #expect(value.epoch == "epoch-001")
        #expect(value.baseRevision == 4)
        #expect(value.revision == 5)
        #expect(value.mutations.map(\.type) == ["metaPatch", "logsSet", "toolsSet", "artifactsSet", "finalAnswerSet", "queueSet"])

        guard case .sessionProjectionSnapshot(let value) = snapshot.event else {
            Issue.record("Expected sessionProjectionSnapshot")
            return
        }
        #expect(value.requestId == "snapshot-001")
        #expect(value.complete == false)
        #expect(value.omittedFields == ["messages", "logs"])
        #expect(value.projection.id == "session-001")

        guard case .sessionProjectionBootstrapComplete(let value) = completion.event else {
            Issue.record("Expected sessionProjectionBootstrapComplete")
            return
        }
        #expect(value.epoch == "epoch-001")
        #expect(value.bootstrapId == "register-capabilities-command-001")
        #expect(value.sessionIds == ["session-001", "session-002"])
    }

    @Test func rejectsInvalidProjectionBootstrapCompletionAsUnknown() throws {
        let invalidPayloads = [
            #"{"id":"invalid-completion","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionBootstrapComplete","epoch":"","bootstrapId":"register-1","sessionIds":[]}"#,
            #"{"id":"invalid-completion","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionBootstrapComplete","epoch":"epoch-1","bootstrapId":"","sessionIds":[]}"#,
            #"{"id":"invalid-completion","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionBootstrapComplete","epoch":"epoch-1","bootstrapId":"register-1","sessionIds":[""]}"#,
            #"{"id":"invalid-completion","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionBootstrapComplete","epoch":"epoch-1","bootstrapId":"register-1","sessionIds":["duplicate","duplicate"]}"#,
        ]
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        for payload in invalidPayloads {
            #expect(try decoder.decode(PickyEventEnvelope.self, from: Data(payload.utf8)).event == .unknown(type: "sessionProjectionBootstrapComplete"))
        }
    }

    @Test func decodesEveryProjectionMutationVariant() throws {
        let mutations = [
            #"{"type":"metaPatch","patch":{"title":"Updated"}}"#,
            #"{"type":"messageAppend","message":{"id":"message-001","kind":"agent_text","createdAt":"2026-08-24T00:00:00.000Z","text":"Answer"}}"#,
            #"{"type":"messageReplace","messageId":"message-001","message":{"id":"message-001","kind":"agent_text","createdAt":"2026-08-24T00:00:00.000Z","text":"Updated answer"}}"#,
            #"{"type":"messageRemove","messageId":"message-001"}"#,
            #"{"type":"messagesImport","messages":[]}"#,
            #"{"type":"logAppend","line":"completed"}"#,
            #"{"type":"logsSet","logs":[]}"#,
            #"{"type":"toolUpsert","tool":{"toolCallId":"tool-001","name":"read","status":"succeeded"}}"#,
            #"{"type":"toolsSet","tools":[]}"#,
            #"{"type":"todoSet","todoState":null}"#,
            #"{"type":"subagentRunsSet","runs":[]}"#,
            #"{"type":"asyncTaskDetailSet","detail":null}"#,
            #"{"type":"asyncControlSet","control":null}"#,
            #"{"type":"artifactUpsert","artifact":{"id":"artifact-001","kind":"report","title":"Report","updatedAt":"2026-08-24T00:00:00.000Z"}}"#,
            #"{"type":"artifactsSet","artifacts":[]}"#,
            #"{"type":"changedFilesSet","changedFiles":[]}"#,
            #"{"type":"queueSet","queuedSteers":[],"queuedFollowUps":[],"steeringMode":"one-at-a-time","followUpMode":"one-at-a-time"}"#,
            #"{"type":"activitySet","activitySummary":{"read":0,"bash":0,"edit":0,"write":0,"thinking":0,"other":0}}"#,
            #"{"type":"finalAnswerSet","finalAnswer":null}"#,
            #"{"type":"extensionUiRequestSet","request":null}"#,
        ]

        let decoded = try mutations.map {
            try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionMutation.self, from: Data($0.utf8))
        }
        #expect(decoded.map(\.type) == [
            "metaPatch", "messageAppend", "messageReplace", "messageRemove", "messagesImport",
            "logAppend", "logsSet", "toolUpsert", "toolsSet", "todoSet", "subagentRunsSet",
            "asyncTaskDetailSet", "asyncControlSet", "artifactUpsert", "artifactsSet", "changedFilesSet", "queueSet", "activitySet",
            "finalAnswerSet", "extensionUiRequestSet",
        ])
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.pickyAgentProtocolDecoder().decode(
                PickySessionProjectionMutation.self,
                from: Data(#"{"type":"messageReplace","messageId":"original","message":{"id":"replacement","kind":"agent_text","createdAt":"2026-08-24T00:00:00.000Z"}}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.pickyAgentProtocolDecoder().decode(
                PickySessionProjectionMutation.self,
                from: Data(#"{"type":"finalAnswerSet"}"#.utf8)
            )
        }
    }

    @Test func rejectsInvalidProjectionEventsAsUnknown() throws {
        let invalidTransactions = [
            #"{"id":"invalid-revision","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionTransaction","sessionId":"session-001","epoch":"epoch-001","baseRevision":5,"revision":5,"mutations":[{"type":"metaPatch","patch":{}}]}"#,
            #"{"id":"invalid-mutation","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionTransaction","sessionId":"session-001","epoch":"epoch-001","baseRevision":4,"revision":5,"mutations":[{"type":"unknown"}]}"#,
            #"{"id":"invalid-meta-patch-key","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionTransaction","sessionId":"session-001","epoch":"epoch-001","baseRevision":4,"revision":5,"mutations":[{"type":"metaPatch","patch":{"statuz":"completed"}}]}"#,
            #"{"id":"invalid-extension-session","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionTransaction","sessionId":"session-001","epoch":"epoch-001","baseRevision":4,"revision":5,"mutations":[{"type":"extensionUiRequestSet","request":{"id":"request-001","sessionId":"other-session","method":"confirm","createdAt":"2026-08-24T00:00:00.000Z"}}]}"#,
        ]
        let invalidSnapshots = [
            #"{"id":"invalid-complete","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionSnapshot","sessionId":"session-001","epoch":"epoch-001","revision":5,"complete":true,"omittedFields":["messages"],"projection":{"id":"session-001","title":"Projection","status":"running","createdAt":"2026-08-24T00:00:00.000Z","updatedAt":"2026-08-24T00:00:00.000Z"}}"#,
            #"{"id":"invalid-field","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionSnapshot","sessionId":"session-001","epoch":"epoch-001","revision":5,"complete":false,"omittedFields":["notAStoredSessionField"],"projection":{"id":"session-001","title":"Projection","status":"running","createdAt":"2026-08-24T00:00:00.000Z","updatedAt":"2026-08-24T00:00:00.000Z"}}"#,
            #"{"id":"invalid-duplicate","protocolVersion":"2026-08-25","timestamp":"2026-08-24T00:00:00.000Z","type":"sessionProjectionSnapshot","sessionId":"session-001","epoch":"epoch-001","revision":5,"complete":false,"omittedFields":["messages","messages"],"projection":{"id":"session-001","title":"Projection","status":"running","createdAt":"2026-08-24T00:00:00.000Z","updatedAt":"2026-08-24T00:00:00.000Z"}}"#,
        ]
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()

        for invalidTransaction in invalidTransactions {
            #expect(try decoder.decode(PickyEventEnvelope.self, from: Data(invalidTransaction.utf8)).event == .unknown(type: "sessionProjectionTransaction"))
        }
        for invalidSnapshot in invalidSnapshots {
            #expect(try decoder.decode(PickyEventEnvelope.self, from: Data(invalidSnapshot.utf8)).event == .unknown(type: "sessionProjectionSnapshot"))
        }
    }

    @Test func keepsSwiftProjectionOwnershipInParityWithManifest() throws {
        let manifestURL = try #require(try fixtureURLs(in: "contracts/projection").first {
            $0.lastPathComponent == "session-field-ownership.json"
        })
        let ownership = try JSONDecoder().decode([PickySessionFieldOwnershipFixture].self, from: Data(contentsOf: manifestURL))

        #expect(Set(ownership.map(\.swiftStore)) == [
            "PickySessionActivityStore", "PickySessionArtifactStore", "PickySessionExtensionUiStore", "PickySessionAsyncTaskStore",
            "PickySessionLogStore", "PickySessionMessageStore", "PickySessionMetaStore", "PickySessionRevisionCursor",
            "PickySessionQueueStore", "PickySessionSubagentStore", "PickySessionTodoStore", "PickySessionToolStore",
            "not-projected",
        ])
        #expect(Set(ownership.filter { $0.swiftStore == "not-projected" }.map(\.field)) == [
            "asyncArchiveIntentId", "asyncControlJournal",
        ])
        #expect(ownership.allSatisfy { ["replace", "merge", "clear-if-omitted-explicit"].contains($0.snapshotSemantics) })
        #expect(Set(ownership.filter { $0.v2Mutation.contains("metaPatch") }.map(\.field)) == Set(PickySessionMetaPatch.CodingKeys.allCases.map(\.stringValue)))
    }
}

private struct PickySessionFieldOwnershipFixture: Decodable {
    let field: String
    let swiftStore: String
    let snapshotSemantics: String
    let v2Mutation: PickySessionFieldOwnershipMutationFixture
}

private enum PickySessionFieldOwnershipMutationFixture: Decodable {
    case single(String)
    case multiple([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .single(value)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }

    func contains(_ value: String) -> Bool {
        switch self {
        case .single(let mutation): mutation == value
        case .multiple(let mutations): mutations.contains(value)
        }
    }
}

private func pointerOverlayEventData(extraRequestField: String = "") -> Data {
    """
    {
      "id":"event-pointer-legacy",
      "protocolVersion":"2026-07-23",
      "timestamp":"2026-07-19T00:00:00.000Z",
      "type":"pointerOverlayRequested",
      "request":{
        "id":"pointer-legacy",
        "x":640,
        "y":360,
        \(extraRequestField)
        "screenBounds":{"x":0,"y":0,"width":1728,"height":1117},
        "screenshotSize":{"width":1280,"height":827}
      }
    }
    """.data(using: .utf8)!
}

private func annotationOverlayRequest(
    from decoder: JSONDecoder,
    annotation: String
) throws -> PickyAnnotationOverlayRequest {
    let envelope = try decoder.decode(
        PickyEventEnvelope.self,
        from: annotationOverlayEventData(annotation: annotation)
    )
    guard case .annotationOverlayRequested(let request) = envelope.event else {
        throw AnnotationOverlayFixtureError.unexpectedEvent
    }
    return request
}

private func annotationOverlayEventData(annotation: String) -> Data {
    """
    {
      "id":"event-annotation-legacy",
      "protocolVersion":"2026-07-23",
      "timestamp":"2026-07-19T00:00:00.000Z",
      "type":"annotationOverlayRequested",
      "request":{
        "id":"annotation-legacy",
        "mode":"replace",
        "annotations":[\(annotation)]
      }
    }
    """.data(using: .utf8)!
}

private enum AnnotationOverlayFixtureError: Error {
    case unexpectedEvent
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

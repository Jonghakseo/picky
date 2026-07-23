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

    @Test func keepsSessionsWithArtifactsContainingRawBacktickURLsInSnapshots() throws {
        let json = """
        {
          "id":"event-snapshot-backtick-url",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:01.000Z",
          "type":"sessionSnapshot",
          "sessions":[
            {
              "id":"session-healthy",
              "title":"Healthy session",
              "status":"completed",
              "cwd":"/tmp/healthy",
              "createdAt":"2026-05-01T00:00:00.000Z",
              "updatedAt":"2026-05-01T00:00:01.000Z",
              "logs":[],
              "tools":[],
              "artifacts":[],
              "changedFiles":[]
            },
            {
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
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)

        guard case .sessionSnapshot(let snapshot) = envelope.event else {
            Issue.record("Expected sessionSnapshot")
            return
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.skippedSessionCount == 0)
        #expect(snapshot.sessions.map(\.id) == ["session-healthy", "session-backtick-url"])
        #expect(snapshot.sessions[1].artifacts.count == 1)
    }

    @Test func marksSnapshotsPartialWhenAContainedSessionCannotDecode() throws {
        let json = """
        {
          "id":"event-snapshot-partial",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-01T00:00:01.000Z",
          "type":"sessionSnapshot",
          "sessions":[
            {"id":"session-a","title":"A","status":"running","cwd":"/tmp/a","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},
            {"id":"session-b","title":"B","status":42,"cwd":"/tmp/b","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},
            {"id":"session-c","title":"C","status":"completed","cwd":"/tmp/c","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)

        guard case .sessionSnapshot(let snapshot) = envelope.event else {
            Issue.record("Expected sessionSnapshot")
            return
        }
        #expect(snapshot.isComplete == false)
        #expect(snapshot.skippedSessionCount == 1)
        #expect(snapshot.sessions.map(\.id) == ["session-a", "session-c"])
    }

    @Test func ignoresUnknownFutureFields() throws {
        let json = """
        {
          "id":"event-future-001",
          "protocolVersion":"2026-07-23",
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
    }

    @Test func decodesPayloadBackedSessionEvents() throws {
        let queueJSON = """
        {
          "id":"event-queue",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-07-19T00:00:00.000Z",
          "type":"sessionQueueUpdated",
          "sessionId":"session-queue",
          "steering":[{"id":"steer-1","text":"slow down","enqueuedAt":"2026-07-19T00:00:00.000Z"}],
          "followUp":[{"id":"follow-1","text":"then report","enqueuedAt":"2026-07-19T00:00:01.000Z"}],
          "steeringMode":"one-at-a-time",
          "followUpMode":"all",
          "seq":7
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

        if case .sessionQueueUpdated(let sessionId, let steering, let followUp, let steeringMode, let followUpMode, let seq) = queue.event {
            #expect(sessionId == "session-queue")
            #expect(steering.map(\.text) == ["slow down"])
            #expect(followUp.map(\.text) == ["then report"])
            #expect(steeringMode == .oneAtATime)
            #expect(followUpMode == .all)
            #expect(seq == 7)
        } else {
            Issue.record("Expected sessionQueueUpdated event")
        }
        #expect(terminal.event == .terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome(
            sessionId: "session-terminal",
            baselineFound: true,
            importedMessageCount: 2,
            activeLastMessageId: "message-last",
            baselinePiMessageId: "pi-baseline"
        )))
    }

    @Test func decodesTodoStateFromSessionUpdateFixture() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixture = try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-updated.event.json"
        })

        let envelope = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: fixture))

        guard case .sessionUpdated(let session) = envelope.event else {
            Issue.record("Expected sessionUpdated event")
            return
        }
        let todoState = try #require(session.todoState)
        #expect(todoState.completedCount == 1)
        #expect(todoState.tasks.count == 2)
        #expect(todoState.tasks[1].status == .inProgress)
        #expect(todoState.tasks[1].activeForm == "Implementing HUD projection")
        #expect(todoState.tasks[1].notes == "Keep the overlay read-only")
    }

    @Test func decodesSlimTodoStateUpdatesIncludingClear() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let fixture = try #require(fixtureURLs(in: "contracts/protocol").first {
            $0.lastPathComponent == "session-todo-state-updated.event.json"
        })
        let update = try decoder.decode(PickyEventEnvelope.self, from: Data(contentsOf: fixture))
        let clearJSON = """
        {
          "id":"event-session-todo-clear",
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-07-14T01:01:00.000Z",
          "type":"sessionTodoStateUpdated",
          "sessionId":"session-001",
          "todoState":null,
          "seq":10
        }
        """.data(using: .utf8)!
        let clear = try decoder.decode(PickyEventEnvelope.self, from: clearJSON)

        guard case .sessionTodoStateUpdated(let sessionID, let todoState, let seq) = update.event else {
            Issue.record("Expected sessionTodoStateUpdated event")
            return
        }
        #expect(sessionID == "session-001")
        #expect(todoState?.tasks.first?.activeForm == "Implementing HUD")
        #expect(seq == 9)
        #expect(clear.event == .sessionTodoStateUpdated(sessionId: "session-001", todoState: nil, seq: 10))
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
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionMessageAppended",
          "sessionId":"session-1",
          "seq":3,
          "message":{
            "id":"notify-1",
            "kind":"system",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "text":"Extension warning",
            "notifyType":"warning"
          }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .sessionMessageAppended(_, let message, _) = event.event else {
            Issue.record("Expected session message appended")
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
          "protocolVersion":"2026-07-23",
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
        #expect(session.todoState == nil)
        #expect(session.piSessionFilePath == nil)
    }

    @Test func decodesExplicitPiSessionFilePath() throws {
        let json = """
        {
          "id":"event-session-file",
          "protocolVersion":"2026-07-23",
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
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-05-05T00:00:00.000Z",
          "type":"sessionMessageAppended",
          "sessionId":"session-001",
          "message":{
            "id":"message-001",
            "kind":"agent_text",
            "createdAt":"2026-05-05T00:00:00.000Z",
            "originatedBy":"main_agent",
            "text":"Done",
            "assistantRun":{"model":"openai-codex/gpt-5.6","thinkingLevel":"max"}
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
        #expect(message.assistantRun?.displayText == "gpt-5.6 max")
        #expect(seq == 7)
    }

    @Test func decodesAgentActivitySessionMessage() throws {
        let json = """
        {
          "id":"event-activity-message",
          "protocolVersion":"2026-07-23",
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
          "protocolVersion":"2026-07-23",
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

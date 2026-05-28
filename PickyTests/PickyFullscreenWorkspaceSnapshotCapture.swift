//
//  PickyFullscreenWorkspaceSnapshotCapture.swift
//  PickyTests
//
//  TEMPORARY: renders the fullscreen workspace with dummy data and writes PNG
//  snapshots to `PICKY_FULLSCREEN_SNAPSHOT_DIR` so the self-healing loop can
//  attach real UI captures as context. When the env var is unset, the test is
//  a no-op so day-to-day `xcodebuild test` runs are unaffected.
//
//  Safe by construction:
//  - never calls `viewModel.start()`, so no WebSocket/daemon traffic
//  - uses an in-memory `UserDefaults` suite for `PickyFullscreenStateStore`
//  - does not depend on the running Picky.app process
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Picky

// Snapshot output directory is derived from this file's location so the test
// can write captures without depending on env propagation through xcodebuild.
// Captures are placed at `<repo>/build/fullscreen-snapshots/` and only when
// the marker file `<repo>/build/fullscreen-snapshots/.enabled` exists. The
// marker is created by the self-healing flow before running the test and is
// removed afterwards, so plain `xcodebuild test` runs stay no-ops.
private let repoRootForSnapshotTests: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // PickyTests
    .deletingLastPathComponent() // repo root

private let snapshotOutputDir: URL = repoRootForSnapshotTests
    .appendingPathComponent("build/fullscreen-snapshots", isDirectory: true)

private let snapshotMarkerURL: URL = snapshotOutputDir.appendingPathComponent(".enabled")

@MainActor
struct PickyFullscreenWorkspaceSnapshotCapture {
    @Test func captureWorkspaceSnapshots() async throws {
        guard FileManager.default.fileExists(atPath: snapshotMarkerURL.path) else {
            // Marker file absent. Keep ordinary `xcodebuild test` runs cheap
            // and side-effect free.
            return
        }
        let outputURL = snapshotOutputDir
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let scenarios: [SnapshotScenario] = [
            .init(name: "completed", selected: "session-completed"),
            .init(name: "running", selected: "session-running"),
            .init(name: "waiting", selected: "session-waiting"),
            .init(name: "empty", selected: nil, omitSessions: true),
            .init(name: "completed-rail", selected: "session-completed", workInfoPanelVisible: false),
            .init(name: "running-rail", selected: "session-running", workInfoPanelVisible: false),
        ]

        for scenario in scenarios {
            try capture(scenario: scenario, outputDirectory: outputURL)
        }
    }

    private func capture(scenario: SnapshotScenario, outputDirectory: URL) throws {
        let client = SnapshotFakeAgentClient()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter()
        )
        if !scenario.omitSessions {
            for json in SnapshotDummyData.sessionUpdatedJSONs() {
                viewModel.apply(.protocolEvent(.fixture(eventJSON: json)))
            }
        }

        let stateStore = PickyFullscreenStateStore(defaults: SnapshotIsolatedDefaults.make())
        stateStore.selectedSessionID = scenario.selected
        stateStore.isWorkInfoPanelVisible = scenario.workInfoPanelVisible

        let view = PickyFullscreenWorkspaceView(viewModel: viewModel, stateStore: stateStore)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 920)
        hosting.layoutSubtreeIfNeeded()

        // Drive the run loop briefly so SwiftUI completes its first frame and
        // any async `onAppear` reconcile passes settle before we cache the bitmap.
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            Issue.record("Failed to create bitmap rep for scenario \(scenario.name)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG for scenario \(scenario.name)")
            return
        }
        let outputURL = outputDirectory.appendingPathComponent("fullscreen-\(scenario.name).png")
        try pngData.write(to: outputURL, options: .atomic)
        // Print so the test log records the absolute path even when xcodebuild
        // mangles the working directory.
        print("captured: \(outputURL.path)")
    }
}

private struct SnapshotScenario {
    let name: String
    let selected: String?
    var omitSessions: Bool = false
    var workInfoPanelVisible: Bool = true
}

private enum SnapshotIsolatedDefaults {
    static func make() -> UserDefaults {
        // Random suite name so each capture run is fully isolated from the
        // user's standard defaults. We do not register persistent settings.
        let suite = "picky.fullscreen.snapshot.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}

private final class SnapshotFakeAgentClient: PickyAgentClient {
    let events: AsyncStream<PickyClientEvent>
    private let continuation: AsyncStream<PickyClientEvent>.Continuation

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "snapshot-session", message: "noop")
    }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() {}
}

private extension PickyEventEnvelope {
    static func fixture(eventJSON: String) -> PickyEventEnvelope {
        try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(eventJSON.utf8))
    }
}

private enum SnapshotDummyData {
    static func sessionUpdatedJSONs() -> [String] {
        let runningMessages = """
        [
          {"id":"msg-r-1","kind":"user_text","createdAt":"2026-05-28T02:55:00.000Z","originatedBy":"user","text":"Picky 전체화면에서 모델/추론 표시가 빈 칸인 케이스를 점검해줘.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-r-2","kind":"agent_thinking","createdAt":"2026-05-28T02:56:00.000Z","originatedBy":"main_agent","text":"세션의 currentAssistantRun이 nil일 때 최신 메시지에서 fallback 하는지 확인 중...","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-r-3","kind":"agent_activity","createdAt":"2026-05-28T02:57:00.000Z","originatedBy":"main_agent","text":"PickyFullscreenAssistantRunResolver 호출","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-r-4","kind":"agent_text","createdAt":"2026-05-28T02:58:30.000Z","originatedBy":"main_agent","text":"진행 상태입니다: 모델/추론 fallback 코드를 검토 중이고 곧 변경 파일 목록과 함께 정리할게요.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null,"assistantRun":{"model":"opus-4-7","thinkingLevel":"high"}}
        ]
        """
        let completedMessages = """
        [
          {"id":"msg-c-1","kind":"user_text","createdAt":"2026-05-27T21:00:00.000Z","originatedBy":"user","text":"이번 주 릴리즈 회고를 짧게 정리해줘. 핵심 변경, 리스크, 다음 액션.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-c-int1","kind":"agent_text","createdAt":"2026-05-27T21:05:00.000Z","originatedBy":"main_agent","text":"릴리즈 노트와 최근 PR을 확인하고 있어요. 잠시만요.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-c-int2","kind":"agent_activity","createdAt":"2026-05-27T21:30:00.000Z","originatedBy":"main_agent","text":"read docs/release-notes.md","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-c-int3","kind":"agent_text","createdAt":"2026-05-27T22:00:00.000Z","originatedBy":"main_agent","text":"릴리즈 노트 확인 완료. 회고 노트를 작성할게요.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-c-int4","kind":"agent_activity","createdAt":"2026-05-27T22:15:00.000Z","originatedBy":"main_agent","text":"write docs/release-retro-2026-05.md","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-c-final","kind":"agent_text","createdAt":"2026-05-27T22:30:00.000Z","originatedBy":"main_agent","text":"## 릴리즈 회고\\n\\n- 핵심 변경: Picky 전체화면 워크스페이스 도입, dock/fullscreen 상호 배타.\\n- 리스크: 멀티 모니터에서 dock 복원 timing, 긴 대화에서 마크다운 렌더링 비용.\\n- 다음 액션: 알파 테스트 빌드 배포, 사용자 피드백 채널에서 단축키 충돌 모니터링.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null,"assistantRun":{"model":"opus-4-7","thinkingLevel":"medium"}}
        ]
        """
        let waitingMessages = """
        [
          {"id":"msg-w-1","kind":"user_text","createdAt":"2026-05-28T01:00:00.000Z","originatedBy":"user","text":"DB 마이그레이션을 production에 바로 돌려도 안전한지 확인해줘.","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},
          {"id":"msg-w-2","kind":"agent_text","createdAt":"2026-05-28T02:00:00.000Z","originatedBy":"main_agent","text":"잠깐 확인이 필요해요: 동일 마이그레이션이 staging에서 이미 통과된 상태인가요?","question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null,"assistantRun":{"model":"opus-4-7","thinkingLevel":"medium"}}
        ]
        """

        let runningTools = """
        [{"toolCallId":"tool-r-1","name":"grep","status":"running","preview":"PickyFullscreenAssistantRunResolver","startedAt":"2026-05-28T02:56:30.000Z","endedAt":null}]
        """
        let completedTools = """
        [
          {"toolCallId":"tool-c-1","name":"read","status":"succeeded","preview":"docs/release-notes.md","startedAt":"2026-05-27T21:30:00.000Z","endedAt":"2026-05-27T21:30:30.000Z"},
          {"toolCallId":"tool-c-2","name":"write","status":"succeeded","preview":"docs/release-retro-2026-05.md","startedAt":"2026-05-27T22:00:00.000Z","endedAt":"2026-05-27T22:15:00.000Z"}
        ]
        """
        let completedChangedFiles = """
        [
          {"path":"docs/release-retro-2026-05.md","status":"added","summary":"릴리즈 회고 노트 신규 작성"},
          {"path":"Picky/Fullscreen/Views/PickyFullscreenWorkspaceView.swift","status":"modified","summary":"전체화면 워크스페이스 기본 selection 보정"}
        ]
        """
        let completedArtifacts = """
        [{"id":"art-c-1","kind":"file","title":"release-retro-2026-05.md","path":"docs/release-retro-2026-05.md","url":null,"updatedAt":"2026-05-27T22:30:00.000Z"}]
        """
        let runningContextUsage = """
        ,"contextUsage":{"tokens":62300,"contextWindow":200000,"percent":31}
        """
        let completedContextUsage = """
        ,"contextUsage":{"tokens":118000,"contextWindow":200000,"percent":59}
        """
        let waitingContextUsage = """
        ,"contextUsage":{"tokens":28500,"contextWindow":200000,"percent":14}
        """

        let running = """
        {"id":"snapshot-evt-running","protocolVersion":"2026-05-09","timestamp":"2026-05-28T02:58:30.000Z","type":"sessionUpdated","session":{"id":"session-running","title":"Picky 전체화면 점검","status":"running","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-28T02:50:00.000Z","updatedAt":"2026-05-28T02:58:30.000Z","lastSummary":"전체화면 모델/추론 fallback 검토 중","thinkingPreview":"currentAssistantRun nil 케이스 점검","logs":[],"tools":\(runningTools),"artifacts":[],"changedFiles":[],"messages":\(runningMessages),"currentAssistantRun":{"model":"opus-4-7","thinkingLevel":"high"}\(runningContextUsage)}}
        """
        let completed = """
        {"id":"snapshot-evt-completed","protocolVersion":"2026-05-09","timestamp":"2026-05-27T22:30:00.000Z","type":"sessionUpdated","session":{"id":"session-completed","title":"릴리즈 회고 노트 정리","status":"completed","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-27T20:00:00.000Z","updatedAt":"2026-05-27T22:30:00.000Z","lastSummary":"Done","logs":[],"tools":\(completedTools),"artifacts":\(completedArtifacts),"changedFiles":\(completedChangedFiles),"messages":\(completedMessages),"piSessionFilePath":"/Users/creatrip/.pi/sessions/session-completed.jsonl"\(completedContextUsage)}}
        """
        let waiting = """
        {"id":"snapshot-evt-waiting","protocolVersion":"2026-05-09","timestamp":"2026-05-28T02:00:00.000Z","type":"sessionUpdated","session":{"id":"session-waiting","title":"DB 마이그레이션 안전한가요?","status":"waiting_for_input","cwd":"/Users/creatrip/Documents/creatrip-app","createdAt":"2026-05-28T01:00:00.000Z","updatedAt":"2026-05-28T02:00:00.000Z","lastSummary":"사용자 확인 필요","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"messages":\(waitingMessages),"notifyMainOnCompletion":true\(waitingContextUsage)}}
        """

        return [running, completed, waiting]
    }
}

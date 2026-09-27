import AppKit
import SwiftUI
@testable import Picky

/// Only data/transport are fixtures. Header, conversation, composer, colors, fonts and
/// sizing are the production implementations, linked from the current Debug build.
@MainActor
private final class StudySession {
    let storage = PickyRegistrySessionProjectionStorage()
    let client = StudyClient()
    let model: PickySessionListViewModel
    let store: PickySessionStore
    var session: PickyAgentSession
    private var revision = 0

    init() {
        model = PickySessionListViewModel(client: client, sessionProjectionStorage: storage)
        store = storage.registry.sessionStore(sessionID: "async-ui-study")
        let now = Date()
        session = PickyAgentSession(id: "async-ui-study", title: "로그인 오류 수정", status: .running,
            cwd: "/tmp/picky-ui-study", createdAt: now.addingTimeInterval(-180), updatedAt: now,
            lastSummary: "테스트와 변경사항 리뷰를 실행하고 있어요.", logs: [], tools: [], artifacts: [], changedFiles: [],
            messages: [
                Self.message("request", .userText, "로그인 오류를 고치고 테스트도 확인해줘.", now.addingTimeInterval(-170)),
                Self.message("reply", .agentText,
                    "인증 토큰을 갱신하는 부분을 수정했어요.\n\n테스트와 변경사항 리뷰를 함께 실행하고 있어요.", now.addingTimeInterval(-100))
            ])
        session.agentCycle = .init(cycleId: "study-cycle", runtimeInstanceId: "study-runtime",
                                  phase: .idle, outcome: nil, controlGeneration: 1)
        session.currentAssistantRun = .init(model: "openai-codex/gpt-5.6", thinkingLevel: .high)
        client.onControl = { [weak self] command in
            guard let self else { throw PickyAsyncControlError.requestConflict }
            if command.type == .cancelAsyncTask {
                for index in session.asyncTasks?.indices ?? 0..<0 {
                    if session.asyncTasks?[index].rootTaskId == command.taskId {
                        session.asyncTasks?[index].execution = .cancelled
                        session.asyncTasks?[index].presence = .settled
                    }
                }
                try publish()
            }
            return PickyAsyncTaskCommandResult(type: "asyncTaskResult", requestId: command.requestId,
                sessionId: command.sessionId, daemonInstanceId: command.daemonInstanceId,
                runtimeInstanceId: command.runtimeInstanceId, workRevision: command.workRevision,
                controlGeneration: command.controlGeneration, operationId: "study-operation", outcome: .settled,
                detail: .init(tasks: session.asyncTasks ?? [], tickets: session.completionTickets ?? []))
        }
        try! install("running")
    }

    private static func message(_ id: String, _ kind: PickySessionMessageKind, _ text: String, _ date: Date) -> PickySessionMessage {
        .init(id: id, kind: kind, createdAt: date, originatedBy: kind == .userText ? .user : nil,
              text: text, question: nil, cancelledAt: nil, activitySnapshot: nil, errorContext: nil, errorMessage: nil)
    }

    func task(_ id: String, title: String, execution: PickyExecutionState = .running,
              presence: PickyExecutionPresence = .active, root: String? = nil) -> PickyAsyncTask {
        var task = PickyAsyncTask(sessionId: session.id, piSessionId: "study-pi", runtimeInstanceId: "study-runtime",
            providerId: "study-provider", providerInstanceId: "study-instance", taskId: id,
            rootTaskId: root ?? id, parentTaskId: root, kind: id == "review" ? "subagent" : "bash", title: title,
            execution: execution, presence: presence, registration: .spawned, providerRevision: 1,
            controlGeneration: 1, createdAt: Date().addingTimeInterval(id == "review" ? -38 : -102), updatedAt: Date())
        task.progress = id == "review" ? "토큰 갱신과 오류 처리 부분을 검토하고 있어요." : "인증 관련 테스트를 실행하고 있어요."
        return task
    }

    func install(_ state: String) throws {
        let first = task("tests", title: "테스트 실행")
        session.completionTickets = []
        switch state {
        case "running": session.asyncTasks = [first, task("review", title: "변경사항 리뷰")]
        case "processing":
            session.asyncTasks = [task("tests", title: "테스트 실행", execution: .succeeded, presence: .settled)]
            session.completionTickets = [.init(sessionId: session.id, piSessionId: "study-pi", runtimeInstanceId: "study-runtime",
                providerId: "study-provider", providerInstanceId: "study-instance", completionId: "study-result",
                rootTaskId: "tests", target: .model, state: .processing, controlGeneration: 1, cycleId: "study-cycle")]
        case "failed": session.asyncTasks = [task("tests", title: "테스트 실행", execution: .failed, presence: .settled)]
        case "unknown": session.asyncTasks = [task("tests", title: "테스트 실행", presence: .unknown)]
        case "queued": session.asyncTasks = [task("tests", title: "テスト", execution: .queued)]
        case "surviving-child":
            session.asyncTasks = [task("tests", title: "테스트 실행", execution: .failed, presence: .settled),
                                  task("child", title: "통합 테스트", root: "tests")]
        default: session.asyncTasks = []
        }
        try publish()
    }

    private func publish() throws {
        revision += 1
        let runningRoots = Set((session.asyncTasks ?? []).filter { $0.execution == .running && $0.presence == .active }.map(\.rootTaskId))
        let tasks: [PickyAsyncTask] = session.asyncTasks ?? []
        let unknownCount = tasks.filter { $0.presence == .unknown }.count
        let failedCount = tasks.filter { $0.execution == .failed }.count
        let pendingCount = session.completionTickets?.count ?? 0
        session.asyncWorkSummary = PickyAsyncWorkSummary(tracking: .ready, activeRootCount: runningRoots.count,
            pendingCompletionCount: pendingCount, uncertainExecutionCount: unknownCount,
            attentionCount: failedCount, workRevision: revision, canReleaseRuntime: runningRoots.isEmpty)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try JSONSerialization.data(withJSONObject: ["sessionId": session.id, "epoch": "study",
            "revision": revision, "complete": true, "omittedFields": [],
            "projection": JSONSerialization.jsonObject(with: encoder.encode(session))])
        let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: data)
        precondition(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
        storage.registry.replaceMembership(active: [session.id], archived: [])
    }
}

@MainActor
private final class StudyClient: PickyAgentClient, PickyAsyncTaskControlling {
    let events = AsyncStream<PickyClientEvent> { $0.finish() }
    var onControl: ((PickyAsyncTaskCommand) throws -> PickyAsyncTaskCommandResult)?
    func connect() async {}
    func disconnect() {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        throw PickyAsyncControlError.unsupported
    }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func asyncControlContext(sessionID: String) async throws -> PickyAsyncControlContext {
        .init(requestId: "study", sessionId: sessionID, daemonInstanceId: "study-daemon",
              runtimeInstanceId: "study-runtime", workRevision: 1, controlGeneration: 1, admissionState: .open,
              tracking: .ready, expectedProviders: ["study-provider"], readyProviders: ["study-provider"])
    }
    func executeAsyncControl(_ command: PickyAsyncTaskCommand) async throws -> PickyAsyncTaskCommandResult {
        guard let onControl else { throw PickyAsyncControlError.unsupported }
        return try onControl(command)
    }
    func beginDeletion(sessionID: String) {}
    func endDeletion(sessionID: String) {}
    func invalidateAsyncArchiveIntent(sessionID: String) {}
    func stopAsyncWork(sessionID: String) async throws -> PickyAsyncTaskCommandResult { throw PickyAsyncControlError.unsupported }
    func archiveAsyncSession(sessionID: String, mode: PickyAsyncTaskCommand.ArchiveMode?) async throws { throw PickyAsyncControlError.unsupported }
    func restoreAsyncSession(sessionID: String) async throws { throw PickyAsyncControlError.unsupported }
    func releaseArchivedAsyncSession(sessionID: String) async throws -> Bool { false }
}

private struct StudyBoard: View {
    let session: StudySession
    @State private var running = true
    @State private var dark = false
    var forcedDark: Bool?
    private var scheme: ColorScheme { (forcedDark ?? dark) ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space3) {
            HStack {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    Text("백그라운드 작업 · 실제 UI 비교").font(PickyHUDTypography.heading(level: 1))
                    Text("동일한 세션 · 446 × 640pt · 하단 작업 표시만 변경")
                        .font(PickyHUDTypography.supporting).foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
                Toggle("실행 중인 작업", isOn: $running).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: running) { _, value in try? session.install(value ? "running" : "empty") }
                Toggle("다크 모드", isOn: $dark).toggleStyle(.switch).controlSize(.small)
                    .disabled(forcedDark != nil)
                    .onChange(of: dark) { _, value in NSApp.appearance = NSAppearance(named: value ? .darkAqua : .aqua) }
            }
            HStack(alignment: .top, spacing: DS.Spacing.space6) {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    Text("현재 UI").font(PickyHUDTypography.title)
                    Picky.PickyConversationCardView(viewModel: session.model, sessionStore: session.store,
                        maxHeight: 640, width: 446, fixedHeight: 640)
                }
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    Text("개선안 · 실행 중인 작업만").font(PickyHUDTypography.title)
                    StudyConversationCardView(viewModel: session.model, sessionStore: session.store,
                        maxHeight: 640, width: 446, fixedHeight: 640)
                }
            }
            Text("예시 데이터예요. 작업 줄을 펼치고 작업을 선택하면 상세와 중지가 나타나요.")
                .font(PickyHUDTypography.supporting).foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(DS.Spacing.space6)
        .frame(width: 964, height: 792, alignment: .top)
        .background(DS.Colors.background)
        .environment(\.locale, Locale(identifier: "ko"))
        .environment(\.colorScheme, scheme)
        .environment(\.pickyAppFontScale, 1)
    }
}

@main
private enum AsyncWorkStudyApp {
    @MainActor static func main() throws {
        // Reuse the app's fail-closed test environment for preferences, credentials and paths.
        // This does not opt into UI-effect tests; only our explicitly requested mock window opens.
        setenv("XCTestBundlePath", "PickyAsyncUIStudy", 1)
        let app = NSApplication.shared
        LocaleManager.shared.apply(.korean)
        let session = StudySession()
        if CommandLine.arguments.contains("--verify") {
            app.setActivationPolicy(.prohibited)
            try verify(session)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            app.setActivationPolicy(.prohibited)
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
                app.appearance = NSAppearance(named: appearance)
                let view = StudyBoard(session: session, forcedDark: dark)
                guard let bitmap = PickyRenderGalleryRasterizer.rasterize(view, logicalSize: CGSize(width: 964, height: 792),
                    scale: 2, appearance: appearance), let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw PickyAsyncControlError.invalidResponse
                }
                try png.write(to: output.appendingPathComponent("production-\(dark ? "dark" : "light").png"))
                print("Rendered production \(dark ? "dark" : "light") \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
            }
            return
        }
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 964, height: 792),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Picky · 실제 UI 기반 작업 표시 목업"
        window.contentView = NSHostingView(rootView: StudyBoard(session: session))
        window.isReleasedWhenClosed = false
        let delegate = StudyDelegate()
        app.delegate = delegate
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "목업 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        menu.addItem(item)
        app.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func verify(_ session: StudySession) throws {
        let host = NSHostingView(rootView: PickyRunningTaskFooterView(store: session.store, commands: session.model,
            maxListHeight: 120).frame(width: 422))
        for state in ["running", "processing", "failed", "unknown", "queued", "empty", "surviving-child", "empty"] {
            try session.install(state)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            let shouldShow = ["running", "surviving-child"].contains(state)
            precondition(shouldShow ? height >= 28 : height == 0, "Unexpected mounted footer for \(state): \(height)")
            print("PASS v2 snapshot → mounted footer: \(state) height=\(height)")
        }
    }
}

private final class StudyDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

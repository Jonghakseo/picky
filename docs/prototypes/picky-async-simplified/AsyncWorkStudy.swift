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
    let fixture: StudyFixture
    private var revision = 0

    init() throws {
        fixture = try StudyFixture.load()
        model = PickySessionListViewModel(client: client, sessionProjectionStorage: storage)
        store = storage.registry.sessionStore(sessionID: "async-ui-study")
        let now = Date()
        let messageCount = fixture.messages.count
        session = PickyAgentSession(id: "async-ui-study", title: fixture.sessionTitle, status: .running,
            cwd: "/tmp/picky-ui-study", createdAt: now, updatedAt: now,
            logs: [], tools: [], artifacts: [], changedFiles: [],
            messages: fixture.messages.enumerated().map { index, message in
                Self.message("fixture-\(index)", message.kind, message.text, now.addingTimeInterval(Double(index - messageCount)))
            })
        session.agentCycle = .init(cycleId: "study-cycle", runtimeInstanceId: "study-runtime",
                                  phase: .idle, outcome: nil, controlGeneration: 1)
        session.currentAssistantRun = .init(model: "openai-codex/gpt-5.6", thinkingLevel: .high)
        try install("running")
    }

    private static func message(_ id: String, _ kind: PickySessionMessageKind, _ text: String, _ date: Date) -> PickySessionMessage {
        .init(id: id, kind: kind, createdAt: date, originatedBy: kind == .userText ? .user : nil,
              text: text, question: nil, cancelledAt: nil, activitySnapshot: nil, errorContext: nil, errorMessage: nil)
    }

    func task(_ id: String, title: String, execution: PickyExecutionState = .running,
              presence: PickyExecutionPresence = .active, root: String? = nil) -> PickyAsyncTask {
        let task = PickyAsyncTask(sessionId: session.id, piSessionId: "study-pi", runtimeInstanceId: "study-runtime",
            providerId: id == "review" || root == "review" ? "subagent" : "bash-async", providerInstanceId: "study-instance", taskId: id,
            rootTaskId: root ?? id, parentTaskId: root, kind: id == "review" || root == "review" ? "subagent" : "bash", title: title,
            execution: execution, presence: presence, registration: .spawned, providerRevision: 1,
            controlGeneration: 1, createdAt: Date(), updatedAt: Date())
        return task
    }

    func install(_ state: String) throws {
        let first = task("tests", title: fixture.bashTitle)
        session.completionTickets = []
        session.subagentRuns = []
        switch state {
        case "running":
            var root = task("review", title: fixture.subagentTitle)
            root.invocationId = "study-invocation"
            let children = fixture.runs.map { run in
                var child = task("run-\(run.runId)", title: run.agent, root: "review")
                child.invocationId = root.invocationId
                child.details = ["runId": .number(Double(run.runId))]
                child.createdAt = Date().addingTimeInterval(-(run.elapsedMs ?? 0) / 1000)
                return child
            }
            root.createdAt = children.map(\.createdAt).min() ?? root.createdAt
            session.asyncTasks = [first, root] + children
            session.subagentRuns = fixture.runs
        case "processing":
            session.asyncTasks = [task("tests", title: fixture.bashTitle, execution: .succeeded, presence: .settled)]
            session.completionTickets = [.init(sessionId: session.id, piSessionId: "study-pi", runtimeInstanceId: "study-runtime",
                providerId: "bash-async", providerInstanceId: "study-instance", completionId: "study-result",
                rootTaskId: "tests", target: .model, state: .processing, controlGeneration: 1, cycleId: "study-cycle")]
        case "failed": session.asyncTasks = [task("tests", title: fixture.bashTitle, execution: .failed, presence: .settled)]
        case "unknown": session.asyncTasks = [task("tests", title: fixture.bashTitle, presence: .unknown)]
        case "queued": session.asyncTasks = [task("tests", title: "テスト", execution: .queued)]
        case "surviving-child":
            session.asyncTasks = [task("tests", title: fixture.bashTitle, execution: .failed, presence: .settled),
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

private struct StudyFixture: Decodable {
    struct Message: Decodable { let kind: PickySessionMessageKind; let text: String }
    let label: String
    let sessionTitle: String
    let bashTitle: String
    let subagentTitle: String
    let runs: [PickySubagentRun]
    let messages: [Message]

    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "session-fixture", withExtension: "json") else {
            throw PickyAsyncControlError.invalidResponse
        }
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@MainActor
private final class StudyClient: PickyAgentClient {
    let events = AsyncStream<PickyClientEvent> { $0.finish() }
    func connect() async {}
    func disconnect() {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        throw PickyAsyncControlError.unsupported
    }
    func send(_ command: PickyCommandEnvelope) async throws {}
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
                    Text(session.fixture.label)
                        .font(PickyHUDTypography.supporting).foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer()
                Toggle("실행 중인 작업", isOn: $running)
                    .toggleStyle(.button).controlSize(.regular)
                    .accessibilityIdentifier("study.running")
                    .onChange(of: running) { _, value in try? session.install(value ? "running" : "empty") }
                Toggle("다크 모드", isOn: $dark)
                    .toggleStyle(.button).controlSize(.regular)
                    .accessibilityIdentifier("study.dark")
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
            Text("실제 에이전트 종류를 묶어 표시해요. 같은 종류는 × 개수로 표시하며, 항목별 상세는 없어요.")
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
        let session = try StudySession()
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
        let host = NSHostingView(rootView: PickyRunningTaskFooterView(store: session.store,
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

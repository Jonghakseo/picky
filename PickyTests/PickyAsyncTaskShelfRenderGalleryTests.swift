import AppKit
import Combine
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyAsyncTaskShelfRenderGalleryTests {
    private let request = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.async-tasks-output-path")

    @Test func writesProductionShelfGalleryWhenRequested() throws {
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let path = try String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var scenes: [[String: Any]] = []
        for light in [false, true] {
            for scale in [1.0, 1.3] {
                for state in ["single", "multiple", "group", "expanded", "processing", "failure", "reconciling", "unsupported", "unknown"] {
                    let name = "\(state)-\(light ? "light" : "dark")-\(Int(scale * 100)).png"
                    try LocaleManager.shared.withTemporaryChoiceForTesting(scale == 1.3 ? .korean : .english) {
                        let view = content(state: state, scale: scale)
                            .environment(\.pickyAppFontScale, scale)
                            .environment(\.locale, Locale(identifier: scale == 1.3 ? "ko" : "en"))
                            .environment(\.colorScheme, light ? .light : .dark)
                            .frame(width: 420)
                            .padding(DS.Spacing.space3)
                            .background(DS.Colors.background)
                        let host = NSHostingView(rootView: view)
                        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                        host.layoutSubtreeIfNeeded()
                        let size = host.fittingSize
                        #expect(size.width > 0 && size.height > 0)
                        host.frame = NSRect(origin: .zero, size: size)
                        host.layoutSubtreeIfNeeded()
                        let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(
                            view, logicalSize: size, scale: 2, appearance: light ? .aqua : .darkAqua))
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent(name), options: .atomic)
                        #expect(NSImage(data: png) != nil)
                        scenes.append(["file": name, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                                       "logicalWidth": size.width, "logicalHeight": size.height])
                    }
                }
            }
        }
        try renderMountedScenes(into: output, scenes: &scenes)
        let manifest: [String: Any] = ["schemaVersion": 1, "renderer": "production shelf, mounted conversation and archive / offscreen NSHostingView", "scenes": scenes]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        #expect(scenes.count == 60)
    }

    @Test func boundedDetailsRemainReachableWithoutInflatingShortRows() throws {
        let request = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/render-gallery/.async-tasks-bounds-output-path")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let output = URL(fileURLWithPath: try String(contentsOf: request, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var heights: [String: CGFloat] = [:]
        for count in [1, 2] {
            for long in [false, true] {
                let name = "\(count)-\(long ? "overflow" : "short")"
                let roots = (0..<count).map { index -> PickyAsyncTask in
                    var root = recent(PickyAsyncTaskShelfFixtures.task("root-\(index)", title: "Run local checks"))
                    if long {
                        root.progress = "Review the first task result and inspect the retained provider notes."
                    }
                    return root
                }
                let children = long ? roots.flatMap { root in
                    (0..<8).map { index -> PickyAsyncTask in
                        let id = "child-\(root.taskId)-\(index)"
                        var child = recent(PickyAsyncTaskShelfFixtures.task(id, root: root.taskId,
                            title: "Inspect retained child result \(index)"))
                        child.progress = "Provider result \(index) remains available in the scroll document."
                        return child
                    }
                } : []
                let details = PickyAsyncTaskDetail(tasks: roots + children, tickets: [])
                let error = long
                    ? String(repeating: "Provider failure requires inspection of the complete response. ", count: 13)
                    : nil
                let view = PickyAsyncTaskShelfView(summary: PickyAsyncTaskShelfFixtures.summary(active: count),
                    detailState: .loaded(details), maxListHeight: 120, initiallyExpandedRows: long,
                    detailError: { _ in error }, cancelAvailability: { _ in .available }, onAction: { _ in })
                    .environment(\.pickyAppFontScale, 1.3)
                    .frame(width: 380)
                let host = NSHostingView(rootView: view)
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size,
                    scale: 2, appearance: .aqua))
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
                heights[name] = size.height
                if long {
                    let document = NSHostingView(rootView: PickyAsyncTaskShelfRowView(root: roots[0],
                        detail: details, summary: PickyAsyncTaskShelfFixtures.summary(active: count),
                        availability: .available, onAction: { _ in }, isExpanded: true,
                        detailError: error).environment(\.pickyAppFontScale, 1.3).frame(width: 356))
                    #expect(document.fittingSize.height > 120, "Expanded child and failure details exceed the viewport")
                }
                // The user's card/popover budget is 120pt for the list plus the shelf heading and padding.
                #expect(size.height <= 185, "\(name) must fit inside the bounded shelf")
            }
        }
        #expect(try #require(heights["1-short"]) < 120, "The ordinary row stays intrinsic, without a blank scroll area")
        let longHeight = try #require(heights["1-overflow"])
        let shortHeight = try #require(heights["1-short"])
        #expect(longHeight > shortHeight)
        let data = try JSONSerialization.data(withJSONObject: heights, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("heights.json"), options: .atomic)
    }

    @Test func expandedRowUpdatesItsDocumentWithoutRecreatingTheHost() {
        let root = PickyAsyncTaskShelfFixtures.task("root")
        let child = PickyAsyncTaskShelfFixtures.task("child", root: root.taskId)
        let model = RowDisclosureModel()
        let view = ControlledRowDisclosure(root: root, child: child, model: model)
            .frame(width: 356)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let collapsed = host.fittingSize.height
        model.expanded = true
        host.rootView = view
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > collapsed)
        model.expanded = false
        host.rootView = view
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == collapsed)
    }

    private func renderMountedScenes(into output: URL, scenes: inout [[String: Any]]) throws {
        for light in [false, true] {
            for scale in [1.0, 1.3] {
                try LocaleManager.shared.withTemporaryChoiceForTesting(scale == 1.3 ? .korean : .english) {
                    let registry = PickySessionRegistry()
                    let store = registry.sessionStore(sessionID: "session")
                    var card = PickySessionCard.fromAgentSession(PickyAgentSession(
                        id: "session", title: "보관된 작업 / Archived work", status: .running, cwd: "/tmp/project",
                        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                        lastSummary: "Background work", logs: [], tools: [], artifacts: [], changedFiles: [], messages: []))
                    card.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 1)
                    card.asyncTasks = [PickyAsyncTaskShelfFixtures.task("root")]
                    card.completionTickets = []
                    card.archived = true
                    store.replace(card: card)
                    registry.replaceMembership(active: [], archived: ["session"])
                    let model = PickySessionListViewModel(client: FakePickyAgentClient())
                    let name = "archived-\(light ? "light" : "dark")-\(Int(scale * 100)).png"
                    let view = PickyHUDArchivedSessionsListView(archiveMembership: registry, commands: model)
                        .environment(\.pickyAppFontScale, scale)
                        .environment(\.locale, Locale(identifier: scale == 1.3 ? "ko" : "en"))
                        .environment(\.colorScheme, light ? .light : .dark)
                        .frame(width: 420, height: 230)
                        .background(DS.Colors.background)
                    let size = CGSize(width: 420, height: 230)
                    let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size,
                        scale: 2, appearance: light ? .aqua : .darkAqua))
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent(name), options: .atomic)
                    scenes.append(["file": name, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                        "logicalWidth": size.width, "logicalHeight": size.height])
                }
                for state in ["running", "short", "processing", "failure", "unavailable"] {
                    try LocaleManager.shared.withTemporaryChoiceForTesting(scale == 1.3 ? .korean : .english) {
                        let root = recent(PickyAsyncTaskShelfFixtures.task("root", title: scale == 1.3
                            ? "한국어와日本語가 섞인 아주 긴 작업 제목으로 결과와 하위 작업 상태를 확인합니다" : "Run local checks",
                            execution: state == "processing" ? .succeeded : state == "failure" ? .failed : .running,
                            presence: state == "processing" || state == "failure" ? .settled : .active))
                        var card = PickySessionCard.fromAgentSession(PickyAgentSession(
                            id: "session", title: "Async Pickle", status: .running, cwd: "/tmp/project",
                            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                            lastSummary: "Background work", logs: [], tools: [], artifacts: [], changedFiles: [], messages: []))
                        card.agentCycle = .init(cycleId: "cycle", runtimeInstanceId: root.runtimeInstanceId,
                            phase: .idle, outcome: nil, controlGeneration: 1)
                        card.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(
                            active: state == "processing" || state == "failure" ? 0 : 1,
                            pending: state == "processing" ? 1 : 0,
                            attention: state == "failure" ? 1 : 0)
                        card.asyncTasks = state == "unavailable" ? nil : [root]
                        card.completionTickets = state == "unavailable" ? nil : state == "processing"
                            ? [PickyAsyncTaskShelfFixtures.ticket(root, state: .processing)] : []
                        let store = PickySessionStore(sessionID: card.id)
                        store.replace(card: card)
                        let model = PickySessionListViewModel(client: FakePickyAgentClient())
                        let appearance: NSAppearance.Name = light ? .aqua : .darkAqua
                        let name = "mounted-\(state)-\(light ? "light" : "dark")-\(Int(scale * 100)).png"
                        let view = PickyConversationCardView(viewModel: model, sessionStore: store,
                            maxHeight: state == "short" ? 320 : 640, width: 420,
                            fixedHeight: state == "short" ? 320 : 640)
                            .environment(\.pickyAppFontScale, scale)
                            .environment(\.locale, Locale(identifier: scale == 1.3 ? "ko" : "en"))
                            .environment(\.colorScheme, light ? .light : .dark)
                        let size = CGSize(width: 420, height: state == "short" ? 320 : 640)
                        let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size,
                            scale: 2, appearance: appearance))
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent(name), options: .atomic)
                        scenes.append(["file": name, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                            "logicalWidth": size.width, "logicalHeight": size.height])
                    }
                }
            }
        }
    }

    @MainActor private final class RowDisclosureModel: ObservableObject {
        @Published var expanded = false
    }

    private struct ControlledRowDisclosure: View {
        let root: PickyAsyncTask
        let child: PickyAsyncTask
        @ObservedObject var model: RowDisclosureModel

        var body: some View {
            PickyAsyncTaskShelfRowView(root: root, detail: .init(tasks: [root, child], tickets: []),
                summary: PickyAsyncTaskShelfFixtures.summary(), availability: .available, onAction: { _ in },
                expandedBinding: Binding(get: { model.expanded }, set: { model.expanded = $0 }))
        }
    }

    private func recent(_ task: PickyAsyncTask) -> PickyAsyncTask {
        var result = task
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 - 90)
        result.createdAt = start
        result.updatedAt = start.addingTimeInterval(90)
        return result
    }

    private func failedDelivery(for root: PickyAsyncTask) -> PickyCompletionTicket {
        var ticket = PickyAsyncTaskShelfFixtures.ticket(root, state: .failed)
        ticket.failureReason = "The provider rejected delivery after waiting for the result.\n" +
            "Inspect the complete response before retrying."
        return ticket
    }

    private func staleDetail(for root: PickyAsyncTask) -> PickyAsyncTaskDetail {
        var previous = root
        previous.execution = .running
        previous.presence = .active
        previous.providerRevision -= 1
        return PickyAsyncTaskDetail(tasks: [previous], tickets: [])
    }

    @ViewBuilder
    private func content(state: String, scale: Double) -> some View {
        let title = scale == 1.3 ? "한국어와日本語가 섞인 아주 긴 작업 제목으로 결과와 하위 작업 상태를 확인하고 변경 사항을 검증합니다" : "Run local checks"
        let root = recent(PickyAsyncTaskShelfFixtures.task("root", kind: state == "group" ? "subagent" : state == "unknown" ? "future-provider" : "bash", title: title,
            execution: state == "processing" ? .succeeded : state == "failure" ? .failed : .running,
            presence: state == "processing" || state == "failure" ? .settled : state == "unknown" ? .unknown : .active))
        let children = (1...8).map { recent(PickyAsyncTaskShelfFixtures.task("child-\($0)", root: "root", title: "Inspect module \($0)")) }
        let tasks = state == "multiple" ? [root] + (1...5).map { recent(PickyAsyncTaskShelfFixtures.task("task-\($0)", title: "Check package \($0)")) } : state == "group" || state == "expanded" ? [root] + children : [root]
        let tickets = state == "processing" ? [PickyAsyncTaskShelfFixtures.ticket(root, state: .processing)] :
            state == "failure" ? [failedDelivery(for: root)] : []
        let detail = PickyAsyncTaskDetail(tasks: tasks, tickets: tickets)
        let summary = PickyAsyncTaskShelfFixtures.summary(active: state == "multiple" ? 6 : state == "processing" || state == "failure" ? 0 : 1,
            pending: tickets.count, unknown: state == "unknown" ? 1 : 0, attention: state == "failure" ? 1 : 0,
            tracking: state == "reconciling" ? .reconciling : state == "unsupported" ? .unsupported : .ready)
        let availability: PickyAsyncTaskCancelAvailability = state == "failure" ? .failed(scale == 1.3
            ? "중지 요청이 거부됐어요.\n작업 상태와 제공자 응답을 확인한 뒤 다시 시도하세요."
            : "Stop request rejected.\nCheck the task and provider response before retrying.")
            : state == "unsupported" || state == "unknown" ? .unsupported : .available
        if state == "group" {
            PickyAsyncTaskShelfRowView(root: root, detail: detail, summary: summary,
                                      availability: availability, onAction: { _ in }, isExpanded: true)
        } else {
            // A fetched response predating the v2 processing state must never restore the old running status.
            PickyAsyncTaskShelfView(summary: summary, detailState: state == "reconciling" || state == "unsupported" ? .unavailable : .loaded(detail),
                                   initiallyExpanded: state == "multiple" && scale == 1.3,
                                   maxListHeight: state == "expanded" ? 120 : 200,
                                   initiallyExpandedRows: state == "expanded" || state == "failure",
                                   fetchedDetail: { _ in state == "processing" ? staleDetail(for: root) : nil },
                                   detailError: { _ in state == "expanded" ? "Provider details are temporarily unavailable.\nThe complete response is retained for inspection." : nil },
                                   cancelAvailability: { _ in availability }, onAction: { _ in })
        }
    }
}

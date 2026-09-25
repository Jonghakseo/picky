import AppKit
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
                for state in ["single", "multiple", "group", "processing", "failure", "reconciling", "unsupported", "unknown"] {
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
        let manifest: [String: Any] = ["schemaVersion": 1, "renderer": "production shelf / offscreen NSHostingView", "scenes": scenes]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        #expect(scenes.count == 32)
    }

    @ViewBuilder
    private func content(state: String, scale: Double) -> some View {
        let title = scale == 1.3 ? "한국어와日本語가 섞인 아주 긴 작업 제목으로 결과와 하위 작업 상태를 확인하고 변경 사항을 검증합니다" : "Run local checks"
        let root = PickyAsyncTaskShelfFixtures.task("root", kind: state == "group" ? "subagent" : state == "unknown" ? "future-provider" : "bash", title: title,
            execution: state == "processing" ? .succeeded : state == "failure" ? .failed : .running,
            presence: state == "processing" || state == "failure" ? .settled : state == "unknown" ? .unknown : .active)
        let children = (1...4).map { PickyAsyncTaskShelfFixtures.task("child-\($0)", root: "root", title: "Inspect module \($0)") }
        let tasks = state == "multiple" ? [root] + (1...5).map { PickyAsyncTaskShelfFixtures.task("task-\($0)", title: "Check package \($0)") } : state == "group" ? [root] + children : [root]
        let tickets = state == "processing" ? [PickyAsyncTaskShelfFixtures.ticket(root, state: .processing)] :
            state == "failure" ? [PickyAsyncTaskShelfFixtures.ticket(root, state: .failed)] : []
        let detail = PickyAsyncTaskDetail(tasks: tasks, tickets: tickets)
        let summary = PickyAsyncTaskShelfFixtures.summary(active: state == "multiple" ? 6 : state == "processing" || state == "failure" ? 0 : 1,
            pending: tickets.count, unknown: state == "unknown" ? 1 : 0, attention: state == "failure" ? 1 : 0,
            tracking: state == "reconciling" ? .reconciling : state == "unsupported" ? .unsupported : .ready)
        let availability: PickyAsyncTaskCancelAvailability = state == "failure" ? .failed(scale == 1.3 ? "중지 요청이 거부됐어요. 작업 상태를 다시 확인해 주세요." : "Stop request rejected. Check the task status.") : state == "unsupported" || state == "unknown" ? .unsupported : .available
        if state == "group" {
            PickyAsyncTaskShelfRowView(root: root, detail: detail, summary: summary,
                                      availability: availability, onAction: { _ in }, isExpanded: true)
        } else {
            PickyAsyncTaskShelfView(summary: summary, detailState: state == "reconciling" || state == "unsupported" ? .unavailable : .loaded(detail),
                                   initiallyExpanded: state == "multiple" && scale == 1.3,
                                   cancelAvailability: { _ in availability }, onAction: { _ in })
        }
    }
}

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyToolHistoryRenderGalleryTests {
    private static let outputRequestFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("build/render-gallery/.tool-history-output-path")
    private static let width: CGFloat = 780
    private static let scale: CGFloat = 2

    private struct Row: Identifiable {
        let entry: PickyToolHistoryEntry
        let expanded: Bool
        let result: PickyToolHistoryDetailModel
        let arguments: PickyToolHistoryDetailModel
        var id: String { entry.id }
    }

    private struct ManifestScene: Encodable {
        let file: String
        let appearance: String
        let logicalWidth: Double
        let logicalHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct Manifest: Encodable {
        let schemaVersion = 1
        let renderer = "offscreen NSHostingView bitmap cache"
        let scale = 2
        let scenes: [ManifestScene]
    }

    @Test func writesToolHistoryGalleryWhenOutputDirectoryIsRequested() async throws {
        guard let rawOutput = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !rawOutput.isEmpty
        else { return }
        let output = URL(fileURLWithPath: rawOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var scenes: [ManifestScene] = []
        for dark in [true, false] {
            // Each render owns fresh models; disappearing hosts cancel their detail requests.
            let rows = await makeRows()
            for row in rows where row.expanded {
                #expect(row.result.state == .ready)
                #expect(row.arguments.state == .ready)
            }
            let scene = try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
                try render(rows: rows, dark: dark, output: output)
            }
            scenes.append(scene)
            let windowRows = await makeRows()
            let windowScene = try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
                try render(rows: windowRows, dark: dark, output: output, wholeWindow: true)
            }
            scenes.append(windowScene)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(scenes: scenes)).write(
            to: output.appendingPathComponent("manifest.json"), options: .atomic
        )
    }

    private func makeRows() async -> [Row] {
        let fixtures: [(name: String, args: String, result: String, structured: String?, expanded: Bool, failed: Bool)] = [
            ("read", #"{"path":"Picky/HUD/PickyToolHistoryViewer.swift"}"#,
             "import SwiftUI", nil, false, false),
            ("edit", #"{"path":"Picky/HUD/PickyToolHistoryViewer.swift","oldText":"let showsDetails = false","newText":"let showsDetails = true"}"#,
             "Successfully replaced text in Picky/HUD/PickyToolHistoryViewer.swift.", nil, true, false),
            ("write", #"{"path":"Picky/HUD/HistoryStyle.swift","content":"struct HistoryStyle {\n    let rowHeight = 34\n    let showsStatus = true\n}"}"#,
             "Successfully wrote Picky/HUD/HistoryStyle.swift.", nil, true, false),
            ("todo_write", #"{"todos":[{"id":"inspect","content":"기존 도구 기록 확인","status":"completed"},{"id":"render","content":"원본 인자와 결과 표시","status":"in_progress"},{"id":"verify","content":"라이트·다크 화면 검증","status":"pending"}]}"#,
             "Updated 3 tasks.", nil, true, false),
            ("ask_user_question", #"{"questions":[{"id":"q1","type":"radio","prompt":"도구 기록을 어떻게 표시할까요?","options":[{"value":"list","label":"간결한 목록"},{"value":"cards","label":"카드"}]},{"id":"q2","type":"checkbox","prompt":"함께 표시할 정보는 무엇인가요?","options":[{"value":"time","label":"실행 시간"},{"value":"status","label":"완료 상태"}]}]}"#,
             "User submitted answers.", #"{"value":{"q1":"list","q2":["time","status"]},"cancelled":false}"#, true, false),
            ("bash", #"{"command":"pnpm test","title":"테스트 실행"}"#,
             "Error: test command exited with code 1.", nil, true, true),
        ]
        var rows: [Row] = []
        for (index, fixture) in fixtures.enumerated() {
            let id = "gallery-tool-\(index)"
            let entry = PickyToolHistoryRenderer.entry(from: PickyToolActivity(
                toolCallId: id, name: fixture.name, status: fixture.failed ? "failed" : "succeeded",
                argsPreview: fixture.args, resultPreview: fixture.result
            ), index: index)
            let loader: @MainActor (PickyToolHistoryDetailPart, String?) async throws -> PickyToolHistoryDetailResult = { part, _ in
                PickyToolHistoryDetailResult(
                    sessionId: "gallery", requestId: "gallery-\(id)-\(part.rawValue)",
                    toolCallId: id, expectedSessionFile: "/gallery/session.jsonl",
                    part: part, status: .ready,
                    text: part == .arguments ? fixture.args : fixture.result,
                    structuredResult: part == .result ? fixture.structured : nil
                )
            }
            let result = PickyToolHistoryDetailModel(toolName: fixture.name, loadsAllPages: true, loader: loader)
            let arguments = PickyToolHistoryDetailModel(toolName: fixture.name, loadsAllPages: true, loader: loader)
            await result.load(part: .result).value
            await arguments.load(part: .arguments).value
            rows.append(Row(entry: entry, expanded: fixture.expanded, result: result, arguments: arguments))
        }
        return rows
    }

    private func render(rows: [Row], dark: Bool, output: URL, wholeWindow: Bool = false) throws -> ManifestScene {
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        let name = "compact-tool-history-\(wholeWindow ? "window-" : "")\(dark ? "dark" : "light").png"
        let fontStore = PickyAppFontScaleStore()
        let tools = rows.map { row in
            PickyToolActivity(toolCallId: row.entry.id, name: row.entry.name,
                status: row.entry.status == .failed ? "failed" : "succeeded",
                argsPreview: row.arguments.text, resultPreview: row.result.text)
        }
        let snapshot = PickyToolHistorySnapshot(tools: tools, sessionFilePath: "/gallery/session.jsonl", workingDirectory: "/gallery/project")
        let model = PickyToolHistoryViewerModel(title: "도구 히스토리 · 원본 결과 표시 개선", snapshot: snapshot,
            scope: .dateRange(start: nil, end: nil), refresh: { snapshot }) { _, _, part, _ in
                PickyToolHistoryDetailResult(sessionId: "gallery", requestId: "unused", toolCallId: "unused", expectedSessionFile: "/gallery/session.jsonl", part: part, status: .unavailable)
            }
        let root = AnyView(
            PickyAppFontScaleRoot(store: fontStore) {
                Group {
                if wholeWindow {
                    PickyToolHistoryViewerWindowView(model: model).frame(height: 330)
                } else {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    ForEach(rows) { row in
                        PickyToolHistoryEntryView(
                            entry: row.entry, workingDirectory: "/gallery/project",
                            initiallyExpanded: row.expanded,
                            initialDetail: row.result, initialArguments: row.arguments
                        )
                    }
                }
                .padding(DS.Spacing.space3)
                }
                }
                .frame(width: Self.width, alignment: .leading)
                .background(DS.Colors.surface1)
                .environment(\.locale, Locale(identifier: "ko_KR"))
                .preferredColorScheme(dark ? .dark : .light)
                .fixedSize(horizontal: false, vertical: true)
            }
        )
        let measuringHost = NSHostingView(rootView: root)
        // Retain this host through rasterization so disappearance cannot clear preloaded models.
        defer { measuringHost.rootView = AnyView(EmptyView()) }
        measuringHost.appearance = NSAppearance(named: appearance)
        measuringHost.layoutSubtreeIfNeeded()
        let measured = measuringHost.fittingSize
        guard measured.width > 0, measured.height > 0 else { throw RenderError.emptyLogicalSize }
        let size = CGSize(width: Self.width, height: ceil(measured.height * Self.scale) / Self.scale)
        guard let bitmap = PickyRenderGalleryRasterizer.rasterize(
            root, logicalSize: size, scale: Self.scale, appearance: appearance
        ) else { throw RenderError.bitmapCreationFailed }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }
        let file = output.appendingPathComponent(name)
        try png.write(to: file, options: .atomic)
        let saved = try Data(contentsOf: file)
        #expect(!saved.isEmpty)
        let decoded = try #require(NSBitmapImageRep(data: saved))
        #expect(decoded.pixelsWide == Int(Self.width * Self.scale))
        #expect(decoded.pixelsHigh == Int(size.height * Self.scale))
        #expect(decoded.pixelsHigh > 0)
        return ManifestScene(
            file: name, appearance: dark ? "dark" : "light",
            logicalWidth: Double(size.width), logicalHeight: Double(size.height),
            pixelWidth: decoded.pixelsWide, pixelHeight: decoded.pixelsHigh
        )
    }

    private enum RenderError: Error {
        case emptyLogicalSize
        case bitmapCreationFailed
        case pngEncodingFailed
    }
}

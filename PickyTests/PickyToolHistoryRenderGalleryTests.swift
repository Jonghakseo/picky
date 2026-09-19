import AppKit
import SwiftUI
import Testing
import Vision
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

    @Test func storedPreviewsRemainVisibleWhenOriginalsCannotBeLoaded() async throws {
        for unsupported in [true, false] {
            for dark in [false, true] {
                let id = unsupported ? "user-bash:preview" : "missing-original"
                let text = unsupported ? "Saved shell output survives" : "Saved tool output survives"
                let tool = PickyToolActivity(
                    toolCallId: id, name: "bash", status: "succeeded",
                    argsPreview: #"{"command":"echo saved"}"#, resultPreview: text,
                    resultPreviewTruncated: unsupported
                )
                // Missing session files take the production viewer's unavailable path;
                // user-bash calls receive the daemon's unsupported response.
                let snapshot = PickyToolHistorySnapshot(
                    tools: [tool], sessionFilePath: unsupported ? "/gallery/session.jsonl" : nil
                )
                let history = PickyToolHistoryViewerModel(
                    title: "History", snapshot: snapshot, scope: .session, refresh: { snapshot },
                    detailLoader: { id, file, part, _ in
                        #expect(id.hasPrefix("user-bash:"))
                        return PickyToolHistoryDetailResult(
                            sessionId: "gallery", requestId: "preview", toolCallId: id,
                            expectedSessionFile: file, part: part, status: .unsupported
                        )
                    }
                )
                let result = try #require(history.inlineDetail(toolCallID: id))
                let arguments = try #require(history.inlineArguments(toolCallID: id))
                await result.load(part: .result).value
                await arguments.load(part: .arguments).value
                #expect(result.state == (unsupported ? .unsupported : .unavailable))
                let entry = PickyToolHistoryRenderer.entry(from: tool, index: 0)
                try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
                    let view = PickyToolHistoryEntryView(
                        entry: entry, initiallyExpanded: true, initialDetail: result, initialArguments: arguments
                    )
                    .padding(DS.Spacing.space3)
                    .frame(width: Self.width, height: 260, alignment: .topLeading)
                    .background(DS.Colors.surface1)
                    .preferredColorScheme(dark ? .dark : .light)
                    let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(
                        view, logicalSize: CGSize(width: Self.width, height: 260), scale: Self.scale,
                        appearance: dark ? .darkAqua : .aqua
                    ))
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    #expect(lines.contains { $0.localizedCaseInsensitiveContains(text) },
                            "Stored output must be rendered: \(lines)")
                    #expect(lines.contains { $0.contains("Stored preview") }, "Preview must be labeled: \(lines)")
                    #expect(lines.contains { $0.contains(unsupported ? "truncated" : "may not include") },
                            "Preview completeness must be explicit: \(lines)")
                    if let path = try? String(contentsOf: Self.outputRequestFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                        let state = unsupported ? "unsupported" : "unavailable"
                        let name = "stored-preview-\(state)-\(dark ? "dark" : "light").png"
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
                    }
                }
            }
        }
    }

    private struct ToolHistoryFixture {
        let name: String
        let args: String
        let result: String
        let structured: String?
        let expanded: Bool
        let failed: Bool
    }

    private func makeRows() async -> [Row] {
        let fixtures: [ToolHistoryFixture] = [
            ToolHistoryFixture(name: "read", args: #"{"path":"Picky/HUD/PickyToolHistoryViewer.swift"}"#,
             result: "import SwiftUI", structured: nil, expanded: false, failed: false),
            ToolHistoryFixture(name: "edit", args: #"{"path":"Picky/HUD/PickyToolHistoryViewer.swift","oldText":"let showsDetails = false","newText":"let showsDetails = true"}"#,
             result: "Successfully replaced text in Picky/HUD/PickyToolHistoryViewer.swift.", structured: nil, expanded: true, failed: false),
            ToolHistoryFixture(name: "write", args: #"{"path":"Picky/HUD/HistoryStyle.swift","content":"struct HistoryStyle {\n    let rowHeight = 34\n    let showsStatus = true\n}"}"#,
             result: "Successfully wrote Picky/HUD/HistoryStyle.swift.", structured: nil, expanded: true, failed: false),
            ToolHistoryFixture(name: "todo_write", args: #"{"todos":[{"id":"inspect","content":"기존 도구 기록 확인","status":"completed"},{"id":"render","content":"원본 인자와 결과 표시","status":"in_progress"},{"id":"verify","content":"라이트·다크 화면 검증","status":"pending"}]}"#,
             result: "Updated 3 tasks.", structured: nil, expanded: true, failed: false),
            ToolHistoryFixture(name: "ask_user_question", args: #"{"questions":[{"id":"q1","type":"radio","prompt":"도구 기록을 어떻게 표시할까요?","options":[{"value":"list","label":"간결한 목록"},{"value":"cards","label":"카드"}]},{"id":"q2","type":"checkbox","prompt":"함께 표시할 정보는 무엇인가요?","options":[{"value":"time","label":"실행 시간"},{"value":"status","label":"완료 상태"}]}]}"#,
             result: "User submitted answers.", structured: #"{"value":{"q1":"list","q2":["time","status"]},"cancelled":false}"#, expanded: true, failed: false),
            ToolHistoryFixture(name: "bash", args: #"{"command":"pnpm test","title":"테스트 실행"}"#,
             result: "Error: test command exited with code 1.", structured: nil, expanded: true, failed: true),
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

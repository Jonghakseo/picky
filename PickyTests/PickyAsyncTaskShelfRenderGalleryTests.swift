import AppKit
import Combine
import SwiftUI
import Testing
import Vision
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
        try renderReviewScenes(into: output, scenes: &scenes)
        let manifest: [String: Any] = ["schemaVersion": 1, "renderer": "production shelf, mounted conversation and archive / offscreen NSHostingView", "scenes": scenes]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        #expect(scenes.count == 80)
    }

    @Test func emptyNewAndReenteredPicklesNeverMountLoadingShelfButRealWorkAndUncertaintyDo() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let commands = PickySessionListViewModel(client: FakePickyAgentClient())
        var session = PickyAgentSession(id: "session", title: "New Pickle", status: .waiting_for_input,
            cwd: "/tmp/project", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), logs: [], tools: [], artifacts: [], changedFiles: [])
        session.asyncTasks = []
        session.completionTickets = []
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, tracking: .reconciling)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let store = storage.registry.sessionStore(sessionID: "session")
        let full = NSHostingView(rootView: PickyMountedAsyncTaskShelfView(store: store, commands: commands,
            maxListHeight: 160, bottomSpacing: DS.Spacing.space2).frame(width: 380))
        let compact = NSHostingView(rootView: PickyMountedAsyncTaskShelfView(store: store, commands: commands,
            maxListHeight: 160, compact: true, bottomSpacing: DS.Spacing.space2).frame(width: 380))

        func install(_ revision: Int, omitted: [String] = []) throws {
            let projection = try JSONSerialization.jsonObject(with: encoder.encode(session))
            let data = try JSONSerialization.data(withJSONObject: ["sessionId": "session", "epoch": "epoch",
                "revision": revision, "complete": omitted.isEmpty, "omittedFields": omitted, "projection": projection])
            let snapshot = try JSONDecoder.pickyAgentProtocolDecoder()
                .decode(PickySessionProjectionSnapshot.self, from: data)
            #expect(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
            full.layoutSubtreeIfNeeded()
            compact.layoutSubtreeIfNeeded()
        }
        func heights() -> [CGFloat] {
            full.rootView = PickyMountedAsyncTaskShelfView(store: store, commands: commands,
                maxListHeight: 160, bottomSpacing: DS.Spacing.space2).frame(width: 380)
            compact.rootView = PickyMountedAsyncTaskShelfView(store: store, commands: commands,
                maxListHeight: 160, compact: true, bottomSpacing: DS.Spacing.space2).frame(width: 380)
            full.layoutSubtreeIfNeeded()
            compact.layoutSubtreeIfNeeded()
            return [full.fittingSize.height, compact.fittingSize.height]
        }
        try install(1)
        let initialHeights = heights()
        print("mounted empty initial full/compact heights: \(initialHeights)")
        #expect(initialHeights.allSatisfy { $0 == 0 }, "No blank band before the first instruction")
        try install(2)
        let negotiatingHeights = heights()
        print("mounted empty negotiating full/compact heights: \(negotiatingHeights)")
        #expect(negotiatingHeights.allSatisfy { $0 == 0 }, "Provider negotiation must not shift the composer")
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0)
        try install(3)
        let readyHeights = heights()
        print("mounted empty ready full/compact heights: \(readyHeights)")
        #expect(readyHeights.allSatisfy { $0 == 0 }, "Ready empty session remains absent")
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, tracking: .unsupported)
        try install(4)
        #expect(heights().allSatisfy { $0 == 0 }, "Unsupported tracking without work needs no empty shelf")

        // An existing Pickle has a settled cycle and a last request. Re-entry first omits
        // detail, then hydrates settled history, before new background work appears.
        session.agentCycle = .init(cycleId: "previous", runtimeInstanceId: "runtime",
            phase: .settled, outcome: .completed, controlGeneration: 1)
        session.lastRequest = .init(source: .followUp, text: "Earlier request")
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, tracking: .reconciling)
        try install(5, omitted: ["asyncTasks", "completionTickets"])
        #expect(heights().allSatisfy { $0 == 0 }, "Re-entry with omitted detail must not shift the composer")
        let old = PickyAsyncTaskShelfFixtures.task("old", execution: .succeeded, presence: .settled)
        session.asyncTasks = [old]
        try install(6)
        #expect(heights().allSatisfy { $0 == 0 }, "Hydrated settled history must not create an empty header")
        session.asyncTasks = []
        try install(7)
        #expect(heights().allSatisfy { $0 == 0 }, "Loaded empty detail stays quiet during reconciliation")

        session.status = .running
        session.asyncTasks = [PickyAsyncTaskShelfFixtures.task("root")]
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 1, tracking: .reconciling)
        try install(8)
        let workHeights = heights()
        print("mounted real work full/compact heights: \(workHeights)")
        #expect(workHeights.allSatisfy { $0 >= 28 }, "Real work remains visible during negotiation")
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for compact in [false, true] {
                let view = PickyMountedAsyncTaskShelfView(store: store, commands: commands,
                    maxListHeight: 160, compact: compact, bottomSpacing: DS.Spacing.space2)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(width: 380)
                let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                    logicalSize: CGSize(width: 380, height: workHeights[compact ? 1 : 0]),
                    scale: 2, appearance: .aqua))
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                recognition.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                #expect(!lines.contains { $0.localizedCaseInsensitiveContains("Checking task status") }, "\(lines)")
                if !compact { #expect(lines.contains { $0.contains("Run local checks") }, "\(lines)") }
            }
        }
        session.status = .blocked
        session.asyncTasks?[0].presence = .unknown
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, unknown: 1, tracking: .reconciling)
        try install(9)
        #expect(heights().allSatisfy { $0 >= 28 }, "Unknown execution remains visible")
        session.asyncTasks?[0].presence = .settled
        session.asyncTasks?[0].execution = .failed
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, attention: 1)
        try install(10)
        #expect(heights().allSatisfy { $0 >= 28 }, "Attention remains visible")
        session.asyncTasks = nil
        session.completionTickets = nil
        try install(11, omitted: ["asyncTasks", "completionTickets"])
        #expect(heights().allSatisfy { $0 >= 28 }, "Canonical attention remains visible without detail")
    }

    @Test func focusedExpandedTaskRendersOnceWithNoIdleRefreshControl() throws {
        let outputRequest = request.deletingLastPathComponent()
            .appendingPathComponent(".async-tasks-focused-output-path")
        let path = try? String(contentsOf: outputRequest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let title = "Run 100-second dummy task"
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for light in [false, true] {
                for state in ["simple", "long", "failure", "unknown", "attention"] {
                    var root = recent(PickyAsyncTaskShelfFixtures.task("root", title: state == "long"
                        ? "Run 100-second dummy task and inspect every step of the long output without losing the full title"
                        : title, execution: state == "attention" ? .failed : .running,
                        presence: state == "unknown" ? .unknown : state == "attention" ? .settled : .active))
                    if state == "long" { root.details = ["report": .string("Full provider note retained")] }
                    let summary = PickyAsyncTaskShelfFixtures.summary(active: state == "attention" ? 0 : 1,
                        unknown: state == "unknown" ? 1 : 0, attention: state == "attention" ? 1 : 0)
                    let detail = PickyAsyncTaskDetail(tasks: [root], tickets: [])
                    let view = PickyAsyncTaskShelfView(summary: summary, detailState: .loaded(detail),
                        initiallyExpandedRows: true,
                        detailError: { _ in state == "failure" ? "Provider refused the detail request." : nil },
                        cancelAvailability: { _ in .available }, onAction: { _ in })
                        .environment(\.pickyAppFontScale, state == "long" ? 1.3 : 1)
                        .environment(\.locale, Locale(identifier: "en"))
                        .environment(\.colorScheme, light ? .light : .dark)
                        .frame(width: 420).padding(DS.Spacing.space3).background(DS.Colors.background)
                    let appearance: NSAppearance.Name = light ? .aqua : .darkAqua
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: appearance)
                    host.layoutSubtreeIfNeeded()
                    let size = host.fittingSize
                    #expect(size.height > 0)
                    let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                        logicalSize: size, scale: 2, appearance: appearance))
                    if state == "simple" || state == "failure" {
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                        let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        #expect(lines.filter { $0.contains(title) }.count == 1,
                            "The expanded task has one visible title: \(lines)")
                        if state == "failure" {
                            #expect(lines.contains { $0.localizedCaseInsensitiveContains("Retry loading details") },
                                "A failed fetch offers a labeled retry: \(lines)")
                        }
                    }
                    if let output {
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: output.appendingPathComponent("focused-\(state)-\(light ? "light" : "dark").png"))
                    }
                }
            }
        }
    }

    @Test func mountedRegistrationStopAndUnresolvedControlRenderOneClearStatus() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let store = storage.registry.sessionStore(sessionID: "session")
        let commands = PickySessionListViewModel(client: FakePickyAgentClient())
        var session = PickyAgentSession(id: "session", title: "Background control", status: .running,
            cwd: "/tmp/project", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), logs: [], tools: [], artifacts: [], changedFiles: [])
        let first = recent(PickyAsyncTaskShelfFixtures.task("first", title: "First root"))
        let second = recent(PickyAsyncTaskShelfFixtures.task("second", title: "Second root"))
        var registering = recent(PickyAsyncTaskShelfFixtures.task("third", title: "New root",
            execution: .queued, presence: .unknown))
        registering.registration = .approved
        session.asyncTasks = [first, second, registering]
        session.completionTickets = []
        session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 3)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let outputRequest = request.deletingLastPathComponent()
            .appendingPathComponent(".async-tasks-focused-output-path")
        let path = try? String(contentsOf: outputRequest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for (index, state) in ["registering", "reconciling-grant", "uncertain-grant",
                                   "older-owner-grant", "stopping", "unresolved"].enumerated() {
                if state == "registering" {
                    session.agentCycle = .init(cycleId: "cycle", runtimeInstanceId: "runtime",
                        phase: .idle, outcome: nil, controlGeneration: 1)
                } else if state == "reconciling-grant" || state == "uncertain-grant" || state == "older-owner-grant" {
                    session.asyncTasks = [registering]
                    session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 1, unknown: 1,
                        tracking: state == "reconciling-grant" ? .reconciling : .ready)
                    session.agentCycle?.runtimeInstanceId = state == "older-owner-grant" ? "new-runtime" : "runtime"
                } else if state == "stopping" {
                    session.asyncTasks = [first, second].map { task in
                        var task = task
                        task.execution = .cancelling
                        return task
                    }
                    session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 2)
                } else if state == "unresolved" {
                    session.status = .blocked
                    session.asyncTasks = []
                    session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, attention: 1)
                    session.asyncControl = PickyAsyncControlState(controlGeneration: 2, admissionState: .closed,
                        operations: [.init(requestId: "stop", operationId: "stop", outcome: .blocked_cleanup,
                            controlGeneration: 2, reason: "Cleanup confirmation timed out")], releasePrepared: nil)
                }
                let projection = try JSONSerialization.jsonObject(with: encoder.encode(session))
                let data = try JSONSerialization.data(withJSONObject: ["sessionId": "session", "epoch": "epoch",
                    "revision": index + 1, "complete": true, "omittedFields": [String](), "projection": projection])
                let snapshot = try JSONDecoder.pickyAgentProtocolDecoder()
                    .decode(PickySessionProjectionSnapshot.self, from: data)
                #expect(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
                guard case .loaded(let metadata) = store.metaStore.metadataState else {
                    Issue.record("Mounted metadata was not projected")
                    return
                }
                let summary = try #require(metadata.asyncWorkSummary)
                let detail = store.asyncTaskStore.detailState
                if state == "registering", case .loaded(let value) = detail {
                    #expect(PickyAsyncTaskShelfPresentation.roots(in: value).count == 3)
                    #expect(PickyAsyncTaskShelfPresentation.primaryStateKey(value.tasks[2], tickets: [],
                        summary: summary, runtimeInstanceId: metadata.agentCycle?.runtimeInstanceId)
                        == "hud.asyncTasks.execution.queued")
                }
                if state.hasSuffix("grant"), case .loaded(let value) = detail {
                    #expect(value.tasks[0].registration == .approved && value.tasks[0].execution == .queued
                        && value.tasks[0].presence == .unknown)
                    #expect(PickyAsyncTaskShelfPresentation.primaryStateKey(value.tasks[0], tickets: [],
                        summary: summary, runtimeInstanceId: metadata.agentCycle?.runtimeInstanceId)
                        == "hud.asyncTasks.execution.unknown")
                }
                if state == "stopping", case .loaded(let value) = detail {
                    #expect(PickyAsyncTaskShelfPresentation.roots(in: value).count == 2)
                    #expect(value.tasks.allSatisfy { PickyAsyncTaskShelfPresentation.executionKey($0, summary: summary)
                        == "hud.asyncTasks.execution.cancelling" })
                }
                if state == "unresolved" {
                    #expect(PickyAsyncTaskShelfPresentation.hasUnresolvedControl(summary: summary, detail: detail,
                        control: store.asyncTaskStore.controlState))
                }
                for light in [false, true] {
                    let appearance: NSAppearance.Name = light ? .aqua : .darkAqua
                    for compact in [false, true] {
                        let view = PickyMountedAsyncTaskShelfView(store: store, commands: commands,
                            maxListHeight: 200, compact: compact,
                            stopError: state == "unresolved" ? "Cleanup confirmation timed out" : nil)
                            .environment(\.colorScheme, light ? .light : .dark)
                            .frame(width: 420).padding(DS.Spacing.space3).background(DS.Colors.background)
                        let host = NSHostingView(rootView: view)
                        host.appearance = NSAppearance(named: appearance)
                        host.layoutSubtreeIfNeeded()
                        let size = host.fittingSize
                        #expect(size.height > 0)
                        let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                            logicalSize: size, scale: 2, appearance: appearance))
                        if let output {
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                                output.appendingPathComponent("control-\(state)-\(compact ? "compact" : "full")-\(light ? "light" : "dark").png"))
                        }
                        guard !compact else { continue } // Popover shares the full shelf component.
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                        let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        print("control \(state) \(light ? "light" : "dark") \(size): \(lines)")
                        if state == "registering" {
                            #expect(lines.contains { $0.contains("New root") })
                            #expect(lines.contains { $0.contains("Queued") })
                            #expect(!lines.contains { $0.contains("Unknown") || $0.contains("Needs attention") })
                        } else if state.hasSuffix("grant") {
                            #expect(lines.contains { $0.contains("New root") })
                            #expect(lines.contains { $0.contains("Unknown") })
                            #expect(!lines.contains { $0.contains("Queued") })
                        } else if state == "stopping" {
                            #expect(lines.filter { $0.contains("Stopping") }.count == 2)
                            #expect(!lines.contains { $0.contains("Needs attention") })
                        } else {
                            #expect(lines.filter { $0.contains("Could not complete") }.count == 1)
                            #expect(lines.contains { $0.contains("Cleanup confirmation timed out") })
                            #expect(!lines.contains { $0.contains("No task rows") || $0.contains("Needs attention") })
                        }
                    }
                }
            }
        }
    }

    @Test func archivedListShowsOnlyIdentityAndActionsDespiteRetainedWork() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let commands = PickySessionListViewModel(client: FakePickyAgentClient())
        var session = PickyAgentSession(id: "session", title: "Archived Pickle", status: .completed,
            cwd: "/tmp/project", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), logs: [], tools: [], artifacts: [], changedFiles: [])
        session.archived = true
        session.completionTickets = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for (index, state) in ["active", "unknown", "settled"].enumerated() {
                var summary = PickyAsyncTaskShelfFixtures.summary(active: state == "active" ? 1 : 0,
                    unknown: state == "unknown" ? 1 : 0)
                summary.canReleaseRuntime = state == "settled"
                session.asyncWorkSummary = summary
                var task = PickyAsyncTaskShelfFixtures.task("root", title: "TECHNICAL TASK TITLE",
                    execution: state == "settled" ? .cancelled : .running,
                    presence: state == "settled" ? .settled : state == "unknown" ? .unknown : .active)
                task.progress = "TECHNICAL PROGRESS"
                session.asyncTasks = [task]
                session.asyncControl = state == "settled" ? nil : .init(controlGeneration: 2, admissionState: .closed,
                    operations: [.init(requestId: "stop", operationId: "stop", outcome: .blocked_cleanup,
                        controlGeneration: 2, reason: "async_request_identity_conflict")], releasePrepared: nil)
                let projection = try JSONSerialization.jsonObject(with: encoder.encode(session))
                let data = try JSONSerialization.data(withJSONObject: ["sessionId": "session", "epoch": "epoch",
                    "revision": index + 1, "complete": true, "omittedFields": [String](), "projection": projection])
                let snapshot = try JSONDecoder.pickyAgentProtocolDecoder()
                    .decode(PickySessionProjectionSnapshot.self, from: data)
                #expect(storage.applyProjectionSnapshot(snapshot, archived: true) != nil)
                let store = try #require(storage.registry.existingSessionStore(sessionID: "session"))
                guard case .loaded = store.metaStore.metadataState else {
                    Issue.record("Archived metadata was not projected for \(state)")
                    return
                }
                let view = PickyHUDArchivedSessionsListView(archiveMembership: storage.registry, commands: commands)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.colorScheme, .light).frame(width: 420, height: 230)
                    .background(DS.Colors.background)
                let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                    logicalSize: CGSize(width: 420, height: 230), scale: 2, appearance: .aqua))
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                recognition.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: " ")
                #expect(text.contains("Archived Pickle") && text.contains("project"), "\(state): \(lines)")
                #expect(text.contains("Restore") && text.contains("Delete"), "\(state): \(lines)")
                #expect(!text.contains("TECHNICAL") && !text.contains("async_request_identity_conflict")
                    && !text.contains("Stop") && !text.contains("Archived work"), "\(state): \(lines)")
            }
        }
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
                        id: "session", title: "보관된 피클 / Archived Pickle", status: .running, cwd: "/tmp/project",
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

    private func renderReviewScenes(into output: URL, scenes: inout [[String: Any]]) throws {
        for light in [false, true] {
            for scale in [1.0, 1.3] {
                try LocaleManager.shared.withTemporaryChoiceForTesting(scale == 1.3 ? .korean : .english) {
                    let appearance: NSAppearance.Name = light ? .aqua : .darkAqua
                    let states = ["fresh-failure-child", "delivery-no-reason",
                                  "delivery-unknown-no-reason", "delivery-resolved-reason"]
                    for state in states {
                        var root = PickyAsyncTaskShelfFixtures.task("root", title: "Run local checks",
                            execution: state == "fresh-failure-child" ? .failed : .succeeded, presence: .settled)
                        root.createdAt = Date().addingTimeInterval(-35)
                        root.updatedAt = Date().addingTimeInterval(-25)
                        let child = PickyAsyncTaskShelfFixtures.task("child", root: root.taskId,
                            title: "Surviving child")
                        var ticket = PickyAsyncTaskShelfFixtures.ticket(root,
                            state: state == "delivery-unknown-no-reason" ? .unknown :
                                state == "delivery-resolved-reason" ? .handled : .failed)
                        ticket.failureReason = state == "delivery-resolved-reason"
                            ? "Previous failure already resolved." : nil
                        let detail = PickyAsyncTaskDetail(
                            tasks: state == "fresh-failure-child" ? [root, child] : [root],
                            tickets: state == "fresh-failure-child" ? [] : [ticket])
                        let summary = PickyAsyncTaskShelfFixtures.summary(
                            active: state == "fresh-failure-child" ? 1 : 0,
                            attention: state == "delivery-resolved-reason" ? 0 : 1)
                        let view = PickyAsyncTaskShelfView(summary: summary, detailState: .loaded(detail),
                            initiallyExpandedRows: state == "fresh-failure-child",
                            cancelAvailability: { _ in .available }, onAction: { _ in })
                            .environment(\.pickyAppFontScale, scale)
                            .environment(\.colorScheme, light ? .light : .dark)
                            .frame(width: 420).padding(DS.Spacing.space3).background(DS.Colors.background)
                        let host = NSHostingView(rootView: view)
                        host.appearance = NSAppearance(named: appearance)
                        host.layoutSubtreeIfNeeded()
                        let size = host.fittingSize
                        #expect(size.height > 0)
                        let name = "review-\(state)-\(light ? "light" : "dark")-\(Int(scale * 100)).png"
                        let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                            logicalSize: size, scale: 2, appearance: appearance))
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent(name), options: .atomic)
                        scenes.append(["file": name, "pixelWidth": bitmap.pixelsWide,
                            "pixelHeight": bitmap.pixelsHigh, "logicalWidth": size.width, "logicalHeight": size.height])
                    }
                    let storage = PickyRegistrySessionProjectionStorage()
                    var archived = PickyAgentSession(id: "attention", title: "Archived failure", status: .completed,
                        cwd: "/tmp/project", createdAt: Date(), updatedAt: Date(), logs: [], tools: [],
                        artifacts: [], changedFiles: [])
                    archived.archived = true
                    archived.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, attention: 1)
                    var failed = PickyAsyncTaskShelfFixtures.task("failed", execution: .failed, presence: .settled)
                    failed.sessionId = "attention"
                    archived.asyncTasks = [failed]
                    archived.completionTickets = []
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let projection = try JSONSerialization.jsonObject(with: encoder.encode(archived))
                    let data = try JSONSerialization.data(withJSONObject: ["sessionId": "attention", "epoch": "epoch",
                        "revision": 1, "complete": true, "omittedFields": [String](), "projection": projection])
                    let snapshot = try JSONDecoder.pickyAgentProtocolDecoder()
                        .decode(PickySessionProjectionSnapshot.self, from: data)
                    #expect(storage.applyProjectionSnapshot(snapshot, archived: true) != nil)
                    #expect(storage.registry.archivedSessionIDs == ["attention"])
                    let store = try #require(storage.registry.existingSessionStore(sessionID: "attention"))
                    if case .loaded(let detail) = store.asyncTaskStore.detailState {
                        #expect(detail.tasks.first?.execution == .failed)
                    } else {
                        Issue.record("Archived v2 failure detail was not retained")
                    }
                    let model = PickySessionListViewModel(client: FakePickyAgentClient())
                    let view = PickyHUDArchivedDockAccessView(archiveMembership: storage.registry, commands: model)
                        .environment(\.pickyAppFontScale, scale)
                        .environment(\.colorScheme, light ? .light : .dark)
                        .frame(width: 80, height: 60).background(DS.Colors.background)
                    let name = "review-archived-attention-\(light ? "light" : "dark")-\(Int(scale * 100)).png"
                    let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(view,
                        logicalSize: CGSize(width: 80, height: 60), scale: 2, appearance: appearance))
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let empty = PickyHUDArchivedDockAccessView(
                        archiveMembership: PickySessionRegistry(), commands: model)
                        .environment(\.pickyAppFontScale, scale)
                        .environment(\.colorScheme, light ? .light : .dark)
                        .frame(width: 80, height: 60).background(DS.Colors.background)
                    let emptyBitmap = try #require(PickyRenderGalleryRasterizer.rasterize(empty,
                        logicalSize: CGSize(width: 80, height: 60), scale: 2, appearance: appearance))
                    #expect(png == emptyBitmap.representation(using: .png, properties: [:]),
                        "The archive entry stays quiet even when archived work needs attention")
                    try png.write(to: output.appendingPathComponent(name), options: .atomic)
                    scenes.append(["file": name, "pixelWidth": bitmap.pixelsWide,
                        "pixelHeight": bitmap.pixelsHigh, "logicalWidth": 80, "logicalHeight": 60])
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
            PickyAsyncTaskShelfView(summary: summary, detailState: state == "unsupported" ? .unavailable : .loaded(detail),
                                   initiallyExpanded: state == "multiple" && scale == 1.3,
                                   maxListHeight: state == "expanded" ? 120 : 200,
                                   initiallyExpandedRows: state == "expanded" || state == "failure",
                                   fetchedDetail: { _ in state == "processing" ? staleDetail(for: root) : nil },
                                   detailError: { _ in state == "expanded" ? "Provider details are temporarily unavailable.\nThe complete response is retained for inspection." : nil },
                                   cancelAvailability: { _ in availability }, onAction: { _ in })
        }
    }
}

import AppKit
import Combine
import SwiftUI
import Testing
import Vision
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyHubCalendarRenderTests {
    @Test func missingPluginShowsInstallationAndSidebarTitleOnOneLine() throws {
        let fixture = try PickyHubRenderGalleryFixture()
        defer { fixture.removeTemporaryState() }
        fixture.navigator.select(.calendar)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            for width in [760.0, 1020.0] {
                let view = PickyHubRootView(dependencies: fixture.dependencies, dockDisplayIDProvider: { nil })
                    .environmentObject(fixture.appearanceStore)
                    .environmentObject(fixture.hudVisibilityStore)
                    .environmentObject(fixture.updaterController)
                    .environmentObject(fixture.pluginReloadController)
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                let image = try rasterize(view, name: "hub-calendar-missing-\(Int(width))", width: width, height: 720)
                let lines = try recognizedLines(image)
                #expect(lines.contains { $0.contains("Cron 설치") }, "Missing plugin should offer installation: \(lines)")
                #expect(lines.contains { $0.contains("가이드 및 업데이트") }, "Sidebar title must be a single readable line: \(lines)")
            }
        }
    }

    @Test func firstWeekShowsAfternoonJobWithoutManualScrollInBothAppearances() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let now = day.addingTimeInterval(10 * 3600)
        let job = PickyCronJobPresentation(
            id: "afternoon", name: "Afternoon briefing", status: .active, enabled: true,
            schedule: nil, runAtText: nil, nextRunAt: day.addingTimeInterval(14.5 * 3600),
            lastRunAt: nil, completedAt: nil, lastExitCode: nil
        )
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for dark in [false, true] {
                let view = PickyHubCronCalendarView(jobs: [job], now: now)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .preferredColorScheme(dark ? .dark : .light)
                    .padding(20).background(PickyHubTheme.Colors.canvas)
                // Mount the production scroll view and wait for its actual content offset.
                // A static raster alone previously hid the broken initial-scroll behavior.
                let host = NSHostingView(rootView: AnyView(view))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close(); host.rootView = AnyView(EmptyView()) }
                let deadline = Date().addingTimeInterval(2)
                var moved = false
                repeat {
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    moved = scrollViews(host).contains { $0.contentView.bounds.origin.y > 400 }
                    if moved { break }
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                } while Date() < deadline
                #expect(moved, "The actual week viewport must leave midnight automatically")
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let lines = try recognizedLines(bitmap)
                #expect(lines.joined(separator: " ").contains("Afternoon briefing"), "Upcoming job must actually be visible, including a wrapped title: \(lines)")
                #expect(!lines.joined(separator: " ").contains("Recurring"))
                #expect(!lines.joined(separator: " ").contains("One-time"))
                try save(bitmap, name: "calendar-initial-\(dark ? "dark" : "light")")
            }
        }
    }

    @Test func detailsLeadWithInstructionsAndOmitExecutionMetadata() throws {
        let job = PickyCronJobPresentation(id: "daily", name: "Slack backup", status: .active, enabled: true,
            schedule: "30 10,20 * * *", runAtText: nil, nextRunAt: nil, lastRunAt: Date(), completedAt: nil, lastExitCode: 0)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let detail = PickyHubCronOccurrenceDetail(occurrence: .init(job: job, date: Date(), kind: .actual),
                prompt: .loaded("Back up my Slack messages.\nSave the archive to the project folder.\nReport any files that could not be saved."))
            let image = try rasterize(detail.environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.light).background(PickyHubTheme.Colors.canvas),
                name: "calendar-instructions", width: 440, height: 540)
            let lines = try recognizedLines(image)
            let text = lines.joined(separator: " ")
            #expect(text.contains("Back up my Slack messages"))
            #expect(text.contains("10:30, 20:30"))
            #expect(!text.contains("Asia/Seoul"))
            #expect(!text.contains("Last run"))
        }
    }

    @Test func monthAndNarrowAgendaKeepJobNamesReadable() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 9)))
        let job = PickyCronJobPresentation(id: "backup", name: "Backup documents", status: .active, enabled: true,
            schedule: nil, runAtText: nil, nextRunAt: now.addingTimeInterval(3600), lastRunAt: nil, completedAt: nil, lastExitCode: nil)
        var history = PickyCronJobPresentation(id: "archive", name: "Past backup", status: .completed, enabled: false,
            schedule: nil, runAtText: nil, nextRunAt: nil, lastRunAt: nil, completedAt: nil, lastExitCode: nil)
        history.executions = [
            .init(date: now.addingTimeInterval(-86400), exitCode: 0),
            .init(date: now.addingTimeInterval(-3600), exitCode: 1)
        ]
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for (width, month, height) in [(900.0, true, 1300.0), (510.0, false, 660.0)] {
                let image = try rasterize(PickyHubCronCalendarView(jobs: [job, history], now: now, showsMonth: month)
                    .environment(\.locale, Locale(identifier: "en_US")), name: "calendar-\(month ? "month" : "agenda")", width: width, height: height)
                let text = try recognizedLines(image).joined(separator: " ")
                #expect(!text.contains("Recurring") && !text.contains("One-time"))
                #expect(text.contains("Backup documents"), "Name must remain readable: \(text)")
                #expect(text.components(separatedBy: "Past backup").count >= 3,
                        "Both recorded execution days must be visible alongside the future job: \(text)")
                if !month { #expect(text.contains("Agenda")) }
            }
        }
    }

    @Test func loadedHistoryRefocusesTheExistingWeekViewport() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10)))
        let fixture = CronCalendarHistoryFixture(now: now)
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let host = NSHostingView(rootView: AnyView(CronCalendarHistoryFixtureView(fixture: fixture)))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close(); host.rootView = AnyView(EmptyView()) }
            try #require(waitForLayout(host) { self.scrollViews(host).contains { $0.contentView.bounds.origin.y > 700 } })
            let offset = try #require(scrollViews(host).map { $0.contentView.bounds.origin.y }.max())
            // Deliver the page's history response through the production input boundary.
            // AX queries on an unshown SwiftUI host can block and are not a click test.
            let range = try #require(fixture.requested)
            let date = Calendar.current.date(byAdding: .day, value: 2, to: range.start)!.addingTimeInterval(7.5 * 3600)
            var job = PickyCronJobPresentation(id: "past", name: "Morning archive", status: .completed, enabled: false,
                schedule: nil, runAtText: nil, nextRunAt: nil, lastRunAt: nil, completedAt: nil, lastExitCode: nil)
            job.executions = [.init(date: date, exitCode: 0)]
            fixture.jobs = [job]
            fixture.loadedInterval = range
            #expect(waitForLayout(host) { self.scrollViews(host).contains { $0.contentView.bounds.origin.y < offset - 100 && $0.contentView.bounds.origin.y > 100 } })
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let text = try recognizedLines(image).joined(separator: " ")
            #expect(text.contains("Morning archive"), "Loaded historical execution must be in the viewport: \(text)")
            try save(image, name: "calendar-loaded-history")
        }
    }

    private func waitForLayout(_ host: NSView, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return condition()
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private func recognizedLines(_ bitmap: NSBitmapImageRep) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func rasterize(_ view: some View, name: String, width: CGFloat, height: CGFloat, dark: Bool = false) throws -> NSBitmapImageRep {
        let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(
            view.frame(width: width, height: height), logicalSize: CGSize(width: width, height: height),
            scale: 2, appearance: dark ? .darkAqua : .aqua
        ))
        try save(bitmap, name: name)
        return bitmap
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        let request = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/render-gallery/.calendar-output-path")
        if let path = try? String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
private final class CronCalendarHistoryFixture: ObservableObject {
    let now: Date
    @Published var jobs: [PickyCronJobPresentation]
    @Published var loadedInterval: DateInterval?
    var requested: DateInterval?
    init(now: Date) {
        self.now = now
        jobs = [.init(id: "future", name: "Afternoon backup", status: .active, enabled: true,
            schedule: nil, runAtText: nil, nextRunAt: now.addingTimeInterval(4.5 * 3600), lastRunAt: nil, completedAt: nil, lastExitCode: nil)]
    }
}

private struct CronCalendarHistoryFixtureView: View {
    @ObservedObject var fixture: CronCalendarHistoryFixture
    var body: some View {
        PickyHubCronCalendarView(jobs: fixture.jobs, now: fixture.now, loadedHistoryInterval: fixture.loadedInterval,
            onVisibleIntervalChange: { fixture.requested = $0 })
            .environment(\.locale, Locale(identifier: "en_US"))
            .preferredColorScheme(.light)
            .padding(20).background(PickyHubTheme.Colors.canvas)
    }
}

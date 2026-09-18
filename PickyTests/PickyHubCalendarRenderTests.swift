import AppKit
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

    @Test func calendarRendersStartTimesAndJobNamesInBothAppearances() throws {
        let now = try #require(PickyCronJobReader.parseDate("2026-09-18T12:00:00Z"))
        let job = PickyCronJobPresentation(
            id: "daily", name: "Daily report", status: .active, enabled: true,
            schedule: "0 9 * * *", runAtText: nil,
            nextRunAt: now.addingTimeInterval(86400),
            lastRunAt: Calendar.current.startOfDay(for: now).addingTimeInterval(3600),
            completedAt: nil, lastExitCode: 0
        )
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for dark in [false, true] {
                let view = PickyHubCronCalendarView(jobs: [job], now: now)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .preferredColorScheme(dark ? .dark : .light)
                    .padding(20)
                    .background(PickyHubTheme.Colors.canvas)
                let image = try rasterize(view, name: "calendar-\(dark ? "dark" : "light")", width: 800, height: 660, dark: dark)
                let lines = try recognizedLines(image)
                #expect(lines.contains { $0.contains("Recurring") })
                #expect(lines.contains { $0.contains("Daily report") }, "Scheduled occurrence should be visible: \(lines)")
            }
        }
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
        let request = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/render-gallery/.calendar-output-path")
        if let path = try? String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }
}

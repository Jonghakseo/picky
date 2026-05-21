//
//  PickyContextPacketTests.swift
//  PickyTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Picky

private struct FakeAppProvider: PickyApplicationContextProviding {
    func activeApplicationContext() -> PickyApplicationContext? {
        PickyApplicationContext(bundleId: "com.apple.Safari", name: "Safari", pid: 42)
    }
}

private struct FakeWindowProvider: PickyWindowContextProviding {
    func activeWindowContext() -> PickyWindowContext? {
        PickyWindowContext(title: "Issue page", frame: PickyCGRect(x: 0, y: 0, width: 100, height: 100))
    }
}

private struct FakeBrowserProvider: PickyBrowserContextProviding {
    let url: URL
    func browserContext() -> PickyBrowserContext? {
        PickyBrowserContext(url: url, title: "Browser title", selectedText: "selected text")
    }
}

private struct FakeScreenProvider: PickyScreenContextProviding {
    func screenContexts() -> [PickyScreenContext] {
        [
            PickyScreenContext(
                label: "primary focus",
                frame: PickyCGRect(CGRect(x: 0, y: 0, width: 1512, height: 982)),
                screenshotWidthInPixels: 3024,
                screenshotHeightInPixels: 1964,
                isCursorScreen: true,
                cursor: PickyCursorContext(
                    globalPoint: PickyCGPoint(x: 200, y: 300),
                    displayPoint: PickyCGPoint(x: 200, y: 682),
                    screenshotPixel: PickyCGPoint(x: 400, y: 1364)
                ),
                imageData: Data("jpeg".utf8)
            )
        ]
    }
}

struct PickyContextPacketTests {
    @Test func screenshotCapturePixelSizeScalesLongestDisplayDimension() {
        #expect(CompanionScreenCaptureUtility.capturePixelSize(
            displayWidth: 3024,
            displayHeight: 1964,
            maximumDimension: PickyScreenshotQuality.standard.maximumDimension
        ) == (width: 1280, height: 831))
        #expect(CompanionScreenCaptureUtility.capturePixelSize(
            displayWidth: 3024,
            displayHeight: 1964,
            maximumDimension: PickyScreenshotQuality.onePointFive.maximumDimension
        ) == (width: 1920, height: 1246))
        #expect(CompanionScreenCaptureUtility.capturePixelSize(
            displayWidth: 3024,
            displayHeight: 1964,
            maximumDimension: PickyScreenshotQuality.double.maximumDimension
        ) == (width: 2560, height: 1662))
        #expect(CompanionScreenCaptureUtility.capturePixelSize(
            displayWidth: 1080,
            displayHeight: 1920,
            maximumDimension: PickyScreenshotQuality.double.maximumDimension
        ) == (width: 1440, height: 2560))
    }

    @Test @MainActor func realScreenCaptureIsDisabledInUnitTests() async throws {
        do {
            _ = try await CompanionScreenCaptureUtility.captureScreensAsJPEG(scope: .focusedScreen)
            Issue.record("Expected real screen capture to be disabled during unit tests")
        } catch let error as NSError {
            #expect(error.domain == "CompanionScreenCapture")
            #expect(error.code == -1000)
        }
    }

    @Test @MainActor func contextCaptureExcludesPickyChromeButKeepsArtifactViewers() {
        let hud = PickyHUDPanel(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let terminal = PickyTerminalPanel(
            contentRect: .zero,
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        let report = PickyReportPanel(
            contentRect: .zero,
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        defer {
            hud.close()
            terminal.close()
            report.close()
        }

        #expect(CompanionScreenCaptureUtility.shouldExcludeWindowFromContextCapture(hud))
        #expect(!CompanionScreenCaptureUtility.shouldExcludeWindowFromContextCapture(terminal))
        #expect(!CompanionScreenCaptureUtility.shouldExcludeWindowFromContextCapture(report))
    }

    @Test func assemblesNeutralVoiceContextPacketAndStoresScreenshots() throws {
        let screenshotsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-context-\(UUID().uuidString)", isDirectory: true)
        let assembler = PickyContextPacketAssembler(
            appProvider: FakeAppProvider(),
            windowProvider: FakeWindowProvider(),
            browserProvider: FakeBrowserProvider(url: URL(string: "https://example.com/issue/123")!),
            screenProvider: FakeScreenProvider(),
            screenshotStore: PickyAppSupportScreenshotStore(screenshotsRoot: screenshotsRoot),
            defaultCwd: "/Users/test/project",
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            idGenerator: { "context-test-001" }
        )

        let packet = try assembler.assemble(source: "voice", transcript: "이 화면 맥락으로 원인 분석해줘")

        #expect(packet.source == "voice")
        #expect(packet.transcript == "이 화면 맥락으로 원인 분석해줘")
        #expect(packet.activeApp?.bundleId == "com.apple.Safari")
        #expect(packet.activeWindow?.title == "Issue page")
        #expect(packet.browser?.url?.absoluteString == "https://example.com/issue/123")
        #expect(packet.screenshots.first?.label == "primary focus")
        #expect(packet.screenshots.first?.path.hasPrefix(screenshotsRoot.path) == true)
        #expect(packet.screenshots.first?.screenshotWidthInPixels == 3024)
        #expect(packet.screenshots.first?.screenshotHeightInPixels == 1964)
        #expect(packet.screenshots.first?.isCursorScreen == true)
        #expect(packet.screenshots.first?.cursor?.globalPoint == PickyCGPoint(x: 200, y: 300))
        #expect(packet.screenshots.first?.cursor?.displayPoint == PickyCGPoint(x: 200, y: 682))
        #expect(packet.screenshots.first?.cursor?.screenshotPixel == PickyCGPoint(x: 400, y: 1364))
        #expect(FileManager.default.fileExists(atPath: packet.screenshots.first?.path ?? ""))
        #expect(packet.cwd == "/Users/test/project")
    }

    @Test func sentryAndSlackUrlsRemainDataFieldsOnly() throws {
        for url in ["https://example.sentry.io/issues/123456/", "https://example.slack.com/archives/C123/p123"] {
            let screenshotsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-context-\(UUID().uuidString)", isDirectory: true)
            let assembler = PickyContextPacketAssembler(
                appProvider: FakeAppProvider(),
                browserProvider: FakeBrowserProvider(url: URL(string: url)!),
                screenProvider: FakeScreenProvider(),
                screenshotStore: PickyAppSupportScreenshotStore(screenshotsRoot: screenshotsRoot),
                defaultCwd: nil,
                idGenerator: { "context-url-001" }
            )

            let packet = try assembler.assemble(source: "voice", transcript: "확인해줘")

            #expect(packet.browser?.url?.absoluteString == url)
            #expect(packet.warnings.isEmpty)
            #expect(packet.transcript == "확인해줘")
        }
    }

    @Test func assemblesInkMarksIntoScreenshotPixelContext() throws {
        let screenshotsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-ink-context-\(UUID().uuidString)", isDirectory: true)
        let capture = CompanionScreenCapture(
            imageData: Data("jpeg".utf8),
            label: "focused screen — cursor is on this screen (primary focus)",
            isCursorScreen: true,
            displayWidthInPoints: 100,
            displayHeightInPoints: 100,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotWidthInPixels: 200,
            screenshotHeightInPixels: 200,
            cursor: nil
        )
        let inkCapture = PickyInkCapture(
            id: "ink-test",
            source: .voice,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_001),
            strokes: [
                PickyInkCaptureStroke(
                    id: "ink-test-stroke-1",
                    source: .voice,
                    points: [PickyCGPoint(x: 10, y: 10), PickyCGPoint(x: 30, y: 30), PickyCGPoint(x: 40, y: 20)],
                    strokeWidth: 8,
                    opacity: 0.34
                )
            ]
        )
        let assembler = PickyContextPacketAssembler(
            appProvider: FakeAppProvider(),
            screenProvider: StaticPickyScreenContextProvider(captures: [capture], inkCapture: inkCapture),
            screenshotStore: PickyAppSupportScreenshotStore(screenshotsRoot: screenshotsRoot),
            defaultCwd: nil,
            idGenerator: { "context-ink-001" }
        )

        let packet = try assembler.assemble(source: "voice", transcript: "여기 봐줘")

        #expect(packet.inkMarks.count == 1)
        #expect(packet.inkMarks.first?.screenId == "screen1")
        #expect(packet.inkMarks.first?.points == [
            PickyCGPoint(x: 20, y: 180),
            PickyCGPoint(x: 60, y: 140),
            PickyCGPoint(x: 80, y: 160)
        ])
        #expect(packet.inkMarks.first?.bounds == PickyCGRect(x: 20, y: 140, width: 60, height: 40))
        #expect(packet.inkMarks.first?.strokeWidth == 16)
        #expect(packet.inkMarks.first?.opacity == 0.34)
    }

    @Test func agentClientStubReturnsLocalReceiptWithoutRouting() async throws {
        let packet = PickyContextPacket(
            id: "context-test-001",
            source: "voice",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "https://example.com/issue/123 확인해줘",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )

        let receipt = try await LocalStubPickyAgentClient().submit(
            PickyAgentSubmission(transcript: packet.transcript ?? "", context: packet)
        )

        #expect(receipt.sessionID.hasPrefix("local-stub-"))
        #expect(receipt.message.contains("picky-agentd"))
    }
}

//
//  PickyContextPacketTests.swift
//  PickyTests
//

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
                imageData: Data("jpeg".utf8)
            )
        ]
    }
}

struct PickyContextPacketTests {
    @Test func assemblesNeutralVoiceContextPacketAndStoresScreenshots() throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("picky-context-\(UUID().uuidString)", isDirectory: true)
        let assembler = PickyContextPacketAssembler(
            appProvider: FakeAppProvider(),
            windowProvider: FakeWindowProvider(),
            browserProvider: FakeBrowserProvider(url: URL(string: "https://example.com/issue/123")!),
            screenProvider: FakeScreenProvider(),
            screenshotStore: PickyAppSupportScreenshotStore(appSupportRoot: appSupport),
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
        #expect(packet.screenshots.first?.path.hasPrefix(appSupport.path) == true)
        #expect(packet.screenshots.first?.screenshotWidthInPixels == 3024)
        #expect(packet.screenshots.first?.screenshotHeightInPixels == 1964)
        #expect(packet.screenshots.first?.isCursorScreen == true)
        #expect(FileManager.default.fileExists(atPath: packet.screenshots.first?.path ?? ""))
        #expect(packet.cwd == "/Users/test/project")
    }

    @Test func sentryAndSlackUrlsRemainDataFieldsOnly() throws {
        for url in ["https://creatrip.sentry.io/issues/123456/", "https://creatrip.slack.com/archives/C123/p123"] {
            let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("picky-context-\(UUID().uuidString)", isDirectory: true)
            let assembler = PickyContextPacketAssembler(
                appProvider: FakeAppProvider(),
                browserProvider: FakeBrowserProvider(url: URL(string: url)!),
                screenProvider: FakeScreenProvider(),
                screenshotStore: PickyAppSupportScreenshotStore(appSupportRoot: appSupport),
                defaultCwd: nil,
                idGenerator: { "context-url-001" }
            )

            let packet = try assembler.assemble(source: "voice", transcript: "확인해줘")

            #expect(packet.browser?.url?.absoluteString == url)
            #expect(packet.warnings.isEmpty)
            #expect(packet.transcript == "확인해줘")
        }
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

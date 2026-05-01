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
        PickyApplicationContext(
            localizedName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 42
        )
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
                isCursorScreen: true
            )
        ]
    }
}

struct PickyContextPacketTests {
    @Test func assemblesNeutralVoiceContextPacket() throws {
        let assembler = PickyContextPacketAssembler(
            appProvider: FakeAppProvider(),
            screenProvider: FakeScreenProvider(),
            defaultCwd: "/Users/test/project",
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let packet = assembler.assemble(
            source: "voice",
            transcript: "이 화면 맥락으로 원인 분석해줘"
        )

        #expect(packet.source == "voice")
        #expect(packet.transcript == "이 화면 맥락으로 원인 분석해줘")
        #expect(packet.activeApplication?.bundleIdentifier == "com.apple.Safari")
        #expect(packet.screens.first?.label == "primary focus")
        #expect(packet.defaultCwd == "/Users/test/project")
    }

    @Test func agentClientStubReturnsLocalReceiptWithoutRouting() async throws {
        let packet = PickyContextPacket(
            source: "voice",
            transcript: "https://example.com/issue/123 확인해줘",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            activeApplication: nil,
            activeWindow: nil,
            screens: [],
            defaultCwd: nil
        )

        let receipt = try await LocalStubPickyAgentClient().submit(
            PickyAgentSubmission(transcript: packet.transcript, context: packet)
        )

        #expect(receipt.sessionID.hasPrefix("local-stub-"))
        #expect(receipt.message.contains("picky-agentd integration"))
    }
}

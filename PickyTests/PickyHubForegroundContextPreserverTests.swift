//
//  PickyHubForegroundContextPreserverTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyHubForegroundContextPreserverTests {
    @Test(arguments: ["voice", "voice-follow-up", "text", "text-follow-up"])
    func captureRestoresTheExternalAppOnlyForVoiceSources(source: String) async throws {
        let picky = PickyForegroundApplication(
            bundleIdentifier: "com.example.Picky",
            processIdentifier: 1
        )
        let editor = PickyForegroundApplication(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 2
        )
        var frontmost = editor
        var events: [String] = []
        let preserver = PickyHubForegroundContextPreserver(
            pickyBundleIdentifier: picky.bundleIdentifier,
            frontmostApplicationProvider: { frontmost },
            applicationActivator: { target in
                events.append("activate:\(target.bundleIdentifier ?? "unknown")")
                frontmost = target
                return true
            }
        )
        preserver.recordExternalForegroundBeforeHubActivation()
        frontmost = picky

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _, _ in
                events.append("screen:\(frontmost.bundleIdentifier ?? "unknown")")
                return []
            },
            settingsProvider: { .defaults() },
            contextPreflightPreparation: {
                await preserver.restoreExternalForegroundForContextCapture(
                    hubIsVisible: true,
                    dismissHub: { events.append("dismissHub") }
                )
            },
            contextPreflightCapture: {
                events.append("capture:\(frontmost.bundleIdentifier ?? "unknown")")
                return PickyContextPacketPreflight(
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    activeApp: PickyApplicationContext(
                        bundleId: frontmost.bundleIdentifier,
                        name: "Editor",
                        pid: Int(frontmost.processIdentifier)
                    ),
                    activeWindow: PickyWindowContext(
                        title: "External document",
                        frame: PickyCGRect(x: 10, y: 20, width: 800, height: 600)
                    ),
                    browser: nil,
                    selectedText: "selected external text",
                    warnings: []
                )
            },
            contextPreparer: { _, source, _, preflight in
                PickyPreparedContextPacket(
                    id: "external-context",
                    source: source,
                    capturedAt: preflight.capturedAt,
                    selectedText: preflight.selectedText,
                    cwd: nil,
                    activeApp: preflight.activeApp,
                    activeWindow: preflight.activeWindow,
                    browser: preflight.browser,
                    screenshots: [],
                    inkMarks: [],
                    warnings: preflight.warnings
                )
            }
        )

        let result = try await coordinator.captureContext(
            transcript: "capture my selection",
            source: source
        )

        let isVoice = source == "voice" || source == "voice-follow-up"
        let expectedApp = isVoice ? "com.example.Editor" : "com.example.Picky"
        if isVoice {
            #expect(Array(events.prefix(2)) == ["dismissHub", "activate:com.example.Editor"])
            #expect(Set(events.dropFirst(2)) == ["capture:\(expectedApp)", "screen:\(expectedApp)"])
        } else {
            #expect(Set(events) == ["capture:\(expectedApp)", "screen:\(expectedApp)"])
        }
        #expect(result?.contextPacket.activeApp?.bundleId == expectedApp)
        #expect(result?.contextPacket.activeWindow?.title == "External document")
        #expect(result?.contextPacket.selectedText == "selected external text")
    }

    @Test func clickingAnOpenHubAfterSwitchingAppsRestoresTheLatestExternalApp() async {
        let picky = PickyForegroundApplication(bundleIdentifier: "com.example.Picky", processIdentifier: 1)
        let editor = PickyForegroundApplication(bundleIdentifier: "com.example.Editor", processIdentifier: 2)
        let browser = PickyForegroundApplication(bundleIdentifier: "com.example.Browser", processIdentifier: 3)
        var frontmost = editor
        var activated: [PickyForegroundApplication] = []
        let preserver = PickyHubForegroundContextPreserver(
            pickyBundleIdentifier: picky.bundleIdentifier,
            frontmostApplicationProvider: { frontmost },
            applicationActivator: { target in
                activated.append(target)
                frontmost = target
                return true
            }
        )
        preserver.recordExternalForegroundBeforeHubActivation()
        frontmost = browser
        preserver.recordExternalActivation(browser)
        frontmost = picky
        preserver.recordExternalActivation(picky)
        // A repeated menu-bar/deep-link focus must not erase this observation.
        preserver.recordExternalForegroundBeforeHubActivation(hubIsVisible: true)

        await preserver.restoreExternalForegroundForContextCapture(hubIsVisible: true, dismissHub: {})

        #expect(activated == [browser])
        #expect(frontmost == browser)
    }

    @Test func newerExternalForegroundIsNotReplacedWithTheAppHubOriginallyCovered() async {
        let picky = PickyForegroundApplication(
            bundleIdentifier: "com.example.Picky",
            processIdentifier: 1
        )
        let originalEditor = PickyForegroundApplication(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 2
        )
        let newerBrowser = PickyForegroundApplication(
            bundleIdentifier: "com.example.Browser",
            processIdentifier: 3
        )
        var frontmost = originalEditor
        var actions: [String] = []
        let preserver = PickyHubForegroundContextPreserver(
            pickyBundleIdentifier: picky.bundleIdentifier,
            frontmostApplicationProvider: { frontmost },
            applicationActivator: { target in
                actions.append("activate:\(target.bundleIdentifier ?? "unknown")")
                frontmost = target
                return true
            }
        )
        preserver.recordExternalForegroundBeforeHubActivation()
        frontmost = newerBrowser

        await preserver.restoreExternalForegroundForContextCapture(
            hubIsVisible: true,
            dismissHub: { actions.append("dismissHub") }
        )
        #expect(frontmost == newerBrowser)
        frontmost = picky
        await preserver.restoreExternalForegroundForContextCapture(
            hubIsVisible: true,
            dismissHub: { actions.append("dismissHub") }
        )

        #expect(actions.isEmpty)
        #expect(frontmost == picky)
    }

    @Test func failedExternalActivationDoesNotKeepAStaleTargetForLaterCaptures() async {
        let picky = PickyForegroundApplication(
            bundleIdentifier: "com.example.Picky",
            processIdentifier: 1
        )
        let editor = PickyForegroundApplication(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 2
        )
        var frontmost = editor
        var activationCount = 0
        let preserver = PickyHubForegroundContextPreserver(
            pickyBundleIdentifier: picky.bundleIdentifier,
            frontmostApplicationProvider: { frontmost },
            applicationActivator: { _ in
                activationCount += 1
                return false
            }
        )
        preserver.recordExternalForegroundBeforeHubActivation()
        frontmost = picky

        await preserver.restoreExternalForegroundForContextCapture(hubIsVisible: true, dismissHub: {})
        await preserver.restoreExternalForegroundForContextCapture(hubIsVisible: true, dismissHub: {})

        #expect(activationCount == 1)
    }
}

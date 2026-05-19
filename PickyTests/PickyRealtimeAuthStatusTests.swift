//
//  PickyRealtimeAuthStatusTests.swift
//  PickyTests
//
//  Unit tests for the Realtime auth inspector and gate. Both pieces are
//  load-bearing on PICKY_REALTIME_OPT_IN=1 builds because:
//    * the inspector decides whether agentd's Realtime connect attempt will
//      succeed (Codex OAuth file present, Platform/Azure API key pasted), and
//    * the gate is the only place that proactively tells the user "this build
//      won't talk back to you until you sign in" without waiting for the next
//      PTT.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyRealtimeAuthStatusInspectorTests {
    @Test func codexOAuthMode_withFilePresent_returnsAuthenticated() {
        var settings = PickySettings.defaults()
        settings.openAIRealtime.provider = .openAI
        settings.openAIRealtime.authMode = .codexOAuth
        settings.openAIRealtime.apiKey = ""

        let status = PickyRealtimeAuthStatusInspector.currentStatus(
            settings: settings,
            codexAuthPresent: { true }
        )

        #expect(status.mode == .codexOAuth)
        #expect(status.isAuthenticated)
        #expect(status.blockReason == nil)
    }

    @Test func codexOAuthMode_withFileMissing_blocksWithMissingCodexOAuth() {
        var settings = PickySettings.defaults()
        settings.openAIRealtime.provider = .openAI
        settings.openAIRealtime.authMode = .codexOAuth
        settings.openAIRealtime.apiKey = ""

        let status = PickyRealtimeAuthStatusInspector.currentStatus(
            settings: settings,
            codexAuthPresent: { false }
        )

        #expect(status.mode == .codexOAuth)
        #expect(!status.isAuthenticated)
        #expect(status.blockReason == .missingCodexOAuth)
    }

    @Test func apiKeyMode_withKeyPasted_returnsAuthenticated() {
        var settings = PickySettings.defaults()
        settings.openAIRealtime.provider = .openAI
        settings.openAIRealtime.authMode = .apiKey
        settings.openAIRealtime.apiKey = "sk-something"

        let status = PickyRealtimeAuthStatusInspector.currentStatus(
            settings: settings,
            codexAuthPresent: { false }
        )

        #expect(status.mode == .openAIPlatformKey)
        #expect(status.isAuthenticated)
    }

    @Test func apiKeyMode_withWhitespaceOnlyKey_blocksWithMissingPlatformKey() {
        var settings = PickySettings.defaults()
        settings.openAIRealtime.provider = .openAI
        settings.openAIRealtime.authMode = .apiKey
        settings.openAIRealtime.apiKey = "   \n  "

        let status = PickyRealtimeAuthStatusInspector.currentStatus(
            settings: settings,
            codexAuthPresent: { true }
        )

        #expect(status.mode == .openAIPlatformKey)
        #expect(status.blockReason == .missingPlatformKey)
    }

    @Test func azureProvider_alwaysRequiresApiKey_evenWhenAuthModeIsCodex() {
        // Azure ignores authMode at runtime — its endpoint requires an
        // `api-key` header. The inspector mirrors that behaviour so the gate
        // wording matches reality.
        var settings = PickySettings.defaults()
        settings.openAIRealtime.provider = .azureOpenAI
        settings.openAIRealtime.authMode = .codexOAuth
        settings.openAIRealtime.apiKey = ""

        let status = PickyRealtimeAuthStatusInspector.currentStatus(
            settings: settings,
            codexAuthPresent: { true }
        )

        #expect(status.mode == .azureKey)
        #expect(status.blockReason == .missingAzureKey)
    }

    @Test func azureProvider_withPastedKey_returnsAuthenticated() {
        var settings = PickySettings.defaults()
        settings.openAIRealtime.provider = .azureOpenAI
        settings.openAIRealtime.authMode = .apiKey
        settings.openAIRealtime.apiKey = "azure-key"

        let status = PickyRealtimeAuthStatusInspector.currentStatus(
            settings: settings,
            codexAuthPresent: { false }
        )

        #expect(status.mode == .azureKey)
        #expect(status.isAuthenticated)
    }

    @Test func codexAuthTokenPresent_returnsFalse_whenFileIsMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let missingPath = tempDir.appendingPathComponent("auth.json").path

        #expect(!PickyRealtimeAuthStatusInspector.codexAuthTokenPresent(atPath: missingPath))
    }

    @Test func codexAuthTokenPresent_returnsTrue_forTopLevelAccessToken() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("auth.json").path
        let json: [String: Any] = ["access_token": "fake-token"]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))

        #expect(PickyRealtimeAuthStatusInspector.codexAuthTokenPresent(atPath: path))
    }

    @Test func codexAuthTokenPresent_returnsTrue_forNestedTokensAccessToken() throws {
        // Newer Codex CLI versions wrap access_token under a `tokens` object.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("auth.json").path
        let json: [String: Any] = ["tokens": ["access_token": "nested-token"]]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))

        #expect(PickyRealtimeAuthStatusInspector.codexAuthTokenPresent(atPath: path))
    }

    @Test func codexAuthTokenPresent_returnsFalse_forEmptyTokenString() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("auth.json").path
        let json: [String: Any] = ["access_token": "   "]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))

        #expect(!PickyRealtimeAuthStatusInspector.codexAuthTokenPresent(atPath: path))
    }
}

@MainActor
@Suite(.serialized)
struct PickyRealtimeAuthGateTests {
    private final class AlertRecorder {
        var calls: [PickyRealtimeAuthStatus.BlockReason] = []
        var openSettingsCount = 0
    }

    @Test func gate_doesNotFire_onPiRuntime() {
        let recorder = AlertRecorder()
        let gate = PickyRealtimeAuthGate(
            runtimeModeProvider: { .pi },
            authStatusProvider: {
                PickyRealtimeAuthStatus(mode: .openAIPlatformKey, blockReason: .missingPlatformKey)
            },
            openSettings: { recorder.openSettingsCount += 1 },
            alertPresenter: { reason, _ in recorder.calls.append(reason) }
        )

        gate.evaluate()
        gate.evaluate()

        #expect(recorder.calls.isEmpty)
        #expect(!gate.hasAlertedDuringSessionForTesting)
    }

    @Test func gate_fires_onceForOptInBuildWithMissingAuth() {
        let recorder = AlertRecorder()
        let gate = PickyRealtimeAuthGate(
            runtimeModeProvider: { .openAIRealtime },
            authStatusProvider: {
                PickyRealtimeAuthStatus(mode: .codexOAuth, blockReason: .missingCodexOAuth)
            },
            openSettings: { recorder.openSettingsCount += 1 },
            alertPresenter: { reason, _ in recorder.calls.append(reason) }
        )

        gate.evaluate()
        gate.evaluate()
        gate.evaluate()

        #expect(recorder.calls == [.missingCodexOAuth])
        #expect(gate.hasAlertedDuringSessionForTesting)
    }

    @Test func gate_silent_whenAuthIsHealthy() {
        let recorder = AlertRecorder()
        let gate = PickyRealtimeAuthGate(
            runtimeModeProvider: { .openAIRealtime },
            authStatusProvider: {
                PickyRealtimeAuthStatus(mode: .codexOAuth, blockReason: nil)
            },
            openSettings: { recorder.openSettingsCount += 1 },
            alertPresenter: { reason, _ in recorder.calls.append(reason) }
        )

        gate.evaluate()

        #expect(recorder.calls.isEmpty)
    }

    @Test func gate_invokesOpenSettings_whenPresenterCallsBack() {
        let recorder = AlertRecorder()
        let gate = PickyRealtimeAuthGate(
            runtimeModeProvider: { .openAIRealtime },
            authStatusProvider: {
                PickyRealtimeAuthStatus(mode: .openAIPlatformKey, blockReason: .missingPlatformKey)
            },
            openSettings: { recorder.openSettingsCount += 1 },
            alertPresenter: { reason, onOpenSettings in
                recorder.calls.append(reason)
                onOpenSettings()
            }
        )

        gate.evaluate()

        #expect(recorder.openSettingsCount == 1)
    }

    @Test func gate_rearmsAfterAuthRecovers_andFiresAgainOnNextRegression() {
        let recorder = AlertRecorder()
        var status = PickyRealtimeAuthStatus(mode: .codexOAuth, blockReason: .missingCodexOAuth)
        let gate = PickyRealtimeAuthGate(
            runtimeModeProvider: { .openAIRealtime },
            authStatusProvider: { status },
            openSettings: { recorder.openSettingsCount += 1 },
            alertPresenter: { reason, _ in recorder.calls.append(reason) }
        )

        gate.evaluate()
        status = PickyRealtimeAuthStatus(mode: .codexOAuth, blockReason: nil)
        gate.evaluate()
        status = PickyRealtimeAuthStatus(mode: .codexOAuth, blockReason: .missingCodexOAuth)
        gate.evaluate()

        #expect(recorder.calls == [.missingCodexOAuth, .missingCodexOAuth])
    }
}

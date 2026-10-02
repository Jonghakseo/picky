//
//  PickyPiOAuthLoginControllerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyPiOAuthLoginControllerTests {
    @Test func providersUsePiOAuthProviderIDs() {
        #expect(PickyPiOAuthLoginProvider.openAICodex.rawValue == "openai-codex")
        #expect(PickyPiOAuthLoginProvider.anthropic.rawValue == "anthropic")
    }

    @Test func statusRequestUsesAgentdAndMatchesTheCommandResponse() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            guard command.type == .getPiOAuthStatus, let provider = command.providerId else { return }
            client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
                requestId: command.id,
                providerId: provider,
                configured: true,
                source: "stored",
                label: "OAuth"
            )))))
        }
        let runner = PickyPiOAuthLoginAgentRunner(client: client)

        let status = try await runner.authStatus(for: .anthropic)

        #expect(status == PickyPiOAuthLoginAuthStatus(configured: true, source: "stored", label: "OAuth"))
        #expect(client.sentCommands.map(\.type) == [.getPiOAuthStatus])
        #expect(client.sentCommands.first?.providerId == .anthropic)
    }

    @Test func signInOpensTheBrowserAnswersBrowserSelectionAndReloadsEveryDaemon() async throws {
        let client = FakePickyAgentClient()
        var openedURLs: [URL] = []
        client.beforeSend = { command in
            switch command.type {
            case .signInPiOAuth:
                guard let provider = command.providerId else {
                    Issue.record("Expected OAuth provider")
                    return
                }
                client.emit(.protocolEvent(Self.envelope(.piOAuthPromptRequested(PickyPiOAuthPromptRequestEvent(
                    requestId: command.id,
                    providerId: provider,
                    promptId: "prompt-browser",
                    promptType: .select,
                    message: "Choose login method",
                    placeholder: nil,
                    options: [PickyPiOAuthPromptOption(id: "browser", label: "Browser", description: nil)]
                )))))
                client.emit(.protocolEvent(Self.envelope(.piOAuthUrlRequested(PickyPiOAuthUrlRequestEvent(
                    requestId: command.id,
                    providerId: provider,
                    url: "https://example.com/oauth",
                    instructions: nil,
                    userCode: nil
                )))))
                client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
                    requestId: command.id,
                    providerId: provider,
                    configured: true,
                    source: "stored",
                    label: nil
                )))))
            case .reloadPiAuthentication:
                client.emit(.protocolEvent(Self.envelope(.piAuthenticationReloaded(PickyPiAuthenticationReloadedEvent(
                    requestId: command.id,
                    reloadedHandleCount: 1
                )))))
            default:
                break
            }
        }
        let runner = PickyPiOAuthLoginAgentRunner(
            client: client,
            openURL: { url in openedURLs.append(url); return true },
            reloadTimeoutNanoseconds: 100_000_000
        )

        let status = try await runner.signIn(provider: .openAICodex, method: .browser, onDeviceCode: { _ in })

        #expect(status.configured)
        #expect(openedURLs.map(\.absoluteString) == ["https://example.com/oauth"])
        let promptAnswer = client.sentCommands.first(where: { $0.type == .answerPiOAuthPrompt })
        #expect(promptAnswer?.requestId != nil)
        #expect(promptAnswer?.promptId == "prompt-browser")
        #expect(promptAnswer?.value == .string("browser"))
        let didReloadAuthentication = client.sentCommands.contains(where: { $0.type == .reloadPiAuthentication })
        #expect(didReloadAuthentication)
    }

    @Test func deviceCodeSignInShowsTheCodeWithoutOpeningTheBrowserUntilTheDaemonCompletes() async throws {
        let client = FakePickyAgentClient()
        var openedURLs: [URL] = []
        var signInCommand: PickyCommandEnvelope?
        client.beforeSend = { command in
            switch command.type {
            case .signInPiOAuth:
                guard let provider = command.providerId else {
                    Issue.record("Expected OAuth provider")
                    return
                }
                signInCommand = command
                client.emit(.protocolEvent(Self.envelope(.piOAuthPromptRequested(PickyPiOAuthPromptRequestEvent(
                    requestId: command.id,
                    providerId: provider,
                    promptId: "prompt-method",
                    promptType: .select,
                    message: "Select OpenAI Codex login method:",
                    placeholder: nil,
                    options: [
                        PickyPiOAuthPromptOption(id: "browser", label: "Browser login (default)", description: nil),
                        PickyPiOAuthPromptOption(id: "device_code", label: "Device code login (headless)", description: nil),
                    ]
                )))))
            case .answerPiOAuthPrompt:
                guard let signInCommand, let provider = signInCommand.providerId else { return }
                client.emit(.protocolEvent(Self.envelope(.piOAuthUrlRequested(PickyPiOAuthUrlRequestEvent(
                    requestId: signInCommand.id,
                    providerId: provider,
                    url: "https://auth.openai.com/codex/device",
                    instructions: nil,
                    userCode: "ABCD-12345"
                )))))
            case .reloadPiAuthentication:
                client.emit(.protocolEvent(Self.envelope(.piAuthenticationReloaded(PickyPiAuthenticationReloadedEvent(
                    requestId: command.id,
                    reloadedHandleCount: 1
                )))))
            default:
                break
            }
        }
        let runner = PickyPiOAuthLoginAgentRunner(
            client: client,
            openURL: { url in openedURLs.append(url); return true },
            reloadTimeoutNanoseconds: 100_000_000
        )
        let controller = PickyPiOAuthLoginController(runner: runner)

        controller.signIn(provider: .openAICodex, method: .deviceCode)
        await waitUntil { controller.deviceCodes[.openAICodex] != nil }

        #expect(controller.status(for: .openAICodex) == .signingIn)
        #expect(controller.deviceCodes[.openAICodex] == PickyPiOAuthDeviceCode(
            verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
            userCode: "ABCD-12345"
        ))
        #expect(openedURLs.isEmpty)
        let promptAnswer = client.sentCommands.first(where: { $0.type == .answerPiOAuthPrompt })
        #expect(promptAnswer?.promptId == "prompt-method")
        #expect(promptAnswer?.value == .string("device_code"))

        let requestId = try #require(signInCommand?.id)
        client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
            requestId: requestId,
            providerId: .openAICodex,
            configured: true,
            source: "stored",
            label: nil
        )))))
        await waitUntil { controller.status(for: .openAICodex) == .configured(source: "stored") }

        #expect(controller.deviceCodes[.openAICodex] == nil)
        #expect(openedURLs.isEmpty)
    }

    @Test func deviceCodeSignInFailsWhenTheDaemonSendsNoUserCode() async {
        let client = FakePickyAgentClient()
        var openedURLs: [URL] = []
        var deliveredCodes: [PickyPiOAuthDeviceCode] = []
        client.beforeSend = { command in
            guard command.type == .signInPiOAuth, let provider = command.providerId else { return }
            client.emit(.protocolEvent(Self.envelope(.piOAuthUrlRequested(PickyPiOAuthUrlRequestEvent(
                requestId: command.id,
                providerId: provider,
                url: "https://auth.openai.com/codex/device",
                instructions: nil,
                userCode: ""
            )))))
        }
        let runner = PickyPiOAuthLoginAgentRunner(
            client: client,
            openURL: { url in openedURLs.append(url); return true }
        )

        do {
            _ = try await runner.signIn(
                provider: .openAICodex,
                method: .deviceCode,
                onDeviceCode: { deliveredCodes.append($0) }
            )
            Issue.record("Expected the missing device code to fail the sign-in")
        } catch let error as PickyPiOAuthLoginError {
            #expect(error == .deviceCodeMissing)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(openedURLs.isEmpty)
        #expect(deliveredCodes.isEmpty)
    }

    @Test func browserSignInStillOpensTheBrowserWhenTheDaemonAlsoSendsAUserCode() async throws {
        let client = FakePickyAgentClient()
        var openedURLs: [URL] = []
        var deliveredCodes: [PickyPiOAuthDeviceCode] = []
        client.beforeSend = { command in
            switch command.type {
            case .signInPiOAuth:
                guard let provider = command.providerId else { return }
                client.emit(.protocolEvent(Self.envelope(.piOAuthUrlRequested(PickyPiOAuthUrlRequestEvent(
                    requestId: command.id,
                    providerId: provider,
                    url: "https://example.com/oauth",
                    instructions: nil,
                    userCode: "STRAY-0001"
                )))))
                client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
                    requestId: command.id,
                    providerId: provider,
                    configured: true,
                    source: "stored",
                    label: nil
                )))))
            case .reloadPiAuthentication:
                client.emit(.protocolEvent(Self.envelope(.piAuthenticationReloaded(PickyPiAuthenticationReloadedEvent(
                    requestId: command.id,
                    reloadedHandleCount: 1
                )))))
            default:
                break
            }
        }
        let runner = PickyPiOAuthLoginAgentRunner(
            client: client,
            openURL: { url in openedURLs.append(url); return true },
            reloadTimeoutNanoseconds: 100_000_000
        )

        let status = try await runner.signIn(
            provider: .openAICodex,
            method: .browser,
            onDeviceCode: { deliveredCodes.append($0) }
        )

        #expect(status.configured)
        #expect(openedURLs.map(\.absoluteString) == ["https://example.com/oauth"])
        #expect(deliveredCodes.isEmpty)
    }

    @Test func providersWithoutDeviceCodeLoginIgnoreTheCodeSignInRequest() {
        let runner = FakePiOAuthLoginRunner(signOutStatus: .init(configured: false))
        let controller = PickyPiOAuthLoginController(runner: runner)

        controller.signIn(provider: .anthropic, method: .deviceCode)

        #expect(controller.status(for: .anthropic) == .unknown)
    }

    @Test func signOutReturnsFallbackStatusAndReloadsEveryDaemon() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            switch command.type {
            case .signOutPiOAuth:
                guard let provider = command.providerId else {
                    Issue.record("Expected OAuth provider")
                    return
                }
                client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
                    requestId: command.id,
                    providerId: provider,
                    configured: true,
                    source: "environment",
                    label: "API key"
                )))))
            case .reloadPiAuthentication:
                client.emit(.protocolEvent(Self.envelope(.piAuthenticationReloaded(PickyPiAuthenticationReloadedEvent(
                    requestId: command.id,
                    reloadedHandleCount: 3
                )))))
            default:
                break
            }
        }
        let runner = PickyPiOAuthLoginAgentRunner(client: client, reloadTimeoutNanoseconds: 100_000_000)

        let status = try await runner.signOut(provider: .anthropic)

        #expect(status == PickyPiOAuthLoginAuthStatus(configured: true, source: "environment", label: "API key"))
        #expect(client.sentCommands.map(\.type) == [.signOutPiOAuth, .reloadPiAuthentication])
        #expect(client.sentCommands.first?.providerId == .anthropic)
    }

    @Test func disconnectConfirmationCancelsWithoutChangingCredentialsThenRefreshesFallbackStatus() async {
        let runner = FakePiOAuthLoginRunner(
            signOutStatus: PickyPiOAuthLoginAuthStatus(configured: true, source: "environment", label: "API key")
        )
        let controller = PickyPiOAuthLoginController(runner: runner)

        controller.requestSignOut(provider: .anthropic)
        #expect(controller.pendingSignOutProvider == .anthropic)
        controller.cancelSignOutConfirmation()
        #expect(controller.pendingSignOutProvider == nil)
        #expect(runner.signOutProviders.isEmpty)

        controller.requestSignOut(provider: .anthropic)
        controller.confirmSignOut(provider: .anthropic)
        await waitUntil { controller.status(for: .anthropic) == .configured(source: "API key") }

        #expect(controller.pendingSignOutProvider == nil)
        #expect(runner.signOutProviders == [.anthropic])
    }

    @Test func browserFailureCancelsTheDaemonLogin() async {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            guard command.type == .signInPiOAuth, let provider = command.providerId else { return }
            client.emit(.protocolEvent(Self.envelope(.piOAuthUrlRequested(PickyPiOAuthUrlRequestEvent(
                requestId: command.id,
                providerId: provider,
                url: "https://example.com/oauth",
                instructions: nil,
                userCode: nil
            )))))
        }
        let runner = PickyPiOAuthLoginAgentRunner(client: client, openURL: { _ in false })

        do {
            _ = try await runner.signIn(provider: .anthropic, method: .browser, onDeviceCode: { _ in })
            Issue.record("Expected browser launch failure")
        } catch let error as PickyPiOAuthLoginError {
            #expect(error == .browserOpenFailed("https://example.com/oauth"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        await waitUntil { client.sentCommands.contains(where: { $0.type == .cancelPiOAuth }) }

        let signInRequestId = client.sentCommands.first(where: { $0.type == .signInPiOAuth })?.id
        #expect(client.sentCommands.first(where: { $0.type == .cancelPiOAuth })?.requestId == signInRequestId)
    }

    @Test func silentStatusRequestTimesOut() async {
        let client = FakePickyAgentClient()
        let runner = PickyPiOAuthLoginAgentRunner(client: client, statusTimeoutNanoseconds: 1_000_000)

        do {
            _ = try await runner.authStatus(for: .anthropic)
            Issue.record("Expected status timeout")
        } catch let error as PickyPiOAuthLoginError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancelSendsTheOwnedLoginRequestIDToAgentd() async {
        let client = FakePickyAgentClient()
        let runner = PickyPiOAuthLoginAgentRunner(client: client)
        let loginTask = Task { try await runner.signIn(provider: .anthropic, method: .browser, onDeviceCode: { _ in }) }
        await waitUntil { client.sentCommands.contains(where: { $0.type == .signInPiOAuth }) }
        let requestId = client.sentCommands.first(where: { $0.type == .signInPiOAuth })?.id

        runner.cancel(provider: .anthropic)
        await waitUntil { client.sentCommands.contains(where: { $0.type == .cancelPiOAuth }) }
        loginTask.cancel()
        do {
            _ = try await loginTask.value
            Issue.record("Expected the cancelled login task to throw")
        } catch is CancellationError {
            // Expected: local task cancellation and daemon cancellation settle together.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(client.sentCommands.first(where: { $0.type == .cancelPiOAuth })?.requestId == requestId)
    }

    @Test func ignoresStaleStatusFromAnOlderRequest() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            guard command.type == .getPiOAuthStatus, let provider = command.providerId else { return }
            client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
                requestId: "stale-request",
                providerId: provider,
                configured: false,
                source: nil,
                label: nil
            )))))
            client.emit(.protocolEvent(Self.envelope(.piOAuthStatus(PickyPiOAuthStatusEvent(
                requestId: command.id,
                providerId: provider,
                configured: true,
                source: "stored",
                label: nil
            )))))
        }
        let runner = PickyPiOAuthLoginAgentRunner(client: client)

        let status = try await runner.authStatus(for: .anthropic)

        #expect(status.configured)
    }

    private static func envelope(_ event: PickyEvent) -> PickyEventEnvelope {
        PickyEventEnvelope(
            id: "event-\(UUID().uuidString)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            event: event
        )
    }
}

@MainActor
private final class FakePiOAuthLoginRunner: PickyPiOAuthLoginRunning {
    let signOutStatus: PickyPiOAuthLoginAuthStatus
    private(set) var signOutProviders: [PickyPiOAuthLoginProvider] = []

    init(signOutStatus: PickyPiOAuthLoginAuthStatus) {
        self.signOutStatus = signOutStatus
    }

    func authStatus(for provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        .init(configured: false)
    }

    func signIn(
        provider: PickyPiOAuthLoginProvider,
        method: PickyPiOAuthLoginMethod,
        onDeviceCode: @escaping @MainActor (PickyPiOAuthDeviceCode) -> Void
    ) async throws -> PickyPiOAuthLoginAuthStatus {
        .init(configured: true, source: "stored")
    }

    func signOut(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        signOutProviders.append(provider)
        return signOutStatus
    }

    func cancel(provider: PickyPiOAuthLoginProvider) {}
}

@MainActor
private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition was not reached")
}

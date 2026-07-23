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

        let status = try await runner.signIn(provider: .openAICodex)

        #expect(status.configured)
        #expect(openedURLs.map(\.absoluteString) == ["https://example.com/oauth"])
        let promptAnswer = client.sentCommands.first(where: { $0.type == .answerPiOAuthPrompt })
        #expect(promptAnswer?.requestId != nil)
        #expect(promptAnswer?.promptId == "prompt-browser")
        #expect(promptAnswer?.value == .string("browser"))
        let didReloadAuthentication = client.sentCommands.contains(where: { $0.type == .reloadPiAuthentication })
        #expect(didReloadAuthentication)
    }

    @Test func cancelSendsTheOwnedLoginRequestIDToAgentd() async {
        let client = FakePickyAgentClient()
        let runner = PickyPiOAuthLoginAgentRunner(client: client)
        let loginTask = Task { try await runner.signIn(provider: .anthropic) }
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
private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition was not reached")
}

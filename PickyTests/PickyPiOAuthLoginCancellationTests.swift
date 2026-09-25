import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyPiOAuthLoginCancellationTests {
    @Test func appearingChecksBothProvidersWithoutStartingLogin() async {
        let runner = CancellationOAuthRunner()
        runner.configured = [.anthropic]
        let controller = PickyPiOAuthLoginController(runner: runner)
        controller.refreshAll()
        await waitFor { controller.status(for: .openAICodex) == .notConfigured && controller.status(for: .anthropic) == .configured(source: "OAuth") }
        #expect(Set(runner.checked) == Set(PickyPiOAuthLoginProvider.allCases))
        #expect(runner.logins.isEmpty)
    }

    @Test func userConnectCanFailRetryCompleteAndReconnect() async {
        let runner = CancellationOAuthRunner()
        let controller = PickyPiOAuthLoginController(runner: runner)
        controller.signIn(provider: .openAICodex)
        #expect(controller.status(for: .openAICodex) == .signingIn)
        await waitFor { runner.pending.count == 1 }
        runner.pending.removeFirst().resume(throwing: LoginFailure())
        await waitFor { controller.status(for: .openAICodex) == .failed("Login failed") }
        controller.signIn(provider: .openAICodex)
        await waitFor { runner.pending.count == 1 }
        runner.pending.removeFirst().resume(returning: .init(configured: true, label: "OAuth"))
        await waitFor { controller.status(for: .openAICodex) == .configured(source: "OAuth") }
        controller.signIn(provider: .openAICodex)
        await waitFor { runner.pending.count == 1 }
        runner.pending.removeFirst().resume(returning: .init(configured: true, label: "OAuth"))
        await waitFor { controller.status(for: .openAICodex) == .configured(source: "OAuth") }
        #expect(runner.logins == [.openAICodex, .openAICodex, .openAICodex])
    }

    @Test func cancellingReconnectRechecksStoredAuthAndIgnoresOldCompletion() async {
        let runner = CancellationOAuthRunner()
        runner.configured = [.anthropic]
        let controller = PickyPiOAuthLoginController(runner: runner)
        controller.signIn(provider: .anthropic)
        await waitFor { runner.pending.count == 1 }
        let cancelled = runner.pending.removeFirst()
        controller.cancel(provider: .anthropic)
        await waitFor { controller.status(for: .anthropic) == .configured(source: "OAuth") }
        #expect(runner.cancelled == [.anthropic])
        controller.signIn(provider: .anthropic)
        await waitFor { runner.pending.count == 1 }
        cancelled.resume(throwing: LoginFailure())
        runner.pending.removeFirst().resume(returning: .init(configured: true, label: "New OAuth"))
        await waitFor { controller.status(for: .anthropic) == .configured(source: "New OAuth") }
    }

    @Test func cancellingInitialConnectionReturnsToDisconnected() async {
        let runner = CancellationOAuthRunner()
        let controller = PickyPiOAuthLoginController(runner: runner)
        controller.signIn(provider: .anthropic)
        await waitFor { runner.pending.count == 1 }
        controller.cancel(provider: .anthropic)
        runner.pending.removeFirst().resume(throwing: CancellationError())
        await waitFor { controller.status(for: .anthropic) == .notConfigured }
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Expected authentication state was not reached")
    }
}

private struct LoginFailure: LocalizedError {
    var errorDescription: String? { "Login failed" }
}

@MainActor
private final class CancellationOAuthRunner: PickyPiOAuthLoginRunning {
    var configured: Set<PickyPiOAuthLoginProvider> = []
    var checked: [PickyPiOAuthLoginProvider] = []
    var logins: [PickyPiOAuthLoginProvider] = []
    var cancelled: [PickyPiOAuthLoginProvider] = []
    var pending: [CheckedContinuation<PickyPiOAuthLoginAuthStatus, Error>] = []

    func authStatus(for provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        checked.append(provider)
        return .init(configured: configured.contains(provider), label: "OAuth")
    }

    func signIn(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        logins.append(provider)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func signOut(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        configured.remove(provider)
        return .init(configured: false)
    }

    func cancel(provider: PickyPiOAuthLoginProvider) { cancelled.append(provider) }
}

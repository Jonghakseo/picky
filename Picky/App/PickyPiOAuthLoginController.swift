//
//  PickyPiOAuthLoginController.swift
//  Picky
//
//  Provider-specific Pi OAuth login launched from Settings without opening a terminal.
//

import AppKit
import Combine
import Foundation

struct PickyPiOAuthLoginAuthStatus: Codable, Equatable {
    var configured: Bool
    var source: String?
    var label: String?
}

enum PickyPiOAuthLoginStatus: Equatable {
    case unknown
    case checking
    case notConfigured
    case configured(source: String?)
    case signingIn
    case signingOut
    case failed(String)
}

enum PickyPiOAuthLoginProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAICodex = "openai-codex"
    case anthropic = "anthropic"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .openAICodex: "settings.oauth.provider.openai.title"
        case .anthropic: "settings.oauth.provider.anthropic.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .openAICodex: "settings.oauth.provider.openai.subtitle"
        case .anthropic: "settings.oauth.provider.anthropic.subtitle"
        }
    }

    var iconName: String {
        switch self {
        case .openAICodex: "sparkles"
        case .anthropic: "a.circle"
        }
    }

    /// Login methods the Pi SDK offers for this provider. Only OpenAI Codex
    /// asks Picky to choose between browser callback and device code login.
    var supportedLoginMethods: [PickyPiOAuthLoginMethod] {
        switch self {
        case .openAICodex: [.browser, .deviceCode]
        case .anthropic: [.browser]
        }
    }
}

/// The user's chosen sign-in method. The raw value is the option id the Pi SDK
/// uses in its login method `select` prompt.
enum PickyPiOAuthLoginMethod: String, Equatable, Sendable {
    case browser = "browser"
    case deviceCode = "device_code"
}

/// A device code the user must enter on the provider's verification page.
struct PickyPiOAuthDeviceCode: Equatable, Sendable {
    let verificationURL: URL
    let userCode: String
}

@MainActor
protocol PickyPiOAuthLoginRunning: AnyObject {
    func authStatus(for provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus
    func signIn(
        provider: PickyPiOAuthLoginProvider,
        method: PickyPiOAuthLoginMethod,
        onDeviceCode: @escaping @MainActor (PickyPiOAuthDeviceCode) -> Void
    ) async throws -> PickyPiOAuthLoginAuthStatus
    func signOut(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus
    func cancel(provider: PickyPiOAuthLoginProvider)
}

@MainActor
final class PickyPiOAuthLoginController: ObservableObject {
    @Published private var statuses: [PickyPiOAuthLoginProvider: PickyPiOAuthLoginStatus]
    @Published private(set) var pendingSignOutProvider: PickyPiOAuthLoginProvider?
    /// Device codes waiting for the user to enter them. Present only while the
    /// matching device code sign-in is in flight.
    @Published private(set) var deviceCodes: [PickyPiOAuthLoginProvider: PickyPiOAuthDeviceCode] = [:]
    /// The method of the sign-in currently in flight, so the UI can describe
    /// what it is waiting for before the device code arrives.
    @Published private(set) var inFlightMethods: [PickyPiOAuthLoginProvider: PickyPiOAuthLoginMethod] = [:]

    private let runner: PickyPiOAuthLoginRunning
    private var tasks: [PickyPiOAuthLoginProvider: Task<Void, Never>] = [:]
    private var signInAttemptIDs: [PickyPiOAuthLoginProvider: UUID] = [:]

    init(runner: PickyPiOAuthLoginRunning) {
        self.runner = runner
        self.statuses = Dictionary(uniqueKeysWithValues: PickyPiOAuthLoginProvider.allCases.map { ($0, .unknown) })
    }

    func status(for provider: PickyPiOAuthLoginProvider) -> PickyPiOAuthLoginStatus {
        statuses[provider] ?? .unknown
    }

    var indexSummary: String {
        let configuredCount = PickyPiOAuthLoginProvider.allCases.filter { provider in
            if case .configured = status(for: provider) { return true }
            return false
        }.count
        if configuredCount == 0 {
            return L10n.t("settings.oauth.summary.none")
        }
        return L10n.t("settings.oauth.summary.configured", configuredCount, PickyPiOAuthLoginProvider.allCases.count)
    }

    func refreshAll() {
        for provider in PickyPiOAuthLoginProvider.allCases {
            refresh(provider: provider)
        }
    }

    func refresh(provider: PickyPiOAuthLoginProvider) {
        guard !isBusy(provider) else { return }
        statuses[provider] = .checking
        tasks[provider]?.cancel()
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let authStatus = try await runner.authStatus(for: provider)
                guard !Task.isCancelled else { return }
                statuses[provider] = Self.loginStatus(from: authStatus)
            } catch {
                guard !Task.isCancelled else { return }
                statuses[provider] = .failed(Self.presentableError(error))
            }
            tasks[provider] = nil
        }
    }

    func signIn(provider: PickyPiOAuthLoginProvider, method: PickyPiOAuthLoginMethod = .browser) {
        guard !isBusy(provider), provider.supportedLoginMethods.contains(method) else { return }
        statuses[provider] = .signingIn
        deviceCodes[provider] = nil
        inFlightMethods[provider] = method
        let attemptID = UUID()
        signInAttemptIDs[provider] = attemptID
        tasks[provider]?.cancel()
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let authStatus = try await runner.signIn(provider: provider, method: method) { [weak self] deviceCode in
                    // Ignore codes from a cancelled or superseded attempt.
                    guard let self, self.signInAttemptIDs[provider] == attemptID,
                          self.status(for: provider) == .signingIn else { return }
                    self.deviceCodes[provider] = deviceCode
                }
                guard !Task.isCancelled else { return }
                clearSignInProgress(provider)
                statuses[provider] = Self.loginStatus(from: authStatus)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                clearSignInProgress(provider)
                statuses[provider] = .notConfigured
            } catch {
                guard !Task.isCancelled else { return }
                clearSignInProgress(provider)
                statuses[provider] = .failed(Self.presentableError(error))
            }
            tasks[provider] = nil
        }
    }

    func requestSignOut(provider: PickyPiOAuthLoginProvider) {
        guard !isBusy(provider) else { return }
        pendingSignOutProvider = provider
    }

    func cancelSignOutConfirmation() {
        pendingSignOutProvider = nil
    }

    func confirmSignOut(provider: PickyPiOAuthLoginProvider) {
        guard pendingSignOutProvider == provider, !isBusy(provider) else { return }
        pendingSignOutProvider = nil
        statuses[provider] = .signingOut
        tasks[provider]?.cancel()
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let authStatus = try await runner.signOut(provider: provider)
                guard !Task.isCancelled else { return }
                statuses[provider] = Self.loginStatus(from: authStatus)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                statuses[provider] = .notConfigured
            } catch {
                guard !Task.isCancelled else { return }
                statuses[provider] = .failed(Self.presentableError(error))
            }
            tasks[provider] = nil
        }
    }

    func cancel(provider: PickyPiOAuthLoginProvider) {
        runner.cancel(provider: provider)
        tasks[provider]?.cancel()
        tasks[provider] = nil
        signInAttemptIDs[provider] = nil
        clearSignInProgress(provider)
        statuses[provider] = .notConfigured
        refresh(provider: provider)
    }

    private func clearSignInProgress(_ provider: PickyPiOAuthLoginProvider) {
        deviceCodes[provider] = nil
        inFlightMethods[provider] = nil
    }

    private func isBusy(_ provider: PickyPiOAuthLoginProvider) -> Bool {
        switch status(for: provider) {
        case .signingIn, .signingOut:
            return true
        default:
            return false
        }
    }

    private static func loginStatus(from authStatus: PickyPiOAuthLoginAuthStatus) -> PickyPiOAuthLoginStatus {
        if authStatus.configured {
            return .configured(source: authStatus.label ?? authStatus.source)
        }
        return .notConfigured
    }

    private static func presentableError(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? String(describing: error) : message
    }
}

@MainActor
final class PickyPiOAuthLoginAgentRunner: PickyPiOAuthLoginRunning {
    typealias OpenURL = @MainActor (URL) -> Bool

    private let client: any PickyAgentClient
    private let openURL: OpenURL
    private let statusTimeoutNanoseconds: UInt64
    private let reloadTimeoutNanoseconds: UInt64
    private var loginRequestIDs: [PickyPiOAuthLoginProvider: String] = [:]

    init(
        client: any PickyAgentClient,
        openURL: @escaping OpenURL = { NSWorkspace.shared.open($0) },
        statusTimeoutNanoseconds: UInt64 = 5_000_000_000,
        reloadTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.client = client
        self.openURL = openURL
        self.statusTimeoutNanoseconds = statusTimeoutNanoseconds
        self.reloadTimeoutNanoseconds = reloadTimeoutNanoseconds
    }

    func authStatus(for provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        try await requestStatus(provider: provider, commandType: .getPiOAuthStatus, timeoutNanoseconds: statusTimeoutNanoseconds)
    }

    func signIn(
        provider: PickyPiOAuthLoginProvider,
        method: PickyPiOAuthLoginMethod,
        onDeviceCode: @escaping @MainActor (PickyPiOAuthDeviceCode) -> Void
    ) async throws -> PickyPiOAuthLoginAuthStatus {
        let command = PickyCommandEnvelope(type: .signInPiOAuth, providerId: provider)
        loginRequestIDs[provider] = command.id
        defer {
            if loginRequestIDs[provider] == command.id {
                loginRequestIDs[provider] = nil
            }
        }

        let status: PickyPiOAuthLoginAuthStatus
        do {
            status = try await withTaskCancellationHandler(
                operation: {
                    try await awaitStatus(
                        command: command,
                        provider: provider,
                        loginMethod: method,
                        onDeviceCode: onDeviceCode,
                        timeoutNanoseconds: nil
                    )
                },
                onCancel: { [weak self] in
                    Task { @MainActor in self?.cancelRequest(provider: provider, requestId: command.id) }
                }
            )
        } catch {
            // The daemon may still be waiting on a callback or prompt when a
            // local browser/event handling failure terminates the response loop.
            cancelRequest(provider: provider, requestId: command.id)
            throw error
        }
        try await reloadAuthenticationAcrossDaemons()
        return status
    }

    func signOut(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        let status = try await requestStatus(
            provider: provider,
            commandType: .signOutPiOAuth,
            timeoutNanoseconds: statusTimeoutNanoseconds
        )
        try await reloadAuthenticationAcrossDaemons()
        return status
    }

    func cancel(provider: PickyPiOAuthLoginProvider) {
        guard let requestId = loginRequestIDs[provider] else { return }
        cancelRequest(provider: provider, requestId: requestId)
    }

    private func requestStatus(
        provider: PickyPiOAuthLoginProvider,
        commandType: PickyCommandType,
        timeoutNanoseconds: UInt64
    ) async throws -> PickyPiOAuthLoginAuthStatus {
        let command = PickyCommandEnvelope(type: commandType, providerId: provider)
        return try await awaitStatus(command: command, provider: provider, timeoutNanoseconds: timeoutNanoseconds)
    }

    private func awaitStatus(
        command: PickyCommandEnvelope,
        provider: PickyPiOAuthLoginProvider,
        loginMethod: PickyPiOAuthLoginMethod = .browser,
        onDeviceCode: @escaping @MainActor (PickyPiOAuthDeviceCode) -> Void = { _ in },
        timeoutNanoseconds: UInt64?
    ) async throws -> PickyPiOAuthLoginAuthStatus {
        let stream = client.events
        let responseTask = Task { @MainActor [client, openURL] in
            for await clientEvent in stream {
                switch clientEvent {
                case .connected, .sessionProjectionBootstrapCompletion:
                    continue
                case .disconnected:
                    throw PickyPiOAuthLoginError.disconnected
                case .recoverableError(let message):
                    throw PickyPiOAuthLoginError.daemon(message)
                case .protocolEvent(let envelope):
                    switch envelope.event {
                    case .piOAuthStatus(let event)
                        where event.requestId == command.id && event.providerId == provider:
                        return event.authStatus
                    case .piOAuthUrlRequested(let event)
                        where event.requestId == command.id && event.providerId == provider:
                        guard let url = URL(string: event.url) else {
                            throw PickyPiOAuthLoginError.invalidURL(event.url)
                        }
                        // Branch on the method the user picked, never on the
                        // payload: a browser login must not be hijacked by a
                        // stray user code, and a code login must not silently
                        // fall back to opening a browser. Status and sign-out
                        // requests never receive this event and keep `.browser`.
                        if loginMethod == .deviceCode {
                            // The user enters the code on the verification page,
                            // possibly in another browser or on another device,
                            // so show it instead of opening the page.
                            guard let userCode = event.userCode, !userCode.isEmpty else {
                                throw PickyPiOAuthLoginError.deviceCodeMissing
                            }
                            onDeviceCode(PickyPiOAuthDeviceCode(verificationURL: url, userCode: userCode))
                            continue
                        }
                        guard openURL(url) else {
                            throw PickyPiOAuthLoginError.browserOpenFailed(event.url)
                        }
                    case .piOAuthPromptRequested(let event)
                        where event.requestId == command.id && event.providerId == provider:
                        switch event.promptType {
                        case .select:
                            guard let option = event.options?.first(where: { $0.id == loginMethod.rawValue }) else {
                                throw PickyPiOAuthLoginError.loginMethodUnavailable(loginMethod)
                            }
                            try await client.send(PickyCommandEnvelope(
                                type: .answerPiOAuthPrompt,
                                requestId: event.requestId,
                                value: .string(option.id),
                                promptId: event.promptId
                            ))
                        case .manualCode:
                            // Browser OAuth races this prompt against the local callback server.
                            // Leave it pending so the callback can win; explicit user cancellation
                            // rejects it through cancelPiOAuth and releases the callback port.
                            continue
                        case .text, .secret:
                            try await client.send(PickyCommandEnvelope(
                                type: .answerPiOAuthPrompt,
                                requestId: event.requestId,
                                promptId: event.promptId,
                                cancelled: true
                            ))
                        }
                    case .error(let error) where error.commandId == command.id:
                        throw PickyPiOAuthLoginError.daemon(error.message)
                    default:
                        continue
                    }
                }
            }
            try Task.checkCancellation()
            throw PickyPiOAuthLoginError.disconnected
        }
        defer { responseTask.cancel() }

        try await client.send(command)
        guard let timeoutNanoseconds else {
            return try await withTaskCancellationHandler(
                operation: { try await responseTask.value },
                onCancel: { responseTask.cancel() }
            )
        }
        return try await withThrowingTaskGroup(of: PickyPiOAuthLoginAuthStatus.self) { group in
            // The waiter is intentionally unstructured so it can subscribe
            // before send(). Cancel it before the task-group scope waits for
            // children, otherwise the timeout child can win while the event
            // stream waiter remains suspended forever.
            defer {
                responseTask.cancel()
                group.cancelAll()
            }
            group.addTask { try await responseTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw PickyPiOAuthLoginError.timedOut
            }
            return try await group.next()!
        }
    }

    private func reloadAuthenticationAcrossDaemons() async throws {
        let command = PickyCommandEnvelope(type: .reloadPiAuthentication)
        let stream = client.events
        let deliveredCount = try await client.broadcast(command)
        guard deliveredCount > 0 else { throw PickyPiOAuthLoginError.disconnected }

        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { @MainActor in
                var receivedCount = 0
                for await clientEvent in stream {
                    switch clientEvent {
                    case .protocolEvent(let envelope):
                        switch envelope.event {
                        case .piAuthenticationReloaded(let event) where event.requestId == command.id:
                            receivedCount += 1
                            if receivedCount >= deliveredCount { return }
                        case .error(let error) where error.commandId == command.id:
                            throw PickyPiOAuthLoginError.daemon(error.message)
                        default:
                            continue
                        }
                    case .disconnected:
                        throw PickyPiOAuthLoginError.disconnected
                    case .recoverableError(let message):
                        throw PickyPiOAuthLoginError.daemon(message)
                    case .connected, .sessionProjectionBootstrapCompletion:
                        continue
                    }
                }
                throw PickyPiOAuthLoginError.disconnected
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.reloadTimeoutNanoseconds)
                throw PickyPiOAuthLoginError.timedOut
            }
            _ = try await group.next()
        }
    }

    private func cancelRequest(provider: PickyPiOAuthLoginProvider, requestId: String) {
        guard loginRequestIDs[provider] == requestId else { return }
        loginRequestIDs[provider] = nil
        Task { [client] in
            try? await client.send(PickyCommandEnvelope(type: .cancelPiOAuth, requestId: requestId))
        }
    }
}

enum PickyPiOAuthLoginError: LocalizedError, Equatable {
    case daemon(String)
    case disconnected
    case timedOut
    case invalidURL(String)
    case browserOpenFailed(String)
    case loginMethodUnavailable(PickyPiOAuthLoginMethod)
    case deviceCodeMissing

    var errorDescription: String? {
        switch self {
        case .daemon(let message): message
        case .disconnected: L10n.t("settings.oauth.disconnected")
        case .timedOut: L10n.t("settings.oauth.timedOut")
        case .invalidURL(let value): L10n.t("settings.oauth.invalidURL", value)
        case .browserOpenFailed(let value): L10n.t("settings.oauth.browserOpenFailed", value)
        case .loginMethodUnavailable(.browser): L10n.t("settings.oauth.browserUnavailable")
        case .loginMethodUnavailable(.deviceCode): L10n.t("settings.oauth.deviceCodeUnavailable")
        case .deviceCodeMissing: L10n.t("settings.oauth.deviceCodeMissing")
        }
    }
}

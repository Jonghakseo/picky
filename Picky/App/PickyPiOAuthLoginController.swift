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
    case failed(String)
}

enum PickyPiOAuthLoginProvider: String, CaseIterable, Identifiable {
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
}

@MainActor
protocol PickyPiOAuthLoginRunning: AnyObject {
    func authStatus(for provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus
    func signIn(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus
    func cancel(provider: PickyPiOAuthLoginProvider)
}

@MainActor
final class PickyPiOAuthLoginController: ObservableObject {
    @Published private var statuses: [PickyPiOAuthLoginProvider: PickyPiOAuthLoginStatus]

    private let runner: PickyPiOAuthLoginRunning
    private var tasks: [PickyPiOAuthLoginProvider: Task<Void, Never>] = [:]

    init(runner: PickyPiOAuthLoginRunning? = nil) {
        self.runner = runner ?? PickyPiOAuthLoginProcessRunner()
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
        guard !isSigningIn(provider) else { return }
        statuses[provider] = .checking
        tasks[provider]?.cancel()
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let authStatus = try await runner.authStatus(for: provider)
                statuses[provider] = Self.loginStatus(from: authStatus)
            } catch {
                statuses[provider] = .failed(Self.presentableError(error))
            }
            tasks[provider] = nil
        }
    }

    func signIn(provider: PickyPiOAuthLoginProvider) {
        guard !isSigningIn(provider) else { return }
        statuses[provider] = .signingIn
        tasks[provider]?.cancel()
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            do {
                let authStatus = try await runner.signIn(provider: provider)
                statuses[provider] = Self.loginStatus(from: authStatus)
            } catch is CancellationError {
                statuses[provider] = .notConfigured
            } catch {
                statuses[provider] = .failed(Self.presentableError(error))
            }
            tasks[provider] = nil
        }
    }

    func cancel(provider: PickyPiOAuthLoginProvider) {
        runner.cancel(provider: provider)
        tasks[provider]?.cancel()
        tasks[provider] = nil
        statuses[provider] = .notConfigured
    }

    private func isSigningIn(_ provider: PickyPiOAuthLoginProvider) -> Bool {
        if case .signingIn = status(for: provider) { return true }
        return false
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
final class PickyPiOAuthLoginProcessRunner: PickyPiOAuthLoginRunning {
    private enum Mode: String {
        case status
        case login
    }

    private struct NodeInvocation {
        let executableURL: URL
        let argumentPrefix: [String]
    }

    private var processes: [PickyPiOAuthLoginProvider: Process] = [:]

    func authStatus(for provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        try await runNode(provider: provider, mode: .status)
    }

    func signIn(provider: PickyPiOAuthLoginProvider) async throws -> PickyPiOAuthLoginAuthStatus {
        try await runNode(provider: provider, mode: .login)
    }

    func cancel(provider: PickyPiOAuthLoginProvider) {
        processes[provider]?.terminate()
        processes[provider] = nil
    }

    private func runNode(provider: PickyPiOAuthLoginProvider, mode: Mode) async throws -> PickyPiOAuthLoginAuthStatus {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PickyPiOAuthLoginAuthStatus, Error>) in
                    do {
                        let invocation = Self.nodeInvocation()
                        let process = Process()
                        let stdout = Pipe()
                        let stderr = Pipe()
                        let stdin = Pipe()

                        process.executableURL = invocation.executableURL
                        process.arguments = invocation.argumentPrefix + ["--input-type=module", "-", provider.rawValue, mode.rawValue]
                        process.standardInput = stdin
                        process.standardOutput = stdout
                        process.standardError = stderr
                        process.environment = Self.processEnvironment()

                        process.terminationHandler = { [weak self] process in
                            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                            Task { @MainActor in
                                self?.processes[provider] = nil
                                if process.terminationStatus == 0 {
                                    do {
                                        continuation.resume(returning: try Self.parseResult(stdoutText))
                                    } catch {
                                        continuation.resume(throwing: error)
                                    }
                                } else {
                                    let message = [stderrText, stdoutText]
                                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .first { !$0.isEmpty }
                                        ?? "Pi OAuth helper exited with code \(process.terminationStatus)."
                                    continuation.resume(throwing: PickyPiOAuthLoginError.helperFailed(message))
                                }
                            }
                        }

                        try process.run()
                        processes[provider] = process
                        if let scriptData = Self.nodeScript.data(using: .utf8) {
                            stdin.fileHandleForWriting.write(scriptData)
                        }
                        stdin.fileHandleForWriting.closeFile()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            },
            onCancel: { [weak self] in
                Task { @MainActor in self?.cancel(provider: provider) }
            }
        )
    }

    nonisolated static func parseResult(_ output: String) throws -> PickyPiOAuthLoginAuthStatus {
        let prefix = "PICKY_PI_OAUTH_RESULT "
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix(prefix) })
        else {
            throw PickyPiOAuthLoginError.missingResult(output)
        }
        let jsonText = String(line.dropFirst(prefix.count))
        guard let data = jsonText.data(using: .utf8) else {
            throw PickyPiOAuthLoginError.missingResult(output)
        }
        return try JSONDecoder().decode(PickyPiOAuthLoginAuthStatus.self, from: data)
    }

    private static func nodeInvocation() -> NodeInvocation {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["PICKY_NODE_PATH"], fileManager.isExecutableFile(atPath: override) {
            return NodeInvocation(executableURL: URL(fileURLWithPath: override), argumentPrefix: [])
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("agentd-runtime/bin/node").path
            if fileManager.isExecutableFile(atPath: bundledNode) {
                return NodeInvocation(executableURL: URL(fileURLWithPath: bundledNode), argumentPrefix: [])
            }
        }

        return NodeInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), argumentPrefix: ["node"])
    }

    nonisolated private static let defaultPATHEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    nonisolated static func mergedPATH(existingPATH: String?) -> String {
        var entries = existingPATH?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        for entry in defaultPATHEntries where !entries.contains(entry) {
            entries.append(entry)
        }
        return entries.joined(separator: ":")
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = mergedPATH(existingPATH: environment["PATH"])
        if environment["LANG"]?.isEmpty ?? true {
            environment["LANG"] = "en_US.UTF-8"
        }
        if environment["LC_CTYPE"]?.isEmpty ?? true {
            environment["LC_CTYPE"] = "en_US.UTF-8"
        }
        return environment
    }

    nonisolated static let nodeScript = #"""
        import { execFileSync, spawn } from "node:child_process";
        import { existsSync, realpathSync } from "node:fs";
        import { dirname, join } from "node:path";
        import { pathToFileURL } from "node:url";

        const providerId = process.argv[2];
        const mode = process.argv[3] ?? "status";

        function providerModuleCandidates() {
          const candidates = [];
          if (process.env.PICKY_PI_AUTH_STORAGE_MODULE) {
            candidates.push(process.env.PICKY_PI_AUTH_STORAGE_MODULE);
          }
          try {
            const piBin = execFileSync("/usr/bin/env", ["bash", "-lc", "command -v pi"], { encoding: "utf8" }).trim();
            if (piBin) {
              const realPiBin = realpathSync(piBin);
              const distDir = dirname(realPiBin);
              candidates.push(join(distDir, "core", "auth-storage.js"));
            }
          } catch {}
          candidates.push(
            "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/auth-storage.js",
            "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/auth-storage.js"
          );
          return [...new Set(candidates)].filter(Boolean);
        }

        async function loadAuthStorage() {
          const tried = [];
          for (const candidate of providerModuleCandidates()) {
            tried.push(candidate);
            if (!existsSync(candidate)) continue;
            try {
              return await import(pathToFileURL(candidate).href);
            } catch (error) {
              console.error(`Failed to import ${candidate}: ${error.message}`);
            }
          }
          throw new Error(`Could not find Pi auth-storage.js. Tried:\n${tried.join("\n")}`);
        }

        function emitResult(status) {
          console.log(`PICKY_PI_OAUTH_RESULT ${JSON.stringify(status)}`);
        }

        function readStatus(authStorage, providerId) {
          const status = authStorage.getAuthStatus(providerId);
          return {
            configured: Boolean(status.configured),
            source: status.source ?? null,
            label: status.label ?? null,
          };
        }

        function openBrowser(url) {
          try {
            const child = spawn("/usr/bin/open", [url], { detached: true, stdio: "ignore" });
            child.unref();
          } catch (error) {
            console.error(`Could not open the browser automatically: ${error.message}`);
            console.error(url);
          }
        }

        const { AuthStorage } = await loadAuthStorage();
        const authStorage = AuthStorage.create();
        const provider = authStorage.getOAuthProviders().find((item) => item.id === providerId);
        if (!provider) {
          const known = authStorage.getOAuthProviders().map((item) => item.id).join(", ");
          throw new Error(`Unknown OAuth provider '${providerId}'. Known providers: ${known}`);
        }

        if (mode === "status") {
          emitResult(readStatus(authStorage, providerId));
          process.exit(0);
        }

        await authStorage.login(providerId, {
          onAuth: ({ url }) => openBrowser(url),
          onDeviceCode: ({ verificationUri, userCode }) => {
            openBrowser(verificationUri);
            console.error(`Enter device code: ${userCode}`);
          },
          onProgress: (message) => {
            if (message) console.error(message);
          },
          onPrompt: async ({ message }) => {
            throw new Error(`${message}\nAutomatic browser callback did not complete. Run 'pi /login' and choose this provider for the manual paste fallback.`);
          },
          onSelect: async ({ options }) => {
            const browserLogin = options.find((option) => option.id === "browser");
            if (!browserLogin) {
              throw new Error("Picky only supports browser-based OAuth login from Settings.");
            }
            return browserLogin.id;
          }
        });

        authStorage.reload();
        const nextStatus = readStatus(authStorage, providerId);
        if (!nextStatus.configured) {
          throw new Error("OAuth flow ended, but Pi auth storage still does not report configured credentials.");
        }
        emitResult(nextStatus);
        """#
}

enum PickyPiOAuthLoginError: LocalizedError, Equatable {
    case helperFailed(String)
    case missingResult(String)

    var errorDescription: String? {
        switch self {
        case .helperFailed(let message):
            return message
        case .missingResult(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Pi OAuth helper did not return a status."
                : "Pi OAuth helper did not return a status: \(trimmed)"
        }
    }
}

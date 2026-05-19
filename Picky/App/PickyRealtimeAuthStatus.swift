//
//  PickyRealtimeAuthStatus.swift
//  Picky
//
//  Single source of truth for "can Picky talk to OpenAI Realtime right now?".
//
//  PICKY_REALTIME_OPT_IN=1 makes Picky a Realtime-only product: every PTT, text
//  submission, and Pickle-completion reply is expected to go through the Realtime
//  websocket. When the user has neither finished Codex/ChatGPT OAuth nor pasted
//  a Platform API key, agentd's connect attempt fails with "API key required"
//  and the user is left staring at an empty bubble. This helper centralises the
//  "is auth ready" answer so the runtime entry points (PTT, text, Pickle reply)
//  and the boot flow (onboarding completion gate) can all reject early with the
//  same message.
//
//  Two auth surfaces are supported:
//    * Codex/ChatGPT OAuth — confirmed by looking up `~/.codex/auth.json` (or
//      the `CODEX_AUTH_FILE` override pi-coding-agent honours). agentd actually
//      tries pi AuthStorage first, but in practice the file is the canonical
//      copy on macOS so a presence check is good enough for a "not signed in"
//      gate. We avoid running pi's Node-side resolver inline because that lives
//      in agentd, and we still want this helper to be cheap, sync, and
//      unit-testable.
//    * Platform API key — the OpenAI Platform `sk-…` paste or the Azure
//      `api-key` header. Both flow through `PickyOpenAIRealtimeSettings.apiKey`,
//      so a non-empty trimmed string means "user pasted something".

import Foundation

@MainActor
struct PickyRealtimeAuthStatus: Equatable {
    enum Mode: String, Equatable {
        case codexOAuth
        case openAIPlatformKey
        case azureKey
    }

    enum BlockReason: String, Equatable {
        /// `authMode == .codexOAuth` but `~/.codex/auth.json` is missing or
        /// has no access token.
        case missingCodexOAuth
        /// `authMode == .apiKey` for the OpenAI Platform provider and the
        /// pasted key is empty.
        case missingPlatformKey
        /// Azure Realtime is selected and the `api-key` paste is empty. Azure
        /// ignores `authMode` because it always uses an `api-key` header.
        case missingAzureKey
    }

    /// Currently-chosen authentication surface. Useful for the Settings
    /// indicator label and for the gate message ("Sign in to ChatGPT" vs
    /// "Paste an OpenAI API key").
    let mode: Mode
    /// `nil` when the runtime is ready to connect.
    let blockReason: BlockReason?

    var isAuthenticated: Bool { blockReason == nil }
}

/// Resolves the current Realtime auth status from settings + filesystem state.
///
/// The inspector is injectable so unit tests can replace the filesystem probe
/// without touching `~/.codex/auth.json` on the developer's machine.
@MainActor
enum PickyRealtimeAuthStatusInspector {
    /// Hook that reports whether a Codex OAuth access token is currently on
    /// disk. Defaults to inspecting `~/.codex/auth.json` (or the
    /// `CODEX_AUTH_FILE` override). Replace in tests via
    /// `currentStatus(settings:codexAuthPresent:)`.
    static let defaultCodexAuthPresent: () -> Bool = {
        let env = ProcessInfo.processInfo.environment
        let explicitPath = env["CODEX_AUTH_FILE"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let homeOverride = env["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let path = explicitPath
            ?? (homeOverride.map { "\($0)/auth.json" })
            ?? "\(NSHomeDirectory())/.codex/auth.json"
        return Self.codexAuthTokenPresent(atPath: path)
    }

    static func currentStatus(
        settings: PickySettings = PickySettingsStore().load(),
        codexAuthPresent: () -> Bool = defaultCodexAuthPresent
    ) -> PickyRealtimeAuthStatus {
        let realtime = settings.openAIRealtime.normalized()
        let trimmedKey = realtime.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if realtime.provider == .azureOpenAI {
            return PickyRealtimeAuthStatus(
                mode: .azureKey,
                blockReason: trimmedKey.isEmpty ? .missingAzureKey : nil
            )
        }

        switch realtime.authMode {
        case .apiKey:
            return PickyRealtimeAuthStatus(
                mode: .openAIPlatformKey,
                blockReason: trimmedKey.isEmpty ? .missingPlatformKey : nil
            )
        case .codexOAuth:
            return PickyRealtimeAuthStatus(
                mode: .codexOAuth,
                blockReason: codexAuthPresent() ? nil : .missingCodexOAuth
            )
        }
    }

    /// True when the file at `path` exists and contains a non-empty
    /// `access_token` (top-level or inside a `tokens` object — the two layouts
    /// the Codex CLI has shipped historically).
    static func codexAuthTokenPresent(atPath path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let token = json["access_token"] as? String,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let tokens = json["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
}

extension PickyRealtimeAuthStatus.BlockReason {
    /// Short, user-facing description of what the user must do to unblock the
    /// runtime. Used by both the boot-time alert and the runtime fallback
    /// strings inside CompanionManager so the wording stays in one place.
    var localizedActionMessage: String {
        switch self {
        case .missingCodexOAuth:
            return "ChatGPT 계정으로 로그인하거나 Settings에서 OpenAI API key를 입력해 주세요."
        case .missingPlatformKey:
            return "Settings에서 OpenAI Platform API key를 입력해 주세요."
        case .missingAzureKey:
            return "Settings에서 Azure Realtime API key를 입력해 주세요."
        }
    }
}

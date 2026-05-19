//
//  PickyRealtimeAuthGate.swift
//  Picky
//
//  Boot-time and post-onboarding gate that surfaces a single, blocking alert
//  when PICKY_REALTIME_OPT_IN=1 is set but the user has not yet finished
//  authenticating against OpenAI Realtime.
//
//  PICKY_REALTIME_OPT_IN=1 makes Picky a Realtime-only product: every PTT,
//  text, and Pickle-completion turn goes through the OpenAI Realtime
//  websocket. Without a Codex/ChatGPT OAuth token (or a Platform/Azure API
//  key paste) agentd's connect attempt fails before a single byte of speech
//  reaches the user. The runtime entry points (CompanionManager) carry their
//  own fail-closed guards as a safety net, but those only fire when the user
//  actively initiates an action — so the boot path needs its own indication
//  that "this build won't work until you sign in".
//
//  Opt-in=0 builds bypass this gate entirely (the Pi runtime needs no Realtime
//  auth) so the legacy behaviour is preserved untouched.

import AppKit
import Foundation

@MainActor
final class PickyRealtimeAuthGate {
    /// Identifier strings the inspector returns. Surfaced here so tests can
    /// assert that the alert was rendered with the right message for a given
    /// block reason without scraping `NSAlert.messageText`.
    typealias BlockReason = PickyRealtimeAuthStatus.BlockReason

    /// Hook for presenting the alert. Tests inject a recorder to assert the
    /// gate fired and which reason it surfaced; production wires through to
    /// `NSAlert.runModal()` via the default initialiser.
    typealias AlertPresenter = (_ reason: BlockReason, _ onOpenSettings: @escaping () -> Void) -> Void

    /// Opens the in-app Settings panel scrolled to the realtime auth fields.
    /// Tests inject a stub; production wires this to the MenuBar settings
    /// presenter.
    typealias OpenSettingsHandler = () -> Void

    /// Returns the *effective* runtime mode (honours `realtimeOptIn`). Tests
    /// inject `.openAIRealtime` or `.pi` independently of the build flag.
    typealias RuntimeModeProvider = @MainActor () -> PickyMainAgentRuntimeMode

    /// Returns the current Realtime auth status; defaults to live settings +
    /// the inspector's default filesystem probe.
    typealias AuthStatusProvider = @MainActor () -> PickyRealtimeAuthStatus

    private let runtimeModeProvider: RuntimeModeProvider
    private let authStatusProvider: AuthStatusProvider
    private let alertPresenter: AlertPresenter
    private let openSettings: OpenSettingsHandler

    /// `true` once the alert has been shown in this app session. We never want
    /// to nag the user a second time inside the same launch — they may be in
    /// the middle of pasting a key into Settings and a re-entrant alert would
    /// stomp the focus. PTT and text-submit guards still fail closed if the
    /// user dismisses without finishing, so this is purely an anti-spam flag.
    private var hasAlertedDuringSession = false

    init(
        runtimeModeProvider: @escaping RuntimeModeProvider = { AppBundleConfiguration.effectiveRuntimeMode },
        authStatusProvider: @escaping AuthStatusProvider = { PickyRealtimeAuthStatusInspector.currentStatus() },
        openSettings: @escaping OpenSettingsHandler,
        alertPresenter: AlertPresenter? = nil
    ) {
        self.runtimeModeProvider = runtimeModeProvider
        self.authStatusProvider = authStatusProvider
        self.openSettings = openSettings
        self.alertPresenter = alertPresenter ?? Self.makeDefaultAlertPresenter()
    }

    /// Evaluates the gate and, if necessary, presents the blocking alert.
    /// Safe to call multiple times — the gate de-dupes inside one session.
    func evaluate() {
        guard runtimeModeProvider() == .openAIRealtime else { return }
        let status = authStatusProvider()
        guard let reason = status.blockReason else {
            // Once auth is healthy we re-arm the "haven't alerted yet" flag so
            // the gate can fire again if the user revokes their token mid
            // session (rare, but cheap to handle).
            hasAlertedDuringSession = false
            return
        }
        guard !hasAlertedDuringSession else { return }
        hasAlertedDuringSession = true
        alertPresenter(reason) { [openSettings] in openSettings() }
    }

    /// Hook used by tests to observe state without poking the modal stack.
    var hasAlertedDuringSessionForTesting: Bool { hasAlertedDuringSession }

    private static func makeDefaultAlertPresenter() -> AlertPresenter {
        { reason, onOpenSettings in
            let alert = NSAlert()
            alert.messageText = Self.headlineMessage(for: reason)
            alert.informativeText = reason.localizedActionMessage
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Settings 열기")
            alert.addButton(withTitle: "나중에")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                onOpenSettings()
            }
        }
    }

    private static func headlineMessage(for reason: BlockReason) -> String {
        switch reason {
        case .missingCodexOAuth:
            return "Picky Realtime 사용을 위해 ChatGPT 로그인이 필요해요"
        case .missingPlatformKey:
            return "Picky Realtime 사용을 위해 OpenAI API 키가 필요해요"
        case .missingAzureKey:
            return "Picky Realtime 사용을 위해 Azure Realtime API 키가 필요해요"
        }
    }
}

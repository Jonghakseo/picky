//
//  PickyHubRemoteAccessPresentation.swift
//  Picky
//
//  Pure presentation policy for the "원격 접속" settings section: what the status
//  line says, whether pairing can start, which speech-permission action is even
//  possible, and what the pairing QR encodes. Keeping the rules out of the views
//  means they can be read in one place instead of being spread across branches.
//

import Foundation
import Speech
import SwiftUI

/// One line under the toggle. `failed` keeps the gateway's own reason because
/// it already names the missing file, the exit code, or the CLI message.
enum PickyHubRemoteAccessStatus: Equatable {
    case off
    case starting
    case running(address: String)
    /// Remote access is off (`localOnly`): the server runs for this Mac's
    /// browser alone, so there is no address to hand a phone.
    case runningLocalOnly
    /// The gateway is up but the entrance has no address yet, so a phone has
    /// nothing to open. Pairing is unavailable in this state for the two
    /// entrances that need a public origin.
    case runningWithoutAddress
    /// The gateway is up and Picky's own temporary tunnel is still getting its
    /// address. Nothing for the user to fix yet.
    case waitingForAddress
    case failed(reason: String)

    static func resolve(
        isEnabled: Bool,
        gatewayState: PickyRemoteGatewayState,
        entranceURL: String?,
        isEntranceAddressPending: Bool = false,
        isLocalOnly: Bool = false
    ) -> PickyHubRemoteAccessStatus {
        guard isEnabled else { return .off }
        switch gatewayState {
        // `stopped` while the setting is on is the gap between the save and the
        // launcher's first transition, so it reads as starting rather than off.
        case .stopped, .starting:
            return .starting
        case .failed(let reason):
            return .failed(reason: reason)
        case .running:
            if isLocalOnly { return .runningLocalOnly }
            guard let entranceURL, !entranceURL.isEmpty else {
                return isEntranceAddressPending ? .waitingForAddress : .runningWithoutAddress
            }
            return .running(address: entranceURL)
        }
    }

    var tone: PickyHubInlineStatusTone {
        switch self {
        case .off: .neutral
        case .starting: .neutral
        case .running: .success
        case .runningLocalOnly: .success
        case .runningWithoutAddress: .warning
        case .waitingForAddress: .neutral
        case .failed: .error
        }
    }

    var message: String {
        switch self {
        case .off: L10n.t("settings.remote.status.off")
        case .starting: L10n.t("settings.remote.status.starting")
        case .running(let address): L10n.t("settings.remote.status.running", address)
        case .runningLocalOnly: L10n.t("settings.remote.status.runningLocalOnly")
        case .runningWithoutAddress: L10n.t("settings.remote.status.runningWithoutAddress")
        case .waitingForAddress: L10n.t("settings.remote.status.waitingForAddress")
        case .failed(let reason): reason
        }
    }

    /// Only a failure offers an action: the launcher's backoff can be up to 30
    /// seconds, and a resolve failure never retries on its own.
    var retryTitle: LocalizedStringKey? {
        if case .failed = self { return "settings.remote.status.retry" }
        return nil
    }
}

/// Why the "폰 연결" button is or is not usable.
enum PickyHubRemotePairingAvailability: Equatable {
    case available
    case needsRemoteAccessOn
    case needsEntrance
    /// The gateway runs but the hub socket is down, so `hub.pairing.start`
    /// would be dropped on the way out and the sheet would wait for a code that
    /// is never requested.
    case needsConnection

    static func resolve(
        isRunning: Bool,
        isHubConnected: Bool,
        entrance: PickyRemoteEntrance,
        publicURL: String?
    ) -> PickyHubRemotePairingAvailability {
        guard isRunning else { return .needsRemoteAccessOn }
        guard isHubConnected else { return .needsConnection }
        // Loopback pairing still works from this Mac's own browser, which is
        // how the PWA is tested before a tunnel exists.
        if entrance == .localOnly { return .available }
        guard let publicURL, !publicURL.isEmpty else { return .needsEntrance }
        return .available
    }

    var isAvailable: Bool { self == .available }

    /// The key, not the resolved string, so rows keep using `LocalizedStringKey`.
    var detailKey: String {
        switch self {
        case .available: "settings.remote.pair.detail"
        case .needsRemoteAccessOn: "settings.remote.pair.disabledOff"
        case .needsEntrance: "settings.remote.pair.disabledEntrance"
        case .needsConnection: "settings.remote.pair.disabledDisconnected"
        }
    }
}

/// The settings page is the only place allowed to raise the speech dialog, and
/// only while the answer is still open. A denied Mac gets a link instead.
enum PickyHubRemoteSpeechPermission: Equatable {
    case hidden
    case askOnThisMac
    case blocked

    static func resolve(
        readiness: PickyRemoteDictationReadiness,
        authorization: SFSpeechRecognizerAuthorizationStatus
    ) -> PickyHubRemoteSpeechPermission {
        // Any other readiness is either fine or a service problem the voice
        // settings own; this row would only add noise there.
        guard readiness == .needsPermission else { return .hidden }
        return authorization == .notDetermined ? .askOnThisMac : .blocked
    }
}

enum PickyHubRemotePairingPayload {
    /// The gateway's own URL wins. The fallbacks cover the gap before it
    /// reports one, and loopback pairing, which has no https origin at all.
    static func resolve(
        session: PickyRemotePairingSession,
        entrance: PickyRemoteEntrance,
        publicURL: String?,
        localURL: String
    ) -> String? {
        if let payload = PickyRemotePairingSession.qrPayload(
            publicURL: publicURL,
            code: session.code,
            gatewayURL: session.url
        ) {
            return payload
        }
        guard entrance == .localOnly else { return nil }
        let code = session.code.replacingOccurrences(of: "-", with: "").uppercased()
        guard !code.isEmpty, !localURL.isEmpty else { return nil }
        return "\(localURL)/#pair=\(code)"
    }

    /// What the numbered steps tell the user to type into the phone.
    static func address(entrance: PickyRemoteEntrance, publicURL: String?, localURL: String) -> String {
        if entrance == .localOnly { return localURL }
        return publicURL ?? localURL
    }
}

enum PickyHubRemoteDeviceFormatter {
    static func lastSeen(_ date: Date?, locale: Locale, now: Date = Date()) -> String {
        guard let date else { return L10n.t("settings.remote.devices.neverSeen") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return L10n.t("settings.remote.devices.lastSeen", formatter.localizedString(for: date, relativeTo: now))
    }
}

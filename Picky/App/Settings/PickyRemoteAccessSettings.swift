//
//  PickyRemoteAccessSettings.swift
//  Picky
//
//  Persisted configuration for remote phone access (docs/remote-pwa-plan.md).
//  Off by default: nothing listens and no process is launched until the user
//  turns it on in Settings.
//

import Foundation

/// How the phone reaches this Mac. Picky never operates a network of its own:
/// it points at the user's tailnet or tunnel, or runs the user's own
/// `cloudflared` for a temporary address.
enum PickyRemoteEntrance: String, Codable, CaseIterable, Identifiable {
    /// Tailscale Serve on the user's own tailnet. Picky can toggle the serve
    /// mapping with the Tailscale CLI, but only when the user presses a button.
    case tailscale
    /// Cloudflare, either a temporary address Picky opens with `cloudflared`
    /// or a tunnel on the user's domain (see `PickyRemoteCloudflareMode`).
    case cloudflare
    /// Loopback only. Useful for testing the PWA on this Mac's browser.
    case localOnly

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .tailscale: "settings.remote.entrance.tailscale"
        case .cloudflare: "settings.remote.entrance.cloudflare"
        case .localOnly: "settings.remote.entrance.localOnly"
        }
    }
}

/// Where the Cloudflare entrance's address comes from.
enum PickyRemoteCloudflareMode: String, Codable, CaseIterable, Identifiable {
    /// Picky runs `cloudflared tunnel --url` (a Quick Tunnel) while remote access
    /// is on. No account or domain, but the `trycloudflare.com` address changes
    /// every time the tunnel starts, so phones have to pair again.
    case quick
    /// A named tunnel the user runs on their own domain; Picky stores the URL.
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .quick: "settings.remote.cloudflare.mode.quick"
        case .custom: "settings.remote.cloudflare.mode.custom"
        }
    }
}

struct PickyRemoteAccessSettings: Codable, Equatable {
    /// Master switch. `false` means no gateway process and no listening socket.
    var enabled: Bool
    var entrance: PickyRemoteEntrance
    var cloudflareMode: PickyRemoteCloudflareMode
    /// Public https origin for the Cloudflare entrance, without a trailing slash.
    var cloudflareURL: String
    /// Loopback port for the gateway process.
    var port: Int
    /// Holds a `ProcessInfo` activity so the Mac does not idle-sleep while the
    /// phone may need it. Only active while remote access is actually running.
    var keepAwake: Bool

    static let defaultPort = 17640
    static let portRange: ClosedRange<Int> = 1024...65535

    static let defaults = PickyRemoteAccessSettings(
        enabled: false,
        entrance: .tailscale,
        cloudflareMode: .quick,
        cloudflareURL: "",
        port: defaultPort,
        keepAwake: false
    )

    /// A saved tunnel address means the user already runs their own tunnel;
    /// otherwise the temporary address is the one that works without setup.
    static func defaultCloudflareMode(cloudflareURL: String) -> PickyRemoteCloudflareMode {
        cloudflareURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .quick : .custom
    }

    init(
        enabled: Bool = false,
        entrance: PickyRemoteEntrance = .tailscale,
        cloudflareMode: PickyRemoteCloudflareMode? = nil,
        cloudflareURL: String = "",
        port: Int = PickyRemoteAccessSettings.defaultPort,
        keepAwake: Bool = false
    ) {
        self.enabled = enabled
        self.entrance = entrance
        self.cloudflareMode = cloudflareMode ?? Self.defaultCloudflareMode(cloudflareURL: cloudflareURL)
        self.cloudflareURL = cloudflareURL
        self.port = PickyRemoteAccessSettings.clampedPort(port)
        self.keepAwake = keepAwake
    }

    enum CodingKeys: String, CodingKey {
        case enabled, entrance, cloudflareMode, cloudflareURL, port, keepAwake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickyRemoteAccessSettings.defaults
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        // An unknown entrance (older or newer build) falls back to the default
        // rather than failing the whole settings file.
        entrance = (try? container.decodeIfPresent(PickyRemoteEntrance.self, forKey: .entrance)) ?? defaults.entrance
        cloudflareURL = try container.decodeIfPresent(String.self, forKey: .cloudflareURL) ?? defaults.cloudflareURL
        cloudflareMode = (try? container.decodeIfPresent(PickyRemoteCloudflareMode.self, forKey: .cloudflareMode))
            ?? Self.defaultCloudflareMode(cloudflareURL: cloudflareURL)
        port = Self.clampedPort(try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port)
        keepAwake = try container.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? defaults.keepAwake
    }

    static func clampedPort(_ value: Int) -> Int {
        portRange.contains(value) ? value : defaultPort
    }

    /// Whether Picky itself has to run `cloudflared` for these settings.
    var usesQuickTunnel: Bool {
        enabled && entrance == .cloudflare && cloudflareMode == .quick
    }

    /// The https origin the phone opens, or `nil` when the entrance has no
    /// address yet. Drives pairing URLs and Web Push.
    func publicURL(tailscaleHostname: String?, quickTunnelURL: String? = nil) -> String? {
        switch entrance {
        case .tailscale:
            guard let host = tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
            return "https://\(host)"
        case .cloudflare:
            switch cloudflareMode {
            case .quick: return quickTunnelURL.flatMap(Self.normalizedPublicURL)
            case .custom: return Self.normalizedPublicURL(cloudflareURL)
            }
        case .localOnly:
            return nil
        }
    }

    /// Accepts what a user realistically pastes (trailing slash, missing
    /// scheme) and returns a bare https origin, or `nil` when it is not usable.
    static func normalizedPublicURL(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://\(trimmed)" }
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        var normalized = "https://\(host)"
        if let port = components.port { normalized += ":\(port)" }
        let path = components.path
        if !path.isEmpty, path != "/" { normalized += path }
        return normalized
    }
}

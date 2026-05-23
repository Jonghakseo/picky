//
//  PickyDeepLink.swift
//  Picky
//
//  Parses `picky://...` URLs the LLM emits inside conversation markdown so a
//  click on `[label](picky://settings/cursorBubbles)` opens the right screen
//  in the companion panel. Keep this list in sync with
//  `PICKY_DEEP_LINK_ROUTES` in `agentd/src/application/user-guide-tool.ts` —
//  that's the table the LLM is taught to draw from.
//

import Foundation

/// Resolved destination for a `picky://` link. The companion panel always
/// opens on a tab, and Settings deep links additionally drill into a route.
struct PickyDeepLink: Equatable {
    enum Tab: Equatable {
        case status
        case messages
        case settings
    }

    var tab: Tab
    var settingsRoute: CompanionPanelSettingsRoute?

    init(tab: Tab, settingsRoute: CompanionPanelSettingsRoute? = nil) {
        self.tab = tab
        self.settingsRoute = settingsRoute
    }

    /// Parses `picky://panel/<tab>` and `picky://settings/<route>`. Returns
    /// `nil` for any other scheme or for an unknown route key so the caller
    /// can fall back to the system URL handler (e.g. https links).
    init?(url: URL) {
        guard url.scheme?.lowercased() == "picky" else { return nil }

        // `picky://panel/status` parses as host=`panel`, path=`/status`.
        let host = url.host?.lowercased() ?? ""
        let firstPathComponent = url.pathComponents.first { $0 != "/" } ?? ""

        switch host {
        case "panel":
            switch firstPathComponent {
            case "status": self = PickyDeepLink(tab: .status)
            case "messages": self = PickyDeepLink(tab: .messages)
            case "settings": self = PickyDeepLink(tab: .settings)
            default: return nil
            }
        case "settings":
            guard let route = CompanionPanelSettingsRoute.fromDeepLinkPath(firstPathComponent) else { return nil }
            self = PickyDeepLink(tab: .settings, settingsRoute: route)
        default:
            return nil
        }
    }
}

extension CompanionPanelSettingsRoute {
    /// Path component used in `picky://settings/<path>`. Mirrors the enum
    /// case name 1:1 so the registry stays trivial to audit, except for the
    /// two legacy paths (`cursorBubbles`, `notification`) that were merged
    /// into `.overlayAndNotifications` — they alias to the new route so
    /// previously-emitted assistant links and any external bookmarks keep
    /// working.
    static func fromDeepLinkPath(_ path: String) -> CompanionPanelSettingsRoute? {
        switch path {
        case "general": return .general
        case "mainAgent": return .mainAgent
        case "pickle": return .pickle
        case "overlayAndNotifications": return .overlayAndNotifications
        case "notification", "cursorBubbles": return .overlayAndNotifications
        case "voice": return .voice
        case "shortcuts": return .shortcuts
        case "tools", "builtinTools": return .builtinTools
        case "onboarding": return .onboarding
        case "index", "": return .index
        default: return nil
        }
    }
}

/// Process-wide funnel that the markdown renderer pokes when it sees a
/// `picky://` link, and that the app delegate wires to the menu bar panel
/// manager at launch. Keeping the dispatcher independent of any view lets
/// every place that renders agent markdown (HUD agent bubbles, companion
/// panel messages) share one handler without each view having to know how
/// to find `MenuBarPanelManager`.
@MainActor
final class PickyDeepLinkDispatcher {
    static let shared = PickyDeepLinkDispatcher()

    private var handler: ((PickyDeepLink) -> Void)?

    private init() {}

    func configure(handler: @escaping (PickyDeepLink) -> Void) {
        self.handler = handler
    }

    /// Returns `true` when the URL was a recognised `picky://` link so the
    /// caller can short-circuit SwiftUI's default URL handler. Unknown
    /// `picky://` paths still return `true` (the scheme is ours) to avoid
    /// the system trying to open them in a browser.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "picky" else { return false }
        if let link = PickyDeepLink(url: url) {
            handler?(link)
        }
        return true
    }
}

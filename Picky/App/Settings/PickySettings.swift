//
//  PickySettings.swift
//  Picky
//
//  Lightweight persisted settings for the local-first MVP.
//

import Foundation

enum PickyVoiceProviderSelection: String, Codable, CaseIterable, Identifiable {
    case automatic
    case local
    case azure
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .local: "Local"
        case .azure: "Azure OpenAI"
        case .elevenLabs: "ElevenLabs"
        }
    }

    func displayName(for capability: PickyVoiceProviderCapability) -> String {
        switch self {
        case .automatic:
            return "Automatic"
        case .local:
            switch capability {
            case .transcription: return "Apple Speech"
            case .speechPlayback: return "macOS Speech"
            }
        case .azure:
            return "Azure OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    static func cases(for capability: PickyVoiceProviderCapability) -> [PickyVoiceProviderSelection] {
        switch capability {
        case .transcription:
            return [.automatic, .local, .azure]
        case .speechPlayback:
            return [.automatic, .local, .azure, .elevenLabs]
        }
    }
}

enum PickyVoiceProviderCapability {
    case transcription
    case speechPlayback
}

enum PickyMainAgentThinkingLevel: String, Codable, CaseIterable, Identifiable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        }
    }
}

enum PickyScreenContextScope: String, Codable, CaseIterable, Identifiable {
    case allScreens
    case focusedScreen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allScreens: "All screens"
        case .focusedScreen: "Focused screen only"
        }
    }
}

/// User zoom level for the markdown report viewer and the Pi terminal overlay.
/// Each surface keeps its own multiplier so increasing terminal cell density does not
/// also blow up the markdown body. Bounded by `PickyFontScales.minimum`/`.maximum`
/// before persisting so a corrupted settings file can't push the UI into an unusable
/// scale on next launch.
struct PickyFontScales: Codable, Equatable {
    var markdownReport: Double
    var terminal: Double

    static let minimum: Double = 0.7
    static let maximum: Double = 2.5
    static let step: Double = 0.1
    static let defaults = PickyFontScales(markdownReport: 1.0, terminal: 1.0)

    static func clamped(_ value: Double) -> Double {
        // Round to one decimal to avoid floating-point drift accumulating across `+0.1` taps.
        let rounded = (value * 10).rounded() / 10
        return min(max(rounded, minimum), maximum)
    }
}

/// User-configurable toggles deciding which session status transitions emit a macOS
/// banner via `PickySystemNotificationCenter`. All default to `true` so existing users
/// keep seeing the same notifications they had before this struct shipped.
struct PickyNotificationPreferences: Codable, Equatable {
    var notifyOnCompleted: Bool
    var notifyOnFailed: Bool
    var notifyOnWaitingForInput: Bool

    static let defaults = PickyNotificationPreferences(
        notifyOnCompleted: true,
        notifyOnFailed: true,
        notifyOnWaitingForInput: true
    )
}

/// User-configurable behavior toggles for the Pi cursor buddy overlay.
/// Defaults preserve the existing playful behavior for current users.
struct PickyCursorPreferences: Codable, Equatable {
    var showPiCursor: Bool
    var enableOvershootReaction: Bool
    var enableIdleAnimations: Bool

    static let defaults = PickyCursorPreferences(
        showPiCursor: true,
        enableOvershootReaction: true,
        enableIdleAnimations: true
    )

    enum CodingKeys: String, CodingKey {
        case showPiCursor
        case enableOvershootReaction
        case enableVelocityReaction
        case enableIdleAnimations
    }

    init(
        showPiCursor: Bool,
        enableOvershootReaction: Bool,
        enableIdleAnimations: Bool
    ) {
        self.showPiCursor = showPiCursor
        self.enableOvershootReaction = enableOvershootReaction
        self.enableIdleAnimations = enableIdleAnimations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickyCursorPreferences.defaults
        showPiCursor = try container.decodeIfPresent(Bool.self, forKey: .showPiCursor) ?? defaults.showPiCursor
        enableOvershootReaction = try container.decodeIfPresent(Bool.self, forKey: .enableOvershootReaction)
            ?? container.decodeIfPresent(Bool.self, forKey: .enableVelocityReaction)
            ?? defaults.enableOvershootReaction
        enableIdleAnimations = try container.decodeIfPresent(Bool.self, forKey: .enableIdleAnimations) ?? defaults.enableIdleAnimations
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showPiCursor, forKey: .showPiCursor)
        try container.encode(enableOvershootReaction, forKey: .enableOvershootReaction)
        try container.encode(enableIdleAnimations, forKey: .enableIdleAnimations)
    }
}

struct PickySettings: Codable, Equatable {
    var defaultCwd: String
    var worktreeParent: String
    var preferredToolVisibility: String
    var readOnlyInvestigationPreference: Bool
    var daemonPath: String
    var logPath: String
    var sttProvider: PickyVoiceProviderSelection
    var ttsProvider: PickyVoiceProviderSelection
    /// Full Azure OpenAI audio/transcriptions URL copied from the Azure portal.
    /// Picky parses the base endpoint, deployment name, and api-version from it.
    var azureOpenAIEndpoint: String
    var azureOpenAIAPIKey: String
    var azureSTTPreferredLanguage: String
    var appearance: PickyAppearanceMode
    var notifications: PickyNotificationPreferences
    var cursor: PickyCursorPreferences
    var fontScales: PickyFontScales
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel
    /// Free-form Korean/English instructions appended to every main-agent turn prompt. Lets users
    /// teach the always-on main agent personal preferences (tone, language, recurring reminders)
    /// without forking the bootstrap pair. Empty by default; trimmed before persisting.
    var mainAgentExtraInstructions: String
    var screenContextScope: PickyScreenContextScope
    var useConversationCard: Bool
    var pushToTalkShortcut: PickyShortcutSpec
    var quickInputShortcut: PickyShortcutSpec
    /// Vertical anchor for the HUD dock's top edge, expressed as a percentage of the
    /// current screen's `visibleFrame` height measured from the top. Synced across all
    /// monitors so dragging the handle on one display lands the dock at the same
    /// relative position on every other display. Persisted in the user's settings file
    /// after the user releases the drag handle.
    ///
    /// Range: `PickySettings.dockTopAnchorPercentRange` (5%–40%). 5% keeps the dock
    /// just under the menu bar; 40% lets the dock sit lower without the conversation
    /// card going off-screen at the bottom.
    var hudDockTopAnchorPercent: Double

    static let dockTopAnchorPercentRange: ClosedRange<Double> = 5.0...40.0
    static let defaultDockTopAnchorPercent: Double = 22.0

    /// Clamp any incoming value (slider, persisted file, programmatic) to the supported
    /// range. Out-of-range values can come from corrupted settings files or a future
    /// version that widens the range; clamping keeps the runtime in a known-good zone.
    static func clampedDockTopAnchorPercent(_ value: Double) -> Double {
        if !value.isFinite { return defaultDockTopAnchorPercent }
        return min(max(value, dockTopAnchorPercentRange.lowerBound), dockTopAnchorPercentRange.upperBound)
    }

    init(
        defaultCwd: String,
        worktreeParent: String,
        preferredToolVisibility: String,
        readOnlyInvestigationPreference: Bool,
        daemonPath: String,
        logPath: String,
        sttProvider: PickyVoiceProviderSelection = .automatic,
        ttsProvider: PickyVoiceProviderSelection = .automatic,
        azureOpenAIEndpoint: String = "",
        azureOpenAIAPIKey: String = "",
        azureSTTPreferredLanguage: String = "",
        appearance: PickyAppearanceMode = .dark,
        notifications: PickyNotificationPreferences = .defaults,
        cursor: PickyCursorPreferences = .defaults,
        fontScales: PickyFontScales = .defaults,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium,
        mainAgentExtraInstructions: String = "",
        screenContextScope: PickyScreenContextScope = .allScreens,
        useConversationCard: Bool = true,
        pushToTalkShortcut: PickyShortcutSpec = .defaultPushToTalk,
        quickInputShortcut: PickyShortcutSpec = .defaultQuickInput,
        hudDockTopAnchorPercent: Double = PickySettings.defaultDockTopAnchorPercent
    ) {
        self.defaultCwd = defaultCwd
        self.worktreeParent = worktreeParent
        self.preferredToolVisibility = preferredToolVisibility
        self.readOnlyInvestigationPreference = readOnlyInvestigationPreference
        self.daemonPath = daemonPath
        self.logPath = logPath
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.azureOpenAIEndpoint = azureOpenAIEndpoint
        self.azureOpenAIAPIKey = azureOpenAIAPIKey
        self.azureSTTPreferredLanguage = azureSTTPreferredLanguage
        self.appearance = appearance
        self.notifications = notifications
        self.cursor = cursor
        self.fontScales = fontScales
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentExtraInstructions = mainAgentExtraInstructions
        self.screenContextScope = screenContextScope
        self.useConversationCard = useConversationCard
        self.pushToTalkShortcut = pushToTalkShortcut
        self.quickInputShortcut = quickInputShortcut
        self.hudDockTopAnchorPercent = PickySettings.clampedDockTopAnchorPercent(hudDockTopAnchorPercent)
    }

    static func defaults(appSupportRoot: URL = PickyAppSupport.defaultRoot()) -> PickySettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PickySettings(
            defaultCwd: home,
            worktreeParent: home,
            preferredToolVisibility: "visible in context only",
            readOnlyInvestigationPreference: true,
            daemonPath: "bundled picky-agentd or local development agentd",
            logPath: appSupportRoot.appendingPathComponent("Logs", isDirectory: true).path,
            sttProvider: .automatic,
            ttsProvider: .automatic,
            azureOpenAIEndpoint: "",
            azureOpenAIAPIKey: "",
            azureSTTPreferredLanguage: "",
            appearance: .dark,
            notifications: .defaults,
            cursor: .defaults,
            fontScales: .defaults,
            mainAgentThinkingLevel: .medium,
            mainAgentExtraInstructions: "",
            screenContextScope: .allScreens,
            useConversationCard: true,
            pushToTalkShortcut: .defaultPushToTalk,
            quickInputShortcut: .defaultQuickInput,
            hudDockTopAnchorPercent: PickySettings.defaultDockTopAnchorPercent
        )
    }

    func normalizedPaths() -> PickySettings {
        var copy = self
        copy.defaultCwd = NSString(string: defaultCwd).expandingTildeInPath
        if !worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.worktreeParent = NSString(string: worktreeParent).expandingTildeInPath
        }
        copy.azureOpenAIEndpoint = azureOpenAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAIAPIKey = azureOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureSTTPreferredLanguage = azureSTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.mainAgentExtraInstructions = mainAgentExtraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case defaultCwd
        case worktreeParent
        case preferredToolVisibility
        case readOnlyInvestigationPreference
        case daemonPath
        case logPath
        case sttProvider
        case ttsProvider
        case azureOpenAIEndpoint
        case azureOpenAIAPIKey
        case azureSTTPreferredLanguage
        case appearance
        case notifications
        case cursor
        case fontScales
        case mainAgentThinkingLevel
        case mainAgentExtraInstructions
        case screenContextScope
        case useConversationCard
        case pushToTalkShortcut
        case quickInputShortcut
        case hudDockTopAnchorPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickySettings.defaults()

        defaultCwd = try container.decodeIfPresent(String.self, forKey: .defaultCwd) ?? defaults.defaultCwd
        worktreeParent = try container.decodeIfPresent(String.self, forKey: .worktreeParent) ?? defaults.worktreeParent
        preferredToolVisibility = try container.decodeIfPresent(String.self, forKey: .preferredToolVisibility) ?? defaults.preferredToolVisibility
        readOnlyInvestigationPreference = try container.decodeIfPresent(Bool.self, forKey: .readOnlyInvestigationPreference) ?? defaults.readOnlyInvestigationPreference
        daemonPath = try container.decodeIfPresent(String.self, forKey: .daemonPath) ?? defaults.daemonPath
        logPath = try container.decodeIfPresent(String.self, forKey: .logPath) ?? defaults.logPath
        sttProvider = try container.decodeIfPresent(PickyVoiceProviderSelection.self, forKey: .sttProvider) ?? defaults.sttProvider
        ttsProvider = try container.decodeIfPresent(PickyVoiceProviderSelection.self, forKey: .ttsProvider) ?? defaults.ttsProvider
        azureOpenAIEndpoint = try container.decodeIfPresent(String.self, forKey: .azureOpenAIEndpoint) ?? defaults.azureOpenAIEndpoint
        azureOpenAIAPIKey = try container.decodeIfPresent(String.self, forKey: .azureOpenAIAPIKey) ?? defaults.azureOpenAIAPIKey
        azureSTTPreferredLanguage = try container.decodeIfPresent(String.self, forKey: .azureSTTPreferredLanguage) ?? defaults.azureSTTPreferredLanguage
        appearance = try container.decodeIfPresent(PickyAppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        notifications = try container.decodeIfPresent(PickyNotificationPreferences.self, forKey: .notifications) ?? defaults.notifications
        cursor = try container.decodeIfPresent(PickyCursorPreferences.self, forKey: .cursor) ?? defaults.cursor
        mainAgentThinkingLevel = try container.decodeIfPresent(PickyMainAgentThinkingLevel.self, forKey: .mainAgentThinkingLevel) ?? defaults.mainAgentThinkingLevel
        mainAgentExtraInstructions = try container.decodeIfPresent(String.self, forKey: .mainAgentExtraInstructions) ?? defaults.mainAgentExtraInstructions
        screenContextScope = try container.decodeIfPresent(PickyScreenContextScope.self, forKey: .screenContextScope) ?? defaults.screenContextScope
        useConversationCard = try container.decodeIfPresent(Bool.self, forKey: .useConversationCard) ?? defaults.useConversationCard
        if let storedScales = try container.decodeIfPresent(PickyFontScales.self, forKey: .fontScales) {
            fontScales = PickyFontScales(
                markdownReport: PickyFontScales.clamped(storedScales.markdownReport),
                terminal: PickyFontScales.clamped(storedScales.terminal)
            )
        } else {
            fontScales = defaults.fontScales
        }
        let storedPTT = try container.decodeIfPresent(PickyShortcutSpec.self, forKey: .pushToTalkShortcut)
        pushToTalkShortcut = (storedPTT?.isValid == true) ? storedPTT! : defaults.pushToTalkShortcut
        let storedQuickInput = try container.decodeIfPresent(PickyShortcutSpec.self, forKey: .quickInputShortcut)
        quickInputShortcut = (storedQuickInput?.isValid == true) ? storedQuickInput! : defaults.quickInputShortcut
        let storedAnchor = try container.decodeIfPresent(Double.self, forKey: .hudDockTopAnchorPercent) ?? defaults.hudDockTopAnchorPercent
        hudDockTopAnchorPercent = PickySettings.clampedDockTopAnchorPercent(storedAnchor)
    }
}

enum PickySettingsValidationError: LocalizedError, Equatable {
    case invalidDefaultCwd(String)
    case invalidWorktreeParent(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefaultCwd(let path): "Default cwd does not exist or is not a directory: \(path)"
        case .invalidWorktreeParent(let path): "Worktree parent does not exist or is not a directory: \(path)"
        }
    }
}

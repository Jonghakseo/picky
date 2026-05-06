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

struct PickySettings: Codable, Equatable {
    var defaultCwd: String
    var worktreeParent: String
    var preferredToolVisibility: String
    var readOnlyInvestigationPreference: Bool
    var daemonPath: String
    var logPath: String
    var sttProvider: PickyVoiceProviderSelection
    var ttsProvider: PickyVoiceProviderSelection
    var azureSTTPreferredLanguage: String
    var appearance: PickyAppearanceMode
    var notifications: PickyNotificationPreferences
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

    init(
        defaultCwd: String,
        worktreeParent: String,
        preferredToolVisibility: String,
        readOnlyInvestigationPreference: Bool,
        daemonPath: String,
        logPath: String,
        sttProvider: PickyVoiceProviderSelection = .automatic,
        ttsProvider: PickyVoiceProviderSelection = .automatic,
        azureSTTPreferredLanguage: String = "",
        appearance: PickyAppearanceMode = .dark,
        notifications: PickyNotificationPreferences = .defaults,
        fontScales: PickyFontScales = .defaults,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium,
        mainAgentExtraInstructions: String = "",
        screenContextScope: PickyScreenContextScope = .allScreens,
        useConversationCard: Bool = true,
        pushToTalkShortcut: PickyShortcutSpec = .defaultPushToTalk,
        quickInputShortcut: PickyShortcutSpec = .defaultQuickInput
    ) {
        self.defaultCwd = defaultCwd
        self.worktreeParent = worktreeParent
        self.preferredToolVisibility = preferredToolVisibility
        self.readOnlyInvestigationPreference = readOnlyInvestigationPreference
        self.daemonPath = daemonPath
        self.logPath = logPath
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.azureSTTPreferredLanguage = azureSTTPreferredLanguage
        self.appearance = appearance
        self.notifications = notifications
        self.fontScales = fontScales
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentExtraInstructions = mainAgentExtraInstructions
        self.screenContextScope = screenContextScope
        self.useConversationCard = useConversationCard
        self.pushToTalkShortcut = pushToTalkShortcut
        self.quickInputShortcut = quickInputShortcut
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
            azureSTTPreferredLanguage: "",
            appearance: .dark,
            notifications: .defaults,
            fontScales: .defaults,
            mainAgentThinkingLevel: .medium,
            mainAgentExtraInstructions: "",
            screenContextScope: .allScreens,
            useConversationCard: true,
            pushToTalkShortcut: .defaultPushToTalk,
            quickInputShortcut: .defaultQuickInput
        )
    }

    func normalizedPaths() -> PickySettings {
        var copy = self
        copy.defaultCwd = NSString(string: defaultCwd).expandingTildeInPath
        if !worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.worktreeParent = NSString(string: worktreeParent).expandingTildeInPath
        }
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
        case azureSTTPreferredLanguage
        case appearance
        case notifications
        case fontScales
        case mainAgentThinkingLevel
        case mainAgentExtraInstructions
        case screenContextScope
        case useConversationCard
        case pushToTalkShortcut
        case quickInputShortcut
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
        azureSTTPreferredLanguage = try container.decodeIfPresent(String.self, forKey: .azureSTTPreferredLanguage) ?? defaults.azureSTTPreferredLanguage
        appearance = try container.decodeIfPresent(PickyAppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        notifications = try container.decodeIfPresent(PickyNotificationPreferences.self, forKey: .notifications) ?? defaults.notifications
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

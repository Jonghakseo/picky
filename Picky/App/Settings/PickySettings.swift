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
    var followsFocusedScreen: Bool
    var appearance: PickyAppearanceMode

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
        followsFocusedScreen: Bool = true,
        appearance: PickyAppearanceMode = .dark
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
        self.followsFocusedScreen = followsFocusedScreen
        self.appearance = appearance
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
            followsFocusedScreen: true,
            appearance: .dark
        )
    }

    func normalizedPaths() -> PickySettings {
        var copy = self
        copy.defaultCwd = NSString(string: defaultCwd).expandingTildeInPath
        if !worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.worktreeParent = NSString(string: worktreeParent).expandingTildeInPath
        }
        copy.azureSTTPreferredLanguage = azureSTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case followsFocusedScreen
        case appearance
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
        followsFocusedScreen = try container.decodeIfPresent(Bool.self, forKey: .followsFocusedScreen) ?? defaults.followsFocusedScreen
        appearance = try container.decodeIfPresent(PickyAppearanceMode.self, forKey: .appearance) ?? defaults.appearance
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

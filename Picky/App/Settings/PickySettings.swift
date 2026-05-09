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

enum PickyMainAgentRuntimeMode: String, Codable, CaseIterable, Identifiable {
    case pi
    case openAIRealtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: "Pi (current)"
        case .openAIRealtime: "OpenAI Realtime"
        }
    }

    var agentdEnvironmentValue: String {
        switch self {
        case .pi: "pi"
        case .openAIRealtime: "openai-realtime"
        }
    }
}

enum PickyOpenAIRealtimeProvider: String, Codable, CaseIterable, Identifiable {
    case openAI
    case azureOpenAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .azureOpenAI: "Azure OpenAI"
        }
    }

    var protocolValue: String {
        switch self {
        case .openAI: "openai"
        case .azureOpenAI: "azure_openai"
        }
    }
}

enum PickyAzureOpenAIRealtimeAPIShape: String, Codable, CaseIterable, Identifiable {
    case ga
    case preview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ga: "GA /openai/v1/realtime"
        case .preview: "Preview /openai/realtime"
        }
    }

    var protocolValue: String { rawValue }
}

enum PickyOpenAIRealtimeReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

struct PickyOpenAIRealtimeSettings: Codable, Equatable {
    var provider: PickyOpenAIRealtimeProvider
    var apiKey: String
    var modelOrDeployment: String
    /// Preferred Azure Realtime input. The full WebSocket/HTTPS endpoint includes
    /// api-version and deployment/model, so Azure users only need this URL plus an API key.
    var azureRealtimeURL: String
    /// Legacy split Azure fields kept for backward-compatible decode and protocol mapping.
    var azureResourceEndpoint: String
    var azureAPIVersion: String
    var azureAPIShape: PickyAzureOpenAIRealtimeAPIShape
    var voice: String
    var reasoningEffort: PickyOpenAIRealtimeReasoningEffort
    var transcriptionLanguage: String

    static let defaults = PickyOpenAIRealtimeSettings(
        provider: .openAI,
        apiKey: "",
        modelOrDeployment: "gpt-realtime-2",
        azureRealtimeURL: "",
        azureResourceEndpoint: "",
        azureAPIVersion: "",
        azureAPIShape: .ga,
        voice: "marin",
        reasoningEffort: .medium,
        transcriptionLanguage: ""
    )

    init(
        provider: PickyOpenAIRealtimeProvider,
        apiKey: String,
        modelOrDeployment: String,
        azureRealtimeURL: String = "",
        azureResourceEndpoint: String,
        azureAPIVersion: String,
        azureAPIShape: PickyAzureOpenAIRealtimeAPIShape,
        voice: String,
        reasoningEffort: PickyOpenAIRealtimeReasoningEffort,
        transcriptionLanguage: String
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.modelOrDeployment = modelOrDeployment
        self.azureRealtimeURL = azureRealtimeURL
        self.azureResourceEndpoint = azureResourceEndpoint
        self.azureAPIVersion = azureAPIVersion
        self.azureAPIShape = azureAPIShape
        self.voice = voice
        self.reasoningEffort = reasoningEffort
        self.transcriptionLanguage = transcriptionLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case apiKey
        case modelOrDeployment
        case azureRealtimeURL
        case azureResourceEndpoint
        case azureAPIVersion
        case azureAPIShape
        case voice
        case reasoningEffort
        case transcriptionLanguage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        provider = try container.decodeIfPresent(PickyOpenAIRealtimeProvider.self, forKey: .provider) ?? defaults.provider
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        modelOrDeployment = try container.decodeIfPresent(String.self, forKey: .modelOrDeployment) ?? defaults.modelOrDeployment
        azureRealtimeURL = try container.decodeIfPresent(String.self, forKey: .azureRealtimeURL) ?? defaults.azureRealtimeURL
        azureResourceEndpoint = try container.decodeIfPresent(String.self, forKey: .azureResourceEndpoint) ?? defaults.azureResourceEndpoint
        azureAPIVersion = try container.decodeIfPresent(String.self, forKey: .azureAPIVersion) ?? defaults.azureAPIVersion
        azureAPIShape = try container.decodeIfPresent(PickyAzureOpenAIRealtimeAPIShape.self, forKey: .azureAPIShape) ?? defaults.azureAPIShape
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? defaults.voice
        reasoningEffort = try container.decodeIfPresent(PickyOpenAIRealtimeReasoningEffort.self, forKey: .reasoningEffort) ?? defaults.reasoningEffort
        transcriptionLanguage = try container.decodeIfPresent(String.self, forKey: .transcriptionLanguage) ?? defaults.transcriptionLanguage
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(modelOrDeployment, forKey: .modelOrDeployment)
        try container.encode(azureRealtimeURL, forKey: .azureRealtimeURL)
        try container.encode(azureResourceEndpoint, forKey: .azureResourceEndpoint)
        try container.encode(azureAPIVersion, forKey: .azureAPIVersion)
        try container.encode(azureAPIShape, forKey: .azureAPIShape)
        try container.encode(voice, forKey: .voice)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(transcriptionLanguage, forKey: .transcriptionLanguage)
    }

    func normalized() -> PickyOpenAIRealtimeSettings {
        var copy = self
        copy.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.modelOrDeployment = modelOrDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureRealtimeURL = azureRealtimeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureResourceEndpoint = azureResourceEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureAPIVersion = azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.transcriptionLanguage = transcriptionLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.azureRealtimeURL.isEmpty,
           let legacyURL = PickyAzureOpenAIRealtimeURLComponents.makeURL(
               resourceEndpoint: copy.azureResourceEndpoint,
               deployment: copy.modelOrDeployment,
               apiVersion: copy.azureAPIVersion,
               apiShape: copy.azureAPIShape
           ) {
            copy.azureRealtimeURL = legacyURL
        }
        return copy
    }

    var azureRealtimeEndpointComponents: PickyAzureOpenAIRealtimeURLComponents? {
        PickyAzureOpenAIRealtimeURLComponents.parse(normalized().azureRealtimeURL)
    }
}

struct PickyAzureOpenAIRealtimeURLComponents: Equatable {
    var resourceEndpoint: String
    var deployment: String
    var apiVersion: String?
    var apiShape: PickyAzureOpenAIRealtimeAPIShape

    static func parse(_ rawValue: String) -> PickyAzureOpenAIRealtimeURLComponents? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "wss"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        let endpointScheme = "https"
        let portSuffix = components.port.map { ":\($0)" } ?? ""
        let resourceEndpoint = "\(endpointScheme)://\(host)\(portSuffix)"
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = components.queryItems ?? []
        func query(_ name: String) -> String? {
            queryItems.first { $0.name.lowercased() == name.lowercased() }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch path {
        case "openai/realtime":
            guard let apiVersion = query("api-version"), !apiVersion.isEmpty,
                  let deployment = query("deployment") ?? query("model"), !deployment.isEmpty else {
                return nil
            }
            return PickyAzureOpenAIRealtimeURLComponents(
                resourceEndpoint: resourceEndpoint,
                deployment: deployment,
                apiVersion: apiVersion,
                apiShape: .preview
            )
        case "openai/v1/realtime":
            guard let deployment = query("model") ?? query("deployment"), !deployment.isEmpty else {
                return nil
            }
            return PickyAzureOpenAIRealtimeURLComponents(
                resourceEndpoint: resourceEndpoint,
                deployment: deployment,
                apiVersion: query("api-version"),
                apiShape: .ga
            )
        default:
            return nil
        }
    }

    static func makeURL(
        resourceEndpoint: String,
        deployment: String,
        apiVersion: String,
        apiShape: PickyAzureOpenAIRealtimeAPIShape
    ) -> String? {
        let endpoint = resourceEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let deployment = deployment.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiVersion = apiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !deployment.isEmpty else { return nil }
        switch apiShape {
        case .ga:
            return "\(endpoint)/openai/v1/realtime?model=\(deployment)"
        case .preview:
            guard !apiVersion.isEmpty else { return nil }
            return "\(endpoint)/openai/realtime?api-version=\(apiVersion)&deployment=\(deployment)"
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

/// Horizontal screen edge where the side-agent HUD dock is anchored.
/// Defaults to `.right` to preserve existing behavior for users without the key
/// in their settings file. The dock handle double-click toggles this value.
enum PickyHUDDockSide: String, Codable, CaseIterable, Identifiable {
    case right
    case left

    var id: String { rawValue }

    var toggled: PickyHUDDockSide {
        switch self {
        case .right: .left
        case .left: .right
        }
    }
}

/// Per-display dock position state. Each display keeps its own side, anchor percent,
/// and horizontal offset so users can place the dock differently on each monitor.
struct PickyHUDDockPosition: Codable, Equatable {
    static let defaultKey = "default"

    var side: PickyHUDDockSide
    var anchorPercent: Double
    var xOffset: CGFloat

    static func defaults() -> PickyHUDDockPosition {
        PickyHUDDockPosition(
            side: .right,
            anchorPercent: PickySettings.defaultDockTopAnchorPercent,
            xOffset: 0
        )
    }

    static func resolved(in positions: [String: PickyHUDDockPosition], displayKey: String) -> PickyHUDDockPosition {
        positions[displayKey] ?? positions[defaultKey] ?? defaults()
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

struct PickyOverlayBubblePreferences: Codable, Equatable {
    var showUserSpeechRecognitionBubble: Bool
    var showPickyResponseBubble: Bool

    static let defaults = PickyOverlayBubblePreferences(
        showUserSpeechRecognitionBubble: true,
        showPickyResponseBubble: true
    )

    enum CodingKeys: String, CodingKey {
        case showUserSpeechRecognitionBubble
        case showPickyResponseBubble
    }

    init(
        showUserSpeechRecognitionBubble: Bool,
        showPickyResponseBubble: Bool
    ) {
        self.showUserSpeechRecognitionBubble = showUserSpeechRecognitionBubble
        self.showPickyResponseBubble = showPickyResponseBubble
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickyOverlayBubblePreferences.defaults
        showUserSpeechRecognitionBubble = try container.decodeIfPresent(Bool.self, forKey: .showUserSpeechRecognitionBubble)
            ?? defaults.showUserSpeechRecognitionBubble
        showPickyResponseBubble = try container.decodeIfPresent(Bool.self, forKey: .showPickyResponseBubble)
            ?? defaults.showPickyResponseBubble
    }
}

struct PickySettings: Codable, Equatable {
    var defaultCwd: String
    var mainAgentCwd: String
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
    /// Full Azure OpenAI audio/speech URL copied from the Azure portal.
    /// Kept separate from STT because speech usually uses a different deployment/path.
    var azureOpenAITTSEndpoint: String
    var azureOpenAITTSAPIKey: String
    var azureOpenAITTSVoice: String
    var azureSTTPreferredLanguage: String
    var appearance: PickyAppearanceMode
    var notifications: PickyNotificationPreferences
    var cursor: PickyCursorPreferences
    var overlayBubbles: PickyOverlayBubblePreferences
    var fontScales: PickyFontScales
    var mainAgentRuntimeMode: PickyMainAgentRuntimeMode
    var openAIRealtime: PickyOpenAIRealtimeSettings
    /// Empty means the Pi main agent follows Pi's own default model/settings. Non-empty is a
    /// provider/model pattern returned by picky-agentd, for example `anthropic/claude-sonnet-4-5`.
    var mainAgentModelPattern: String
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
    /// Per-display dock position state keyed by display ID. Each monitor remembers
    /// its own dock side, anchor percent, and horizontal offset so users can place
    /// the dock independently on each screen. Falls back to `PickyHUDDockPosition.defaults()`
    /// when a display has not yet been configured.
    var hudDockPositions: [String: PickyHUDDockPosition]

    static let dockTopAnchorPercentRange: ClosedRange<Double> = 2.0...70.0
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
        mainAgentCwd: String? = nil,
        worktreeParent: String,
        preferredToolVisibility: String,
        readOnlyInvestigationPreference: Bool,
        daemonPath: String,
        logPath: String,
        sttProvider: PickyVoiceProviderSelection = .automatic,
        ttsProvider: PickyVoiceProviderSelection = .automatic,
        azureOpenAIEndpoint: String = "",
        azureOpenAIAPIKey: String = "",
        azureOpenAITTSEndpoint: String = "",
        azureOpenAITTSAPIKey: String = "",
        azureOpenAITTSVoice: String = "",
        azureSTTPreferredLanguage: String = "",
        appearance: PickyAppearanceMode = .dark,
        notifications: PickyNotificationPreferences = .defaults,
        cursor: PickyCursorPreferences = .defaults,
        overlayBubbles: PickyOverlayBubblePreferences = .defaults,
        fontScales: PickyFontScales = .defaults,
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi,
        openAIRealtime: PickyOpenAIRealtimeSettings = .defaults,
        mainAgentModelPattern: String = "",
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .medium,
        mainAgentExtraInstructions: String = "",
        screenContextScope: PickyScreenContextScope = .allScreens,
        useConversationCard: Bool = true,
        pushToTalkShortcut: PickyShortcutSpec = .defaultPushToTalk,
        quickInputShortcut: PickyShortcutSpec = .defaultQuickInput,
        hudDockPositions: [String: PickyHUDDockPosition] = [:]
    ) {
        self.defaultCwd = defaultCwd
        self.mainAgentCwd = mainAgentCwd ?? defaultCwd
        self.worktreeParent = worktreeParent
        self.preferredToolVisibility = preferredToolVisibility
        self.readOnlyInvestigationPreference = readOnlyInvestigationPreference
        self.daemonPath = daemonPath
        self.logPath = logPath
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.azureOpenAIEndpoint = azureOpenAIEndpoint
        self.azureOpenAIAPIKey = azureOpenAIAPIKey
        self.azureOpenAITTSEndpoint = azureOpenAITTSEndpoint
        self.azureOpenAITTSAPIKey = azureOpenAITTSAPIKey
        self.azureOpenAITTSVoice = azureOpenAITTSVoice
        self.azureSTTPreferredLanguage = azureSTTPreferredLanguage
        self.appearance = appearance
        self.notifications = notifications
        self.cursor = cursor
        self.overlayBubbles = overlayBubbles
        self.fontScales = fontScales
        self.mainAgentRuntimeMode = mainAgentRuntimeMode
        self.openAIRealtime = openAIRealtime
        self.mainAgentModelPattern = mainAgentModelPattern
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentExtraInstructions = mainAgentExtraInstructions
        self.screenContextScope = screenContextScope
        self.useConversationCard = useConversationCard
        self.pushToTalkShortcut = pushToTalkShortcut
        self.quickInputShortcut = quickInputShortcut
        self.hudDockPositions = hudDockPositions
    }

    static func defaults(appSupportRoot: URL = PickyAppSupport.defaultRoot()) -> PickySettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return PickySettings(
            defaultCwd: home,
            mainAgentCwd: home,
            worktreeParent: home,
            preferredToolVisibility: "visible in context only",
            readOnlyInvestigationPreference: true,
            daemonPath: "bundled picky-agentd or local development agentd",
            logPath: appSupportRoot.appendingPathComponent("Logs", isDirectory: true).path,
            sttProvider: .automatic,
            ttsProvider: .automatic,
            azureOpenAIEndpoint: "",
            azureOpenAIAPIKey: "",
            azureOpenAITTSEndpoint: "",
            azureOpenAITTSAPIKey: "",
            azureOpenAITTSVoice: "",
            azureSTTPreferredLanguage: "",
            appearance: .dark,
            notifications: .defaults,
            cursor: .defaults,
            overlayBubbles: .defaults,
            fontScales: .defaults,
            mainAgentRuntimeMode: .pi,
            openAIRealtime: .defaults,
            mainAgentModelPattern: "",
            mainAgentThinkingLevel: .medium,
            mainAgentExtraInstructions: "",
            screenContextScope: .allScreens,
            useConversationCard: true,
            pushToTalkShortcut: .defaultPushToTalk,
            quickInputShortcut: .defaultQuickInput,
            hudDockPositions: [:]
        )
    }

    func normalizedPaths() -> PickySettings {
        var copy = self
        copy.defaultCwd = NSString(string: defaultCwd).expandingTildeInPath
        copy.mainAgentCwd = NSString(string: mainAgentCwd).expandingTildeInPath
        if !worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.worktreeParent = NSString(string: worktreeParent).expandingTildeInPath
        }
        copy.azureOpenAIEndpoint = azureOpenAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAIAPIKey = azureOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAITTSEndpoint = azureOpenAITTSEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAITTSAPIKey = azureOpenAITTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAITTSVoice = azureOpenAITTSVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureSTTPreferredLanguage = azureSTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAIRealtime = openAIRealtime.normalized()
        copy.mainAgentModelPattern = mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        // mainAgentExtraInstructions: do not trim here — auto-save runs on every keystroke,
        // so trimming round-trips would eat trailing spaces while typing. Trim happens at send time.
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case defaultCwd
        case mainAgentCwd
        case worktreeParent
        case preferredToolVisibility
        case readOnlyInvestigationPreference
        case daemonPath
        case logPath
        case sttProvider
        case ttsProvider
        case azureOpenAIEndpoint
        case azureOpenAIAPIKey
        case azureOpenAITTSEndpoint
        case azureOpenAITTSAPIKey
        case azureOpenAITTSVoice
        case azureSTTPreferredLanguage
        case appearance
        case notifications
        case cursor
        case overlayBubbles
        case fontScales
        case mainAgentRuntimeMode
        case openAIRealtime
        case mainAgentModelPattern
        case mainAgentThinkingLevel
        case mainAgentExtraInstructions
        case screenContextScope
        case useConversationCard
        case pushToTalkShortcut
        case quickInputShortcut
        case hudDockPositions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickySettings.defaults()

        defaultCwd = try container.decodeIfPresent(String.self, forKey: .defaultCwd) ?? defaults.defaultCwd
        mainAgentCwd = try container.decodeIfPresent(String.self, forKey: .mainAgentCwd) ?? defaultCwd
        worktreeParent = try container.decodeIfPresent(String.self, forKey: .worktreeParent) ?? defaults.worktreeParent
        preferredToolVisibility = try container.decodeIfPresent(String.self, forKey: .preferredToolVisibility) ?? defaults.preferredToolVisibility
        readOnlyInvestigationPreference = try container.decodeIfPresent(Bool.self, forKey: .readOnlyInvestigationPreference) ?? defaults.readOnlyInvestigationPreference
        daemonPath = try container.decodeIfPresent(String.self, forKey: .daemonPath) ?? defaults.daemonPath
        logPath = try container.decodeIfPresent(String.self, forKey: .logPath) ?? defaults.logPath
        sttProvider = try container.decodeIfPresent(PickyVoiceProviderSelection.self, forKey: .sttProvider) ?? defaults.sttProvider
        ttsProvider = try container.decodeIfPresent(PickyVoiceProviderSelection.self, forKey: .ttsProvider) ?? defaults.ttsProvider
        azureOpenAIEndpoint = try container.decodeIfPresent(String.self, forKey: .azureOpenAIEndpoint) ?? defaults.azureOpenAIEndpoint
        azureOpenAIAPIKey = try container.decodeIfPresent(String.self, forKey: .azureOpenAIAPIKey) ?? defaults.azureOpenAIAPIKey
        azureOpenAITTSEndpoint = try container.decodeIfPresent(String.self, forKey: .azureOpenAITTSEndpoint) ?? defaults.azureOpenAITTSEndpoint
        azureOpenAITTSAPIKey = try container.decodeIfPresent(String.self, forKey: .azureOpenAITTSAPIKey) ?? defaults.azureOpenAITTSAPIKey
        azureOpenAITTSVoice = try container.decodeIfPresent(String.self, forKey: .azureOpenAITTSVoice) ?? defaults.azureOpenAITTSVoice
        azureSTTPreferredLanguage = try container.decodeIfPresent(String.self, forKey: .azureSTTPreferredLanguage) ?? defaults.azureSTTPreferredLanguage
        appearance = try container.decodeIfPresent(PickyAppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        notifications = try container.decodeIfPresent(PickyNotificationPreferences.self, forKey: .notifications) ?? defaults.notifications
        cursor = try container.decodeIfPresent(PickyCursorPreferences.self, forKey: .cursor) ?? defaults.cursor
        overlayBubbles = try container.decodeIfPresent(PickyOverlayBubblePreferences.self, forKey: .overlayBubbles) ?? defaults.overlayBubbles
        mainAgentRuntimeMode = try container.decodeIfPresent(PickyMainAgentRuntimeMode.self, forKey: .mainAgentRuntimeMode) ?? defaults.mainAgentRuntimeMode
        openAIRealtime = try container.decodeIfPresent(PickyOpenAIRealtimeSettings.self, forKey: .openAIRealtime) ?? defaults.openAIRealtime
        mainAgentModelPattern = try container.decodeIfPresent(String.self, forKey: .mainAgentModelPattern) ?? defaults.mainAgentModelPattern
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

        // Migrate from legacy flat fields (single global position) to the per-display
        // dictionary on first read. Old settings used hudDockTopAnchorPercent, hudDockSide,
        // and hudDockXOffset; we fold those into a single "default" entry so the dock
        // doesn't reset for users updating in place.
        if let storedPositions = try container.decodeIfPresent([String: PickyHUDDockPosition].self, forKey: .hudDockPositions) {
            hudDockPositions = storedPositions
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyHUDDockKeys.self)
            let storedAnchor = try legacyContainer.decodeIfPresent(Double.self, forKey: .hudDockTopAnchorPercent)
                ?? PickySettings.defaultDockTopAnchorPercent
            let storedSide = try legacyContainer.decodeIfPresent(PickyHUDDockSide.self, forKey: .hudDockSide) ?? .right
            let storedXOffset = try legacyContainer.decodeIfPresent(CGFloat.self, forKey: .hudDockXOffset) ?? 0
            hudDockPositions = [
                PickyHUDDockPosition.defaultKey: PickyHUDDockPosition(
                    side: storedSide,
                    anchorPercent: PickySettings.clampedDockTopAnchorPercent(storedAnchor),
                    xOffset: storedXOffset
                )
            ]
        }
    }

    private enum LegacyHUDDockKeys: String, CodingKey {
        case hudDockTopAnchorPercent
        case hudDockSide
        case hudDockXOffset
    }
}

enum PickySettingsValidationError: LocalizedError, Equatable {
    case invalidDefaultCwd(String)
    case invalidMainAgentCwd(String)
    case invalidWorktreeParent(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefaultCwd(let path): "Side agent default cwd does not exist or is not a directory: \(path)"
        case .invalidMainAgentCwd(let path): "Main agent cwd does not exist or is not a directory: \(path)"
        case .invalidWorktreeParent(let path): "Worktree parent does not exist or is not a directory: \(path)"
        }
    }
}

//
//  PickySettings.swift
//  Picky
//
//  Lightweight persisted settings for the local-first MVP.
//

import CoreGraphics
import Foundation

enum PickyVoiceProviderSelection: String, Codable, CaseIterable, Identifiable {
    case local
    case openai
    case openaiRealtime
    case azure
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Local"
        case .openai: "OpenAI"
        case .openaiRealtime: "OpenAI Realtime"
        case .azure: "Azure OpenAI"
        case .elevenLabs: "ElevenLabs"
        }
    }

    func displayName(for capability: PickyVoiceProviderCapability) -> String {
        switch self {
        case .local:
            switch capability {
            case .transcription: return "Apple Speech"
            case .speechPlayback: return "macOS Speech"
            }
        case .openai:
            return "OpenAI"
        case .openaiRealtime:
            return "OpenAI Realtime"
        case .azure:
            return "Azure OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    static func cases(for capability: PickyVoiceProviderCapability) -> [PickyVoiceProviderSelection] {
        switch capability {
        case .transcription:
            // openaiRealtime piggybacks on the Codex OAuth bearer agentd already
            // owns, so it only makes sense for STT; the speech playback picker
            // never offers it.
            return [.local, .openai, .openaiRealtime, .azure, .elevenLabs]
        case .speechPlayback:
            return [.local, .openai, .azure, .elevenLabs]
        }
    }

    /// Legacy migration: existing settings.json files may contain an `"automatic"`
    /// raw value. Treat it, and any unknown raw value, as the local provider.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "automatic" {
            self = .local
            return
        }
        self = PickyVoiceProviderSelection(rawValue: rawValue) ?? .local
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
        case .off: L10n.t("enum.thinking.off")
        case .minimal: L10n.t("enum.thinking.minimal")
        case .low: L10n.t("enum.thinking.low")
        case .medium: L10n.t("enum.thinking.medium")
        case .high: L10n.t("enum.thinking.high")
        case .xhigh: L10n.t("enum.thinking.xhigh")
        }
    }
}

enum PickyPickleAgentThinkingLevel: String, Codable, CaseIterable, Identifiable {
    case automatic
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: L10n.t("enum.thinking.pickleAuto")
        case .off: L10n.t("enum.thinking.off")
        case .minimal: L10n.t("enum.thinking.minimal")
        case .low: L10n.t("enum.thinking.low")
        case .medium: L10n.t("enum.thinking.medium")
        case .high: L10n.t("enum.thinking.high")
        case .xhigh: L10n.t("enum.thinking.xhigh")
        }
    }

    var agentdValue: String? {
        switch self {
        case .automatic: nil
        case .off, .minimal, .low, .medium, .high, .xhigh: rawValue
        }
    }
}

enum PickyMainAgentRuntimeMode: String, Codable, CaseIterable, Identifiable {
    case pi
    case openAIRealtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: "Pi"
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
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X-High"
        }
    }
}

/// Auth strategy for the OpenAI Realtime runtime.
/// `codexOAuth` (default) reuses the signed-in ChatGPT subscription token from
/// pi AuthStorage so users do not need to register a Platform API key.
/// `apiKey` keeps the explicit `sk-...` Platform key path for users who prefer
/// it (and is required for the Azure OpenAI provider).
enum PickyOpenAIRealtimeAuthMode: String, Codable, CaseIterable, Identifiable {
    case codexOAuth
    case apiKey

    var id: String { rawValue }

    var protocolValue: String { rawValue }

    var displayName: String {
        switch self {
        case .codexOAuth: "ChatGPT 로그인 (Codex OAuth)"
        case .apiKey: "Platform API key (sk-…)"
        }
    }
}

struct PickyOpenAIRealtimeSettings: Codable, Equatable {
    var provider: PickyOpenAIRealtimeProvider
    var authMode: PickyOpenAIRealtimeAuthMode
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
        authMode: .codexOAuth,
        apiKey: "",
        modelOrDeployment: "gpt-realtime-2",
        azureRealtimeURL: "",
        azureResourceEndpoint: "",
        azureAPIVersion: "",
        azureAPIShape: .ga,
        voice: "marin",
        reasoningEffort: .high,
        transcriptionLanguage: ""
    )

    init(
        provider: PickyOpenAIRealtimeProvider,
        authMode: PickyOpenAIRealtimeAuthMode = .codexOAuth,
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
        self.authMode = authMode
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
        case authMode
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
        // Legacy settings written before Codex OAuth landed do not include
        // authMode; treat that history as the explicit apiKey path so existing
        // Platform API key users keep working until they opt into ChatGPT login.
        let decodedAuthMode = try container.decodeIfPresent(PickyOpenAIRealtimeAuthMode.self, forKey: .authMode)
        let decodedApiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        authMode = decodedAuthMode ?? (decodedApiKey.isEmpty ? defaults.authMode : .apiKey)
        apiKey = decodedApiKey
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
        try container.encode(authMode, forKey: .authMode)
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

/// Legacy Sparkle update channel value kept for settings-file compatibility.
/// Runtime update eligibility is now fixed by the app bundle's release channel;
/// see docs/auto-update.md.
enum PickyUpdateChannel: String, Codable, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }
}

enum PickyScreenContextScope: String, Codable, CaseIterable, Identifiable {
    case allScreens
    case focusedScreen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allScreens: L10n.t("enum.screenScope.allScreens")
        case .focusedScreen: L10n.t("enum.screenScope.focused")
        }
    }
}

enum PickyScreenshotQuality: String, Codable, CaseIterable, Identifiable {
    case standard
    case onePointFive
    case double

    static let defaultMaximumDimension = 1280

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "1× (1280 px)"
        case .onePointFive: "1.5× (1920 px)"
        case .double: "2× (2560 px)"
        }
    }

    var maximumDimension: Int {
        switch self {
        case .standard: Self.defaultMaximumDimension
        case .onePointFive: 1920
        case .double: 2560
        }
    }
}

/// Whether the dock rail runs vertically along a screen side or horizontally
/// along the screen top/bottom. Derived from `PickyHUDDockSide`; the side enum
/// is the source of truth so per-display state stays a single field on disk.
enum PickyHUDDockOrientation: String, Codable, CaseIterable, Equatable {
    case vertical
    case horizontal
}

/// Screen edge where the Pickle HUD dock is anchored.
/// Defaults to `.right` to preserve existing behavior for users without the key
/// in their settings file. The dock handle double-click toggles between the
/// vertical and horizontal layouts; `.left/.right` map to the vertical layout
/// pinned to a screen side, `.top/.bottom` map to the horizontal layout pinned
/// to a screen top/bottom edge.
enum PickyHUDDockSide: String, Codable, CaseIterable, Identifiable {
    case right
    case left
    case top
    case bottom

    var id: String { rawValue }

    var orientation: PickyHUDDockOrientation {
        switch self {
        case .left, .right: .vertical
        case .top, .bottom: .horizontal
        }
    }

    /// Flip to the opposite edge within the same orientation.
    /// Used by the existing left/right snap math; horizontal callers can use the
    /// new `.top/.bottom` symmetry the same way.
    var toggled: PickyHUDDockSide {
        switch self {
        case .right: .left
        case .left: .right
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// Switch orientation while preserving a sensible side on the new axis.
    /// `anchorPercent` is interpreted as the long-axis position (Y% in vertical,
    /// X% in horizontal); a value below 50 in vertical mode means the dock is
    /// in the upper half of the screen, so flipping to horizontal lands on `.top`.
    func orientationToggled(anchorPercent: Double) -> PickyHUDDockSide {
        switch self {
        case .left, .right:
            return anchorPercent < 50 ? .top : .bottom
        case .top, .bottom:
            // Always return to `.right` when toggling back to vertical so the
            // dock lands somewhere predictable; users can drag to `.left` again.
            return .right
        }
    }
}

/// Per-display dock position state. Each display keeps its own side, anchor percent,
/// and horizontal offset so users can place the dock differently on each monitor.
struct PickyHUDDockPosition: Codable, Equatable {
    static let defaultKey = "default"

    var side: PickyHUDDockSide
    var anchorPercent: Double
    /// Cross-axis nudge in vertical mode (left/right pixel delta from the
    /// natural pinned X) and along-axis pixel delta from screen center in
    /// horizontal mode.
    var xOffset: CGFloat
    /// Cross-axis nudge in horizontal mode (Y pixel delta from the natural
    /// top/bottom pinned position). Unused in vertical mode. Defaults to 0
    /// so existing per-display settings on disk decode without migration.
    var yOffset: CGFloat

    init(
        side: PickyHUDDockSide,
        anchorPercent: Double,
        xOffset: CGFloat,
        yOffset: CGFloat = 0
    ) {
        self.side = side
        self.anchorPercent = anchorPercent
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        side = try container.decode(PickyHUDDockSide.self, forKey: .side)
        anchorPercent = try container.decode(Double.self, forKey: .anchorPercent)
        xOffset = try container.decode(CGFloat.self, forKey: .xOffset)
        yOffset = try container.decodeIfPresent(CGFloat.self, forKey: .yOffset) ?? 0
    }

    static func defaults() -> PickyHUDDockPosition {
        PickyHUDDockPosition(
            side: .right,
            anchorPercent: PickySettings.defaultDockTopAnchorPercent,
            xOffset: 0,
            yOffset: 0
        )
    }

    static func resolved(in positions: [String: PickyHUDDockPosition], displayKey: String) -> PickyHUDDockPosition {
        positions[displayKey] ?? positions[defaultKey] ?? defaults()
    }
}

/// User-facing size preset for the Pickle HUD dock rail. Large maps to the
/// original redesigned dimensions; Medium and Small step down from there.
enum PickyHUDDockSizePreset: String, Codable, CaseIterable, Identifiable {
    case small = "s"
    case medium = "m"
    case large = "l"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    var scale: Double {
        switch self {
        case .small: 0.72
        case .medium: 0.86
        case .large: 1.0
        }
    }
}

/// User-resized conversation card dimensions for the Pickle HUD. Stored per display
/// so a large external monitor can keep a wider card without making the laptop HUD
/// unusable. Missing entries mean "use the built-in automatic size".
struct PickyHUDCardSize: Codable, Equatable {
    var width: CGFloat
    var height: CGFloat

    static let defaultWidth: CGFloat = PickyHUDDockLayout.detailWidth
    static let defaultHeight: CGFloat = 420
    // Hard cap is intentionally large; the real ceiling is computed per-screen at
    // runtime by `PickyHUDOverlayManager.computeAvailableCardMaxWidth/Height` so the
    // card can grow to nearly the full visibleFrame on big external displays.
    static let widthRange: ClosedRange<CGFloat> = 360...10_000
    static let heightRange: ClosedRange<CGFloat> = 320...10_000

    static func defaults() -> PickyHUDCardSize {
        PickyHUDCardSize(width: defaultWidth, height: defaultHeight)
    }

    static func clamped(
        width: CGFloat,
        height: CGFloat,
        maxWidth: CGFloat = widthRange.upperBound,
        maxHeight: CGFloat = heightRange.upperBound
    ) -> PickyHUDCardSize {
        let resolvedMaxWidth = max(widthRange.lowerBound, min(widthRange.upperBound, maxWidth))
        let resolvedMaxHeight = max(heightRange.lowerBound, min(heightRange.upperBound, maxHeight))
        return PickyHUDCardSize(
            width: min(max(width, widthRange.lowerBound), resolvedMaxWidth).rounded(.toNearestOrAwayFromZero),
            height: min(max(height, heightRange.lowerBound), resolvedMaxHeight).rounded(.toNearestOrAwayFromZero)
        )
    }

    func clamped(maxWidth: CGFloat = widthRange.upperBound, maxHeight: CGFloat = heightRange.upperBound) -> PickyHUDCardSize {
        Self.clamped(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

/// Persisted frame for one of Picky's detached AppKit panels (markdown report viewer,
/// tool history viewer, Pi terminal overlay). Replaces NSWindow's `setFrameAutosaveName`,
/// which silently no-ops on every panel after the first when several share the same
/// autosave slot. Saving a single struct per panel kind makes the latest user-moved
/// frame win regardless of how many panels of that kind are simultaneously open.
struct PickyDetachedPanelFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Parses the screen-relative frame string AppKit writes for `setFrameAutosaveName(_:)`
    /// (e.g. `"0 12 960 1055 0 0 1728 1079"`). Used as a one-shot migration so users who
    /// already have a saved position in `UserDefaults` don't lose it when we move
    /// persistence into `PickySettings`. Returns nil for any malformed value.
    static func parseLegacyAutosave(_ raw: String) -> PickyDetachedPanelFrame? {
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true).compactMap { Double($0) }
        guard parts.count >= 4 else { return nil }
        let width = CGFloat(parts[2])
        let height = CGFloat(parts[3])
        guard width > 0, height > 0 else { return nil }
        return PickyDetachedPanelFrame(x: CGFloat(parts[0]), y: CGFloat(parts[1]), width: width, height: height)
    }
}

/// User zoom level for the markdown report viewer, Pi terminal overlay, and the
/// global app surface (HUD/Conversation/Companion/Settings/Feedback). Each surface
/// keeps its own multiplier so increasing terminal cell density does not also blow up
/// the markdown body. Bounded by `PickyFontScales.minimum`/`.maximum` (or the
/// narrower app range) before persisting so a corrupted settings file can't push the
/// UI into an unusable scale on next launch.
struct PickyFontScales: Codable, Equatable {
    var markdownReport: Double
    var terminal: Double
    /// Global app font scale. Narrower range than report/terminal because the app
    /// surface has fixed-width controls that can't absorb arbitrary zoom.
    var app: Double

    static let minimum: Double = 0.7
    static let maximum: Double = 2.5
    static let step: Double = 0.1
    /// App-wide scale stays within 0.9...1.3 (10% steps) — outside this band the
    /// Companion/Settings forms truncate fixed-width controls.
    static let appMinimum: Double = 0.9
    static let appMaximum: Double = 1.3
    static let appStep: Double = 0.1
    static let defaults = PickyFontScales(markdownReport: 1.0, terminal: 1.0, app: 1.0)

    static func clamped(_ value: Double) -> Double {
        // Round to one decimal to avoid floating-point drift accumulating across `+0.1` taps.
        let rounded = (value * 10).rounded() / 10
        return min(max(rounded, minimum), maximum)
    }

    static func clampedApp(_ value: Double) -> Double {
        let rounded = (value * 10).rounded() / 10
        return min(max(rounded, appMinimum), appMaximum)
    }
}

/// User-configurable toggles deciding which session status transitions emit a macOS
/// banner via `PickySystemNotificationCenter`. Completion banners default off because they
/// fire on every routine finish; failures and input requests stay on so users don't miss
/// the cases that actually need attention.
struct PickyNotificationPreferences: Codable, Equatable {
    var notifyOnCompleted: Bool
    var notifyOnFailed: Bool
    var notifyOnWaitingForInput: Bool

    static let defaults = PickyNotificationPreferences(
        notifyOnCompleted: false,
        notifyOnFailed: true,
        notifyOnWaitingForInput: true
    )
}

/// User-configurable behavior toggles for the Pi cursor buddy overlay.
struct PickyCursorPreferences: Codable, Equatable {
    var showPiCursor: Bool
    var enableFollowSpringAnimation: Bool
    var enableIdleAnimations: Bool

    static let defaults = PickyCursorPreferences(
        showPiCursor: true,
        enableFollowSpringAnimation: true,
        enableIdleAnimations: true
    )

    enum CodingKeys: String, CodingKey {
        case showPiCursor
        case enableFollowSpringAnimation
        case enableIdleAnimations
    }

    init(
        showPiCursor: Bool,
        enableFollowSpringAnimation: Bool = true,
        enableIdleAnimations: Bool
    ) {
        self.showPiCursor = showPiCursor
        self.enableFollowSpringAnimation = enableFollowSpringAnimation
        self.enableIdleAnimations = enableIdleAnimations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickyCursorPreferences.defaults
        showPiCursor = try container.decodeIfPresent(Bool.self, forKey: .showPiCursor) ?? defaults.showPiCursor
        enableFollowSpringAnimation = try container.decodeIfPresent(Bool.self, forKey: .enableFollowSpringAnimation) ?? defaults.enableFollowSpringAnimation
        enableIdleAnimations = try container.decodeIfPresent(Bool.self, forKey: .enableIdleAnimations) ?? defaults.enableIdleAnimations
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showPiCursor, forKey: .showPiCursor)
        try container.encode(enableFollowSpringAnimation, forKey: .enableFollowSpringAnimation)
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
    /// Empty means auto-discover: PI_CODING_AGENT_DIR/bin/pi, PATH (`which pi`),
    /// then the legacy ~/.pi/agent/bin/pi fallback.
    var piBinaryPath: String
    /// Empty means use PI_CODING_AGENT_DIR from the launch environment when present,
    /// infer from the resolved `pi` binary when possible, then fallback to ~/.pi/agent.
    var piCodingAgentDir: String
    var sttProvider: PickyVoiceProviderSelection
    var ttsProvider: PickyVoiceProviderSelection
    /// When false, Picky still shows text replies but skips spoken TTS playback.
    var ttsEnabled: Bool
    /// Names of Picky built-in tools the user has explicitly disabled. Empty by
    /// default; the daemon filters these out of the main agent runtime on next
    /// reset. Unknown names are tolerated so older clients survive new tool
    /// additions.
    var disabledBuiltinTools: Set<PickyBuiltinTool>
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
    // OpenAI direct (api.openai.com) — TTS/STT keys are kept separate to mirror
    // the Azure layout above. Empty values mean "not configured".
    var openAITTSAPIKey: String
    var openAITTSVoice: String
    var openAITTSModel: String
    var openAISTTAPIKey: String
    var openAISTTModel: String
    var openAISTTPreferredLanguage: String
    /// OpenAI TTS base URL override. Empty = default api.openai.com. Setting this
    /// lets the user point Picky at any OpenAI-compatible HTTP server (e.g. a
    /// local proxy that translates to Edge TTS, LocalAI, Piper, Together, Groq,
    /// or self-hosted inference). Picky never reads what runs behind this URL —
    /// it just speaks the standard OpenAI Audio protocol. Validation happens at
    /// trim time; an unparseable string falls back to the default at runtime.
    var openAITTSBaseURL: String

    /// OpenAI STT base URL override. Same semantics as `openAITTSBaseURL` for
    /// the transcriptions endpoint.
    var openAISTTBaseURL: String
    // ElevenLabs TTS — empty values fall back to environment variables. The TTS
    // API key also falls back to the STT key so one ElevenLabs token can power
    // both directions when users leave the dedicated TTS field blank.
    var elevenLabsTTSAPIKey: String
    var elevenLabsTTSVoiceID: String
    var elevenLabsTTSModel: String
    var elevenLabsTTSOutputFormat: String
    var elevenLabsTTSBaseURL: String
    // ElevenLabs STT — empty `elevenLabsSTTModel` falls back to
    // `ElevenLabsTranscriptionProvider.defaultModelID` (currently `scribe_v2`;
    // the legacy `scribe_v1` is deprecated by ElevenLabs as of 2026).
    var elevenLabsSTTAPIKey: String
    var elevenLabsSTTModel: String
    var elevenLabsSTTLanguage: String
    var appearance: PickyAppearanceMode
    var notifications: PickyNotificationPreferences
    var cursor: PickyCursorPreferences
    var overlayBubbles: PickyOverlayBubblePreferences
    var fontScales: PickyFontScales
    var mainAgentRuntimeMode: PickyMainAgentRuntimeMode
    /// One-shot compatibility marker for users who installed a
    /// PICKY_REALTIME_OPT_IN=1 build before runtime mode became a user setting.
    var mainAgentRuntimeModeRealtimeOptInMigrationApplied: Bool
    var openAIRealtime: PickyOpenAIRealtimeSettings
    /// Empty means Picky follows Pi's own default model/settings. Non-empty is a
    /// provider/model pattern returned by picky-agentd, for example `anthropic/claude-sonnet-4-5`.
    var mainAgentModelPattern: String
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel
    /// Empty/automatic means new Pickles follow Pi's global defaults. Non-empty values are
    /// initial overrides applied only when a Pickle runtime is created; users can still cycle
    /// model/thinking level inside the running Pickle afterward.
    var pickleAgentModelPattern: String
    var pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel
    var screenContextScope: PickyScreenContextScope
    var screenshotQuality: PickyScreenshotQuality
    /// When `true`, Picky drops the captured screenshots (and the otherwise
    /// empty `inkMarks`) from the context packet sent to the model unless the
    /// user actually drew a freehand mark during this turn. Screen capture
    /// itself still runs locally so the ink overlay can render on top — only
    /// the model-bound payload is gated. Default is `false` for parity with
    /// the long-standing always-attach behavior.
    var attachScreenshotsOnlyWhenInked: Bool
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
    /// Per-display group collapse/expand state keyed by display ID, then group
    /// ID. Each monitor manages its own collapsed groups independently; a
    /// missing entry falls back to the layout's stored `isCollapsed` default.
    var hudDockGroupCollapse: [String: [String: Bool]]
    /// S/M/L size preset for the Pickle dock rail only. The conversation card keeps
    /// its current width so the setting stays visually scoped to the dock.
    var hudDockSizePreset: PickyHUDDockSizePreset
    /// Per-display user-resized conversation card dimensions. Missing display entries
    /// use the built-in automatic card size.
    var hudCardSizes: [String: PickyHUDCardSize]
    /// Legacy Sparkle channel preference kept for settings-file compatibility.
    /// Current builds derive update eligibility from `PickyBuildInfo.releaseChannel`.
    var updateChannel: PickyUpdateChannel
    /// When false, Sparkle only checks for updates when the user picks
    /// "Check for Updates…" from the menu or the Status panel.
    var updatesAutomaticChecksEnabled: Bool
    /// Highest interactive onboarding revision this install has finished. The
    /// app compares against `PickyOnboardingVersion.current` on launch to
    /// decide whether to show the takeover overlay. Existing settings files
    /// missing this key are treated as already-completed so users updating in
    /// place don't get a surprise demo — fresh installs decode the field via
    /// `defaults()` (value 0) and qualify naturally.
    var onboardingCompletedVersion: Int
    /// `true` once the user explicitly **uninstalled** the `/usr/local/bin/picky`
    /// shell wrapper from Settings. Set so the app-launch auto-installer does
    /// not silently re-add the command after they removed it. The Settings
    /// Install button flips this back to `false` so they can opt back in.
    var shellCommandAutoInstallOptedOut: Bool
    /// When true (default) the main-thread watchdog runs and offers a
    /// recovery dialog when the UI becomes unresponsive. Off-switch is
    /// exposed for developers/QA who deliberately freeze the UI to debug.
    var mainThreadWatchdogEnabled: Bool
    /// User-facing chrome language. `.system` follows whatever language macOS
    /// surfaces via `Locale.preferredLanguages`; the explicit cases pin the
    /// app even when the OS is set to something else. Adding a language is
    /// just a new `PickyLanguage` case + catalog entry.
    var appLanguage: PickyLanguage
    /// Recently used working folders for manual Pickle creation. Kept small so
    /// the dock picker stays lightweight and focused on the common paths.
    var recentPickleCwds: [String]
    /// Last user-moved frame for each kind of detached panel (markdown report
    /// viewer, tool history viewer, Pi terminal overlay), keyed by
    /// `PickyDetachedPanelKind.rawValue`. Empty/missing entries fall back to
    /// the panel's built-in `targetFrame()`.
    var detachedPanelFrames: [String: PickyDetachedPanelFrame]
    /// User-configured click actions for the git chips (insertions/deletions
    /// and branch label) rendered on the Pickle conversation card. Empty
    /// actions mean "no action wired yet"; the chip click handler deep-links
    /// to Settings → Pickle for configuration.
    var gitChipActions: PickyGitChipActions
    /// Persisted dock layout for user-created Pickle groups. Source of truth
    /// for top-level icon/group order; ungrouped sessions live as
    /// `.session(id)` entries and groups as `.group(PickyDockGroup)` with
    /// their own ordered member lists. Empty on fresh installs and on builds
    /// older than the grouping feature — `PickySessionListViewModel` seeds it
    /// from the legacy `manualOrder` UserDefaults on first migration.
    var dockLayout: PickyDockLayout

    static let dockTopAnchorPercentRange: ClosedRange<Double> = 2.0...70.0
    static let defaultDockTopAnchorPercent: Double = 22.0
    static let maxStoredRecentPickleCwds = 8
    static let maxVisibleRecentPickleCwds = 5

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
        piBinaryPath: String = "",
        piCodingAgentDir: String = "",
        sttProvider: PickyVoiceProviderSelection = .local,
        ttsProvider: PickyVoiceProviderSelection = .local,
        ttsEnabled: Bool = true,
        disabledBuiltinTools: Set<PickyBuiltinTool> = [],
        azureOpenAIEndpoint: String = "",
        azureOpenAIAPIKey: String = "",
        azureOpenAITTSEndpoint: String = "",
        azureOpenAITTSAPIKey: String = "",
        azureOpenAITTSVoice: String = "",
        azureSTTPreferredLanguage: String = "",
        openAITTSAPIKey: String = "",
        openAITTSVoice: String = "",
        openAITTSModel: String = "",
        openAISTTAPIKey: String = "",
        openAISTTModel: String = "",
        openAISTTPreferredLanguage: String = "",
        openAITTSBaseURL: String = "",
        openAISTTBaseURL: String = "",
        elevenLabsTTSAPIKey: String = "",
        elevenLabsTTSVoiceID: String = "",
        elevenLabsTTSModel: String = "",
        elevenLabsTTSOutputFormat: String = "",
        elevenLabsTTSBaseURL: String = "",
        elevenLabsSTTAPIKey: String = "",
        elevenLabsSTTModel: String = "",
        elevenLabsSTTLanguage: String = "",
        appearance: PickyAppearanceMode = .dark,
        notifications: PickyNotificationPreferences = .defaults,
        cursor: PickyCursorPreferences = .defaults,
        overlayBubbles: PickyOverlayBubblePreferences = .defaults,
        fontScales: PickyFontScales = .defaults,
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi,
        mainAgentRuntimeModeRealtimeOptInMigrationApplied: Bool = false,
        openAIRealtime: PickyOpenAIRealtimeSettings = .defaults,
        mainAgentModelPattern: String = "",
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .off,
        pickleAgentModelPattern: String = "",
        pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel = .automatic,
        screenContextScope: PickyScreenContextScope = .focusedScreen,
        screenshotQuality: PickyScreenshotQuality = .onePointFive,
        attachScreenshotsOnlyWhenInked: Bool = false,
        useConversationCard: Bool = true,
        pushToTalkShortcut: PickyShortcutSpec = .defaultPushToTalk,
        quickInputShortcut: PickyShortcutSpec = .defaultQuickInput,
        hudDockPositions: [String: PickyHUDDockPosition] = [:],
        hudDockGroupCollapse: [String: [String: Bool]] = [:],
        hudDockSizePreset: PickyHUDDockSizePreset = .medium,
        hudCardSizes: [String: PickyHUDCardSize] = [:],
        updateChannel: PickyUpdateChannel = .stable,
        updatesAutomaticChecksEnabled: Bool = true,
        onboardingCompletedVersion: Int = 0,
        shellCommandAutoInstallOptedOut: Bool = false,
        mainThreadWatchdogEnabled: Bool = true,
        appLanguage: PickyLanguage = .system,
        recentPickleCwds: [String] = [],
        detachedPanelFrames: [String: PickyDetachedPanelFrame] = [:],
        gitChipActions: PickyGitChipActions = .empty,
        dockLayout: PickyDockLayout = .empty
    ) {
        self.defaultCwd = defaultCwd
        self.mainAgentCwd = mainAgentCwd ?? defaultCwd
        self.worktreeParent = worktreeParent
        self.preferredToolVisibility = preferredToolVisibility
        self.readOnlyInvestigationPreference = readOnlyInvestigationPreference
        self.daemonPath = daemonPath
        self.logPath = logPath
        self.piBinaryPath = piBinaryPath
        self.piCodingAgentDir = piCodingAgentDir
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
        self.ttsEnabled = ttsEnabled
        self.disabledBuiltinTools = disabledBuiltinTools
        self.azureOpenAIEndpoint = azureOpenAIEndpoint
        self.azureOpenAIAPIKey = azureOpenAIAPIKey
        self.azureOpenAITTSEndpoint = azureOpenAITTSEndpoint
        self.azureOpenAITTSAPIKey = azureOpenAITTSAPIKey
        self.azureOpenAITTSVoice = azureOpenAITTSVoice
        self.azureSTTPreferredLanguage = azureSTTPreferredLanguage
        self.openAITTSAPIKey = openAITTSAPIKey
        self.openAITTSVoice = openAITTSVoice
        self.openAITTSModel = openAITTSModel
        self.openAISTTAPIKey = openAISTTAPIKey
        self.openAISTTModel = openAISTTModel
        self.openAISTTPreferredLanguage = openAISTTPreferredLanguage
        self.openAITTSBaseURL = openAITTSBaseURL
        self.openAISTTBaseURL = openAISTTBaseURL
        self.elevenLabsTTSAPIKey = elevenLabsTTSAPIKey
        self.elevenLabsTTSVoiceID = elevenLabsTTSVoiceID
        self.elevenLabsTTSModel = elevenLabsTTSModel
        self.elevenLabsTTSOutputFormat = elevenLabsTTSOutputFormat
        self.elevenLabsTTSBaseURL = elevenLabsTTSBaseURL
        self.elevenLabsSTTAPIKey = elevenLabsSTTAPIKey
        self.elevenLabsSTTModel = elevenLabsSTTModel
        self.elevenLabsSTTLanguage = elevenLabsSTTLanguage
        self.appearance = appearance
        self.notifications = notifications
        self.cursor = cursor
        self.overlayBubbles = overlayBubbles
        self.fontScales = fontScales
        self.mainAgentRuntimeMode = mainAgentRuntimeMode
        self.mainAgentRuntimeModeRealtimeOptInMigrationApplied = mainAgentRuntimeModeRealtimeOptInMigrationApplied
        self.openAIRealtime = openAIRealtime
        self.mainAgentModelPattern = mainAgentModelPattern
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.pickleAgentModelPattern = pickleAgentModelPattern
        self.pickleAgentThinkingLevel = pickleAgentThinkingLevel
        self.screenContextScope = screenContextScope
        self.screenshotQuality = screenshotQuality
        self.attachScreenshotsOnlyWhenInked = attachScreenshotsOnlyWhenInked
        self.useConversationCard = useConversationCard
        self.pushToTalkShortcut = pushToTalkShortcut
        self.quickInputShortcut = quickInputShortcut
        self.hudDockPositions = hudDockPositions
        self.hudDockGroupCollapse = hudDockGroupCollapse
        self.hudDockSizePreset = hudDockSizePreset
        self.hudCardSizes = hudCardSizes
        self.updateChannel = updateChannel
        self.updatesAutomaticChecksEnabled = updatesAutomaticChecksEnabled
        self.onboardingCompletedVersion = onboardingCompletedVersion
        self.shellCommandAutoInstallOptedOut = shellCommandAutoInstallOptedOut
        self.mainThreadWatchdogEnabled = mainThreadWatchdogEnabled
        self.appLanguage = appLanguage
        self.recentPickleCwds = PickySettings.normalizedRecentPickleCwds(recentPickleCwds)
        self.detachedPanelFrames = detachedPanelFrames
        self.gitChipActions = gitChipActions
        self.dockLayout = dockLayout
    }

    static func defaultUpdateChannel(forReleaseChannel releaseChannel: String) -> PickyUpdateChannel {
        releaseChannel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "beta" ? .beta : .stable
    }

    static func defaults(
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        mainAgentRuntimeMode: PickyMainAgentRuntimeMode = .pi,
        seedDefaultWorkspace: Bool = true
    ) -> PickySettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The Picky workspace seeded under appSupportRoot is the default cwd
        // for both ad-hoc tasks and the always-on Picky main agent so Pi
        // auto-loads its `AGENTS.md` (persona + Pickle routing rules) without
        // any extra wiring. Decode fallback construction opts out because
        // Codable decoding must not create Pi-only workspace files as a side
        // effect, especially when loading a Realtime runtime settings file.
        let workspace = seedDefaultWorkspace
            ? PickyWorkspaceSeeder.seedDefaultWorkspace(
                appSupportRoot: appSupportRoot,
                mainAgentRuntimeMode: mainAgentRuntimeMode
            )
            : PickyWorkspaceSeeder.defaultWorkspacePath(appSupportRoot: appSupportRoot)
        return PickySettings(
            defaultCwd: workspace,
            mainAgentCwd: workspace,
            worktreeParent: home,
            preferredToolVisibility: "visible in context only",
            readOnlyInvestigationPreference: true,
            daemonPath: "bundled picky-agentd or local development agentd",
            logPath: appSupportRoot.appendingPathComponent("Logs", isDirectory: true).path,
            piBinaryPath: "",
            piCodingAgentDir: "",
            // Fresh installs default to Apple Speech so push-to-talk works
            // without requiring Codex/ChatGPT OAuth, OpenAI API keys, or Azure
            // credentials. Existing users keep whatever they previously chose
            // because settings.json is restored from disk and only overrides
            // explicit keys, not these defaults.
            sttProvider: .local,
            ttsProvider: .local,
            ttsEnabled: true,
            disabledBuiltinTools: [],
            azureOpenAIEndpoint: "",
            azureOpenAIAPIKey: "",
            azureOpenAITTSEndpoint: "",
            azureOpenAITTSAPIKey: "",
            azureOpenAITTSVoice: "",
            azureSTTPreferredLanguage: "",
            openAITTSAPIKey: "",
            openAITTSVoice: "",
            openAITTSModel: "",
            openAISTTAPIKey: "",
            openAISTTModel: "",
            openAISTTPreferredLanguage: "",
            openAITTSBaseURL: "",
            openAISTTBaseURL: "",
            elevenLabsTTSAPIKey: "",
            elevenLabsTTSVoiceID: "",
            elevenLabsTTSModel: "",
            elevenLabsTTSOutputFormat: "",
            elevenLabsTTSBaseURL: "",
            elevenLabsSTTAPIKey: "",
            elevenLabsSTTModel: "",
            elevenLabsSTTLanguage: "",
            appearance: .dark,
            notifications: .defaults,
            cursor: .defaults,
            overlayBubbles: .defaults,
            fontScales: .defaults,
            mainAgentRuntimeMode: mainAgentRuntimeMode,
            mainAgentRuntimeModeRealtimeOptInMigrationApplied: false,
            openAIRealtime: .defaults,
            mainAgentModelPattern: "",
            mainAgentThinkingLevel: .off,
            pickleAgentModelPattern: "",
            pickleAgentThinkingLevel: .automatic,
            screenContextScope: .focusedScreen,
            screenshotQuality: .onePointFive,
            attachScreenshotsOnlyWhenInked: false,
            useConversationCard: true,
            pushToTalkShortcut: .defaultPushToTalk,
            quickInputShortcut: .defaultQuickInput,
            hudDockPositions: [:],
            hudDockGroupCollapse: [:],
            hudDockSizePreset: .medium,
            hudCardSizes: [:],
            updateChannel: defaultUpdateChannel(forReleaseChannel: AppBundleConfiguration.releaseChannel),
            updatesAutomaticChecksEnabled: true,
            onboardingCompletedVersion: 0,
            shellCommandAutoInstallOptedOut: false,
            mainThreadWatchdogEnabled: true,
            appLanguage: .system,
            recentPickleCwds: [],
            detachedPanelFrames: [:],
            gitChipActions: .empty,
            dockLayout: .empty
        )
    }

    func normalizedPaths() -> PickySettings {
        var copy = self
        copy.defaultCwd = NSString(string: defaultCwd).expandingTildeInPath
        copy.mainAgentCwd = NSString(string: mainAgentCwd).expandingTildeInPath
        if !worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.worktreeParent = NSString(string: worktreeParent).expandingTildeInPath
        }
        if let normalizedPiBinaryPath = PickyPiInstallation.normalizedPath(piBinaryPath) {
            copy.piBinaryPath = normalizedPiBinaryPath
        } else {
            copy.piBinaryPath = ""
        }
        if let normalizedPiCodingAgentDir = PickyPiInstallation.normalizedPath(piCodingAgentDir) {
            copy.piCodingAgentDir = normalizedPiCodingAgentDir
        } else {
            copy.piCodingAgentDir = ""
        }
        copy.azureOpenAIEndpoint = azureOpenAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAIAPIKey = azureOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAITTSEndpoint = azureOpenAITTSEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAITTSAPIKey = azureOpenAITTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureOpenAITTSVoice = azureOpenAITTSVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.azureSTTPreferredLanguage = azureSTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSAPIKey = openAITTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSVoice = openAITTSVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSModel = openAITTSModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTAPIKey = openAISTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTModel = openAISTTModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTPreferredLanguage = openAISTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSBaseURL = openAITTSBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTBaseURL = openAISTTBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsTTSAPIKey = elevenLabsTTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsTTSVoiceID = elevenLabsTTSVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsTTSModel = elevenLabsTTSModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsTTSOutputFormat = elevenLabsTTSOutputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsTTSBaseURL = elevenLabsTTSBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsSTTAPIKey = elevenLabsSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsSTTModel = elevenLabsSTTModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsSTTLanguage = elevenLabsSTTLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAIRealtime = openAIRealtime.normalized()
        copy.mainAgentModelPattern = mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pickleAgentModelPattern = pickleAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hudCardSizes = hudCardSizes.mapValues { $0.clamped() }
        copy.recentPickleCwds = Self.normalizedRecentPickleCwds(recentPickleCwds)
        return copy
    }

    static func normalizedRecentPickleCwd(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (NSString(string: trimmed).expandingTildeInPath as NSString).standardizingPath
    }

    static func normalizedRecentPickleCwds(_ cwds: [String]) -> [String] {
        var normalized: [String] = []
        for cwd in cwds {
            guard let path = normalizedRecentPickleCwd(cwd), !normalized.contains(path) else { continue }
            normalized.append(path)
            if normalized.count == maxStoredRecentPickleCwds { break }
        }
        return normalized
    }

    mutating func recordRecentPickleCwd(_ cwd: String) {
        guard let path = Self.normalizedRecentPickleCwd(cwd) else { return }
        recentPickleCwds.removeAll { $0 == path }
        recentPickleCwds.insert(path, at: 0)
        recentPickleCwds = Array(recentPickleCwds.prefix(Self.maxStoredRecentPickleCwds))
    }

    mutating func removeRecentPickleCwd(_ cwd: String) {
        guard let path = Self.normalizedRecentPickleCwd(cwd) else { return }
        recentPickleCwds.removeAll { $0 == path }
    }

    enum CodingKeys: String, CodingKey {
        case defaultCwd
        case mainAgentCwd
        case worktreeParent
        case preferredToolVisibility
        case readOnlyInvestigationPreference
        case daemonPath
        case logPath
        case piBinaryPath
        case piCodingAgentDir
        case sttProvider
        case ttsProvider
        case ttsEnabled
        case disabledBuiltinTools
        case azureOpenAIEndpoint
        case azureOpenAIAPIKey
        case azureOpenAITTSEndpoint
        case azureOpenAITTSAPIKey
        case azureOpenAITTSVoice
        case azureSTTPreferredLanguage
        case openAITTSAPIKey
        case openAITTSVoice
        case openAITTSModel
        case openAISTTAPIKey
        case openAISTTModel
        case openAISTTPreferredLanguage
        case openAITTSBaseURL
        case openAISTTBaseURL
        case elevenLabsTTSAPIKey
        case elevenLabsTTSVoiceID
        case elevenLabsTTSModel
        case elevenLabsTTSOutputFormat
        case elevenLabsTTSBaseURL
        case elevenLabsSTTAPIKey
        case elevenLabsSTTModel
        case elevenLabsSTTLanguage
        case appearance
        case notifications
        case cursor
        case overlayBubbles
        case fontScales
        case mainAgentRuntimeMode
        case mainAgentRuntimeModeRealtimeOptInMigrationApplied
        case openAIRealtime
        case mainAgentModelPattern
        case mainAgentThinkingLevel
        case pickleAgentModelPattern
        case pickleAgentThinkingLevel
        case screenContextScope
        case screenshotQuality
        case attachScreenshotsOnlyWhenInked
        case useConversationCard
        case pushToTalkShortcut
        case quickInputShortcut
        case hudDockPositions
        case hudDockGroupCollapse
        case hudDockSizePreset
        case hudCardSizes
        case updateChannel
        case updatesAutomaticChecksEnabled
        case onboardingCompletedVersion
        case shellCommandAutoInstallOptedOut
        case mainThreadWatchdogEnabled
        case appLanguage
        case recentPickleCwds
        case detachedPanelFrames
        case gitChipActions
        case dockLayout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PickySettings.defaults(seedDefaultWorkspace: false)

        defaultCwd = try container.decodeIfPresent(String.self, forKey: .defaultCwd) ?? defaults.defaultCwd
        mainAgentCwd = try container.decodeIfPresent(String.self, forKey: .mainAgentCwd) ?? defaultCwd
        worktreeParent = try container.decodeIfPresent(String.self, forKey: .worktreeParent) ?? defaults.worktreeParent
        preferredToolVisibility = try container.decodeIfPresent(String.self, forKey: .preferredToolVisibility) ?? defaults.preferredToolVisibility
        readOnlyInvestigationPreference = try container.decodeIfPresent(Bool.self, forKey: .readOnlyInvestigationPreference) ?? defaults.readOnlyInvestigationPreference
        daemonPath = try container.decodeIfPresent(String.self, forKey: .daemonPath) ?? defaults.daemonPath
        logPath = try container.decodeIfPresent(String.self, forKey: .logPath) ?? defaults.logPath
        piBinaryPath = try container.decodeIfPresent(String.self, forKey: .piBinaryPath) ?? defaults.piBinaryPath
        piCodingAgentDir = try container.decodeIfPresent(String.self, forKey: .piCodingAgentDir) ?? defaults.piCodingAgentDir
        sttProvider = try container.decodeIfPresent(PickyVoiceProviderSelection.self, forKey: .sttProvider) ?? defaults.sttProvider
        ttsProvider = try container.decodeIfPresent(PickyVoiceProviderSelection.self, forKey: .ttsProvider) ?? defaults.ttsProvider
        ttsEnabled = try container.decodeIfPresent(Bool.self, forKey: .ttsEnabled) ?? defaults.ttsEnabled
        let rawDisabled = try container.decodeIfPresent([String].self, forKey: .disabledBuiltinTools) ?? []
        disabledBuiltinTools = Set(rawDisabled.compactMap(PickyBuiltinTool.init(rawValue:)))
        azureOpenAIEndpoint = try container.decodeIfPresent(String.self, forKey: .azureOpenAIEndpoint) ?? defaults.azureOpenAIEndpoint
        azureOpenAIAPIKey = try container.decodeIfPresent(String.self, forKey: .azureOpenAIAPIKey) ?? defaults.azureOpenAIAPIKey
        azureOpenAITTSEndpoint = try container.decodeIfPresent(String.self, forKey: .azureOpenAITTSEndpoint) ?? defaults.azureOpenAITTSEndpoint
        azureOpenAITTSAPIKey = try container.decodeIfPresent(String.self, forKey: .azureOpenAITTSAPIKey) ?? defaults.azureOpenAITTSAPIKey
        azureOpenAITTSVoice = try container.decodeIfPresent(String.self, forKey: .azureOpenAITTSVoice) ?? defaults.azureOpenAITTSVoice
        azureSTTPreferredLanguage = try container.decodeIfPresent(String.self, forKey: .azureSTTPreferredLanguage) ?? defaults.azureSTTPreferredLanguage
        openAITTSAPIKey = try container.decodeIfPresent(String.self, forKey: .openAITTSAPIKey) ?? defaults.openAITTSAPIKey
        openAITTSVoice = try container.decodeIfPresent(String.self, forKey: .openAITTSVoice) ?? defaults.openAITTSVoice
        openAITTSModel = try container.decodeIfPresent(String.self, forKey: .openAITTSModel) ?? defaults.openAITTSModel
        openAISTTAPIKey = try container.decodeIfPresent(String.self, forKey: .openAISTTAPIKey) ?? defaults.openAISTTAPIKey
        openAISTTModel = try container.decodeIfPresent(String.self, forKey: .openAISTTModel) ?? defaults.openAISTTModel
        openAISTTPreferredLanguage = try container.decodeIfPresent(String.self, forKey: .openAISTTPreferredLanguage) ?? defaults.openAISTTPreferredLanguage
        openAITTSBaseURL = try container.decodeIfPresent(String.self, forKey: .openAITTSBaseURL) ?? defaults.openAITTSBaseURL
        openAISTTBaseURL = try container.decodeIfPresent(String.self, forKey: .openAISTTBaseURL) ?? defaults.openAISTTBaseURL
        elevenLabsTTSAPIKey = try container.decodeIfPresent(String.self, forKey: .elevenLabsTTSAPIKey) ?? defaults.elevenLabsTTSAPIKey
        elevenLabsTTSVoiceID = try container.decodeIfPresent(String.self, forKey: .elevenLabsTTSVoiceID) ?? defaults.elevenLabsTTSVoiceID
        elevenLabsTTSModel = try container.decodeIfPresent(String.self, forKey: .elevenLabsTTSModel) ?? defaults.elevenLabsTTSModel
        elevenLabsTTSOutputFormat = try container.decodeIfPresent(String.self, forKey: .elevenLabsTTSOutputFormat) ?? defaults.elevenLabsTTSOutputFormat
        elevenLabsTTSBaseURL = try container.decodeIfPresent(String.self, forKey: .elevenLabsTTSBaseURL) ?? defaults.elevenLabsTTSBaseURL
        elevenLabsSTTAPIKey = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTAPIKey) ?? defaults.elevenLabsSTTAPIKey
        elevenLabsSTTModel = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTModel) ?? defaults.elevenLabsSTTModel
        elevenLabsSTTLanguage = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTLanguage) ?? defaults.elevenLabsSTTLanguage
        appearance = try container.decodeIfPresent(PickyAppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        notifications = try container.decodeIfPresent(PickyNotificationPreferences.self, forKey: .notifications) ?? defaults.notifications
        cursor = try container.decodeIfPresent(PickyCursorPreferences.self, forKey: .cursor) ?? defaults.cursor
        overlayBubbles = try container.decodeIfPresent(PickyOverlayBubblePreferences.self, forKey: .overlayBubbles) ?? defaults.overlayBubbles
        mainAgentRuntimeMode = try container.decodeIfPresent(PickyMainAgentRuntimeMode.self, forKey: .mainAgentRuntimeMode) ?? defaults.mainAgentRuntimeMode
        mainAgentRuntimeModeRealtimeOptInMigrationApplied = try container.decodeIfPresent(Bool.self, forKey: .mainAgentRuntimeModeRealtimeOptInMigrationApplied) ?? defaults.mainAgentRuntimeModeRealtimeOptInMigrationApplied
        openAIRealtime = try container.decodeIfPresent(PickyOpenAIRealtimeSettings.self, forKey: .openAIRealtime) ?? defaults.openAIRealtime
        mainAgentModelPattern = try container.decodeIfPresent(String.self, forKey: .mainAgentModelPattern) ?? defaults.mainAgentModelPattern
        mainAgentThinkingLevel = try container.decodeIfPresent(PickyMainAgentThinkingLevel.self, forKey: .mainAgentThinkingLevel) ?? defaults.mainAgentThinkingLevel
        pickleAgentModelPattern = try container.decodeIfPresent(String.self, forKey: .pickleAgentModelPattern) ?? defaults.pickleAgentModelPattern
        pickleAgentThinkingLevel = try container.decodeIfPresent(PickyPickleAgentThinkingLevel.self, forKey: .pickleAgentThinkingLevel) ?? defaults.pickleAgentThinkingLevel
        screenContextScope = try container.decodeIfPresent(PickyScreenContextScope.self, forKey: .screenContextScope) ?? defaults.screenContextScope
        screenshotQuality = try container.decodeIfPresent(PickyScreenshotQuality.self, forKey: .screenshotQuality) ?? defaults.screenshotQuality
        // Missing key on an existing settings file means the user updated in
        // place from a build that predates this toggle — preserve always-attach
        // behavior so screenshots do not silently disappear after the update.
        attachScreenshotsOnlyWhenInked = try container.decodeIfPresent(Bool.self, forKey: .attachScreenshotsOnlyWhenInked) ?? defaults.attachScreenshotsOnlyWhenInked
        useConversationCard = try container.decodeIfPresent(Bool.self, forKey: .useConversationCard) ?? defaults.useConversationCard
        hudDockGroupCollapse = try container.decodeIfPresent([String: [String: Bool]].self, forKey: .hudDockGroupCollapse) ?? defaults.hudDockGroupCollapse
        hudDockSizePreset = try container.decodeIfPresent(PickyHUDDockSizePreset.self, forKey: .hudDockSizePreset) ?? defaults.hudDockSizePreset
        hudCardSizes = (try container.decodeIfPresent([String: PickyHUDCardSize].self, forKey: .hudCardSizes) ?? defaults.hudCardSizes)
            .mapValues { $0.clamped() }
        updateChannel = try container.decodeIfPresent(PickyUpdateChannel.self, forKey: .updateChannel) ?? defaults.updateChannel
        updatesAutomaticChecksEnabled = try container.decodeIfPresent(Bool.self, forKey: .updatesAutomaticChecksEnabled) ?? defaults.updatesAutomaticChecksEnabled
        // Missing field on an existing settings file means the user updated in
        // place from a build that predates onboarding. Pretend they already
        // finished so the overlay doesn't ambush them; the Settings → Onboarding
        // page still exposes "Replay onboarding" for anyone who wants it.
        onboardingCompletedVersion = try container.decodeIfPresent(Int.self, forKey: .onboardingCompletedVersion)
            ?? PickyOnboardingVersion.current
        // Missing field on existing settings files (including users who
        // updated in place from a build before auto-install existed) decodes
        // to `false` so the launch trigger gets one chance to silently add the
        // command. Anyone who hates the auto-install can Uninstall once from
        // Settings to flip this to true.
        shellCommandAutoInstallOptedOut = try container.decodeIfPresent(Bool.self, forKey: .shellCommandAutoInstallOptedOut) ?? defaults.shellCommandAutoInstallOptedOut
        mainThreadWatchdogEnabled = try container.decodeIfPresent(Bool.self, forKey: .mainThreadWatchdogEnabled) ?? defaults.mainThreadWatchdogEnabled
        // Existing installs that predate localization decode as `.system` —
        // they'll follow whatever language they were already comfortable with
        // (the OS preference) without any visible change.
        appLanguage = try container.decodeIfPresent(PickyLanguage.self, forKey: .appLanguage) ?? defaults.appLanguage
        recentPickleCwds = Self.normalizedRecentPickleCwds(try container.decodeIfPresent([String].self, forKey: .recentPickleCwds) ?? defaults.recentPickleCwds)
        detachedPanelFrames = try container.decodeIfPresent([String: PickyDetachedPanelFrame].self, forKey: .detachedPanelFrames) ?? defaults.detachedPanelFrames
        gitChipActions = try container.decodeIfPresent(PickyGitChipActions.self, forKey: .gitChipActions) ?? defaults.gitChipActions
        // Missing dockLayout means the user is on a pre-grouping build. Decode
        // as empty and let `PickySessionListViewModel` rehydrate from the
        // legacy manualOrder UserDefaults so existing reorders survive the
        // upgrade.
        dockLayout = try container.decodeIfPresent(PickyDockLayout.self, forKey: .dockLayout) ?? defaults.dockLayout
        if let storedScales = try container.decodeIfPresent(PickyFontScales.self, forKey: .fontScales) {
            fontScales = PickyFontScales(
                markdownReport: PickyFontScales.clamped(storedScales.markdownReport),
                terminal: PickyFontScales.clamped(storedScales.terminal),
                app: PickyFontScales.clampedApp(storedScales.app)
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
    case invalidPiCodingAgentDir(String)
    case invalidPiBinaryPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefaultCwd(let path): "Pickle default cwd does not exist or is not a directory: \(path)"
        case .invalidMainAgentCwd(let path): "Picky cwd does not exist or is not a directory: \(path)"
        case .invalidWorktreeParent(let path): "Worktree parent does not exist or is not a directory: \(path)"
        case .invalidPiCodingAgentDir(let path): "PI_CODING_AGENT_DIR does not exist or is not a directory: \(path)"
        case .invalidPiBinaryPath(let path): "Pi binary path is not executable: \(path)"
        }
    }
}

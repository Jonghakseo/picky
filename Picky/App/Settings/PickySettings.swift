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
    case azure
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Local"
        case .openai: "OpenAI"
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
        case .azure:
            return "Azure OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    static func cases(for capability: PickyVoiceProviderCapability) -> [PickyVoiceProviderSelection] {
        [.local, .openai, .azure, .elevenLabs]
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
    var sttProvider: PickyVoiceProviderSelection
    var ttsProvider: PickyVoiceProviderSelection
    /// When false, Picky still shows text replies but skips spoken TTS playback.
    var ttsEnabled: Bool
    /// When false, agentd hides the seeded `picky_tell_plan` extension's tool
    /// from the main agent via `pi.setActiveTools`, and Picky silently drops
    /// any narration request that still arrives. Independent from `ttsEnabled`
    /// so users can keep companion replies spoken while opting out of the
    /// spoken work plan.
    var narrationEnabled: Bool
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
    // ElevenLabs STT — playback uses ElevenLabsSpeechConfiguration.fromEnvironment
    // which already exists. Only STT side needs new persisted fields.
    // Empty `elevenLabsSTTModel` falls back to `ElevenLabsTranscriptionProvider.defaultModelID`
    // (currently `scribe_v2`; the legacy `scribe_v1` is deprecated by ElevenLabs as of 2026).
    var elevenLabsSTTAPIKey: String
    var elevenLabsSTTModel: String
    var elevenLabsSTTLanguage: String
    var appearance: PickyAppearanceMode
    var notifications: PickyNotificationPreferences
    var cursor: PickyCursorPreferences
    var overlayBubbles: PickyOverlayBubblePreferences
    var fontScales: PickyFontScales
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
    /// User-facing chrome language. `.system` follows whatever language macOS
    /// surfaces via `Locale.preferredLanguages`; the explicit cases pin the
    /// app even when the OS is set to something else. Adding a language is
    /// just a new `PickyLanguage` case + catalog entry.
    var appLanguage: PickyLanguage
    /// Last user-moved frame for each kind of detached panel (markdown report
    /// viewer, tool history viewer, Pi terminal overlay), keyed by
    /// `PickyDetachedPanelKind.rawValue`. Empty/missing entries fall back to
    /// the panel's built-in `targetFrame()`.
    var detachedPanelFrames: [String: PickyDetachedPanelFrame]

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
        sttProvider: PickyVoiceProviderSelection = .local,
        ttsProvider: PickyVoiceProviderSelection = .local,
        ttsEnabled: Bool = true,
        narrationEnabled: Bool = true,
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
        elevenLabsSTTAPIKey: String = "",
        elevenLabsSTTModel: String = "",
        elevenLabsSTTLanguage: String = "",
        appearance: PickyAppearanceMode = .dark,
        notifications: PickyNotificationPreferences = .defaults,
        cursor: PickyCursorPreferences = .defaults,
        overlayBubbles: PickyOverlayBubblePreferences = .defaults,
        fontScales: PickyFontScales = .defaults,
        mainAgentModelPattern: String = "",
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel = .off,
        pickleAgentModelPattern: String = "",
        pickleAgentThinkingLevel: PickyPickleAgentThinkingLevel = .automatic,
        screenContextScope: PickyScreenContextScope = .focusedScreen,
        screenshotQuality: PickyScreenshotQuality = .onePointFive,
        useConversationCard: Bool = true,
        pushToTalkShortcut: PickyShortcutSpec = .defaultPushToTalk,
        quickInputShortcut: PickyShortcutSpec = .defaultQuickInput,
        hudDockPositions: [String: PickyHUDDockPosition] = [:],
        hudDockSizePreset: PickyHUDDockSizePreset = .medium,
        hudCardSizes: [String: PickyHUDCardSize] = [:],
        updateChannel: PickyUpdateChannel = .stable,
        updatesAutomaticChecksEnabled: Bool = true,
        onboardingCompletedVersion: Int = 0,
        shellCommandAutoInstallOptedOut: Bool = false,
        appLanguage: PickyLanguage = .system,
        detachedPanelFrames: [String: PickyDetachedPanelFrame] = [:]
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
        self.ttsEnabled = ttsEnabled
        self.narrationEnabled = narrationEnabled
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
        self.elevenLabsSTTAPIKey = elevenLabsSTTAPIKey
        self.elevenLabsSTTModel = elevenLabsSTTModel
        self.elevenLabsSTTLanguage = elevenLabsSTTLanguage
        self.appearance = appearance
        self.notifications = notifications
        self.cursor = cursor
        self.overlayBubbles = overlayBubbles
        self.fontScales = fontScales
        self.mainAgentModelPattern = mainAgentModelPattern
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.pickleAgentModelPattern = pickleAgentModelPattern
        self.pickleAgentThinkingLevel = pickleAgentThinkingLevel
        self.screenContextScope = screenContextScope
        self.screenshotQuality = screenshotQuality
        self.useConversationCard = useConversationCard
        self.pushToTalkShortcut = pushToTalkShortcut
        self.quickInputShortcut = quickInputShortcut
        self.hudDockPositions = hudDockPositions
        self.hudDockSizePreset = hudDockSizePreset
        self.hudCardSizes = hudCardSizes
        self.updateChannel = updateChannel
        self.updatesAutomaticChecksEnabled = updatesAutomaticChecksEnabled
        self.onboardingCompletedVersion = onboardingCompletedVersion
        self.shellCommandAutoInstallOptedOut = shellCommandAutoInstallOptedOut
        self.appLanguage = appLanguage
        self.detachedPanelFrames = detachedPanelFrames
    }

    static func defaultUpdateChannel(forReleaseChannel releaseChannel: String) -> PickyUpdateChannel {
        releaseChannel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "beta" ? .beta : .stable
    }

    static func defaults(appSupportRoot: URL = PickyAppSupport.defaultRoot()) -> PickySettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The Picky workspace seeded under appSupportRoot is the default cwd
        // for both ad-hoc tasks and the always-on Picky main agent so Pi
        // auto-loads its `AGENTS.md` (persona + Pickle routing rules) without
        // any extra wiring. The directory and the seed markdown file are
        // created here so first-launch settings validation succeeds.
        let workspace = PickyWorkspaceSeeder.seedDefaultWorkspace(appSupportRoot: appSupportRoot)
        return PickySettings(
            defaultCwd: workspace,
            mainAgentCwd: workspace,
            worktreeParent: home,
            preferredToolVisibility: "visible in context only",
            readOnlyInvestigationPreference: true,
            daemonPath: "bundled picky-agentd or local development agentd",
            logPath: appSupportRoot.appendingPathComponent("Logs", isDirectory: true).path,
            sttProvider: .local,
            ttsProvider: .local,
            ttsEnabled: true,
            narrationEnabled: true,
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
            elevenLabsSTTAPIKey: "",
            elevenLabsSTTModel: "",
            elevenLabsSTTLanguage: "",
            appearance: .dark,
            notifications: .defaults,
            cursor: .defaults,
            overlayBubbles: .defaults,
            fontScales: .defaults,
            mainAgentModelPattern: "",
            mainAgentThinkingLevel: .off,
            pickleAgentModelPattern: "",
            pickleAgentThinkingLevel: .automatic,
            screenContextScope: .focusedScreen,
            screenshotQuality: .onePointFive,
            useConversationCard: true,
            pushToTalkShortcut: .defaultPushToTalk,
            quickInputShortcut: .defaultQuickInput,
            hudDockPositions: [:],
            hudDockSizePreset: .medium,
            hudCardSizes: [:],
            updateChannel: defaultUpdateChannel(forReleaseChannel: AppBundleConfiguration.releaseChannel),
            updatesAutomaticChecksEnabled: true,
            onboardingCompletedVersion: 0,
            shellCommandAutoInstallOptedOut: false,
            appLanguage: .system,
            detachedPanelFrames: [:]
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
        copy.openAITTSAPIKey = openAITTSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSVoice = openAITTSVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSModel = openAITTSModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTAPIKey = openAISTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTModel = openAISTTModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTPreferredLanguage = openAISTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAITTSBaseURL = openAITTSBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openAISTTBaseURL = openAISTTBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsSTTAPIKey = elevenLabsSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsSTTModel = elevenLabsSTTModel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.elevenLabsSTTLanguage = elevenLabsSTTLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.mainAgentModelPattern = mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pickleAgentModelPattern = pickleAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hudCardSizes = hudCardSizes.mapValues { $0.clamped() }
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
        case ttsEnabled
        case narrationEnabled
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
        case elevenLabsSTTAPIKey
        case elevenLabsSTTModel
        case elevenLabsSTTLanguage
        case appearance
        case notifications
        case cursor
        case overlayBubbles
        case fontScales
        case mainAgentModelPattern
        case mainAgentThinkingLevel
        case pickleAgentModelPattern
        case pickleAgentThinkingLevel
        case screenContextScope
        case screenshotQuality
        case useConversationCard
        case pushToTalkShortcut
        case quickInputShortcut
        case hudDockPositions
        case hudDockSizePreset
        case hudCardSizes
        case updateChannel
        case updatesAutomaticChecksEnabled
        case onboardingCompletedVersion
        case shellCommandAutoInstallOptedOut
        case appLanguage
        case detachedPanelFrames
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
        ttsEnabled = try container.decodeIfPresent(Bool.self, forKey: .ttsEnabled) ?? defaults.ttsEnabled
        narrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .narrationEnabled) ?? defaults.narrationEnabled
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
        elevenLabsSTTAPIKey = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTAPIKey) ?? defaults.elevenLabsSTTAPIKey
        elevenLabsSTTModel = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTModel) ?? defaults.elevenLabsSTTModel
        elevenLabsSTTLanguage = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTLanguage) ?? defaults.elevenLabsSTTLanguage
        appearance = try container.decodeIfPresent(PickyAppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        notifications = try container.decodeIfPresent(PickyNotificationPreferences.self, forKey: .notifications) ?? defaults.notifications
        cursor = try container.decodeIfPresent(PickyCursorPreferences.self, forKey: .cursor) ?? defaults.cursor
        overlayBubbles = try container.decodeIfPresent(PickyOverlayBubblePreferences.self, forKey: .overlayBubbles) ?? defaults.overlayBubbles
        mainAgentModelPattern = try container.decodeIfPresent(String.self, forKey: .mainAgentModelPattern) ?? defaults.mainAgentModelPattern
        mainAgentThinkingLevel = try container.decodeIfPresent(PickyMainAgentThinkingLevel.self, forKey: .mainAgentThinkingLevel) ?? defaults.mainAgentThinkingLevel
        pickleAgentModelPattern = try container.decodeIfPresent(String.self, forKey: .pickleAgentModelPattern) ?? defaults.pickleAgentModelPattern
        pickleAgentThinkingLevel = try container.decodeIfPresent(PickyPickleAgentThinkingLevel.self, forKey: .pickleAgentThinkingLevel) ?? defaults.pickleAgentThinkingLevel
        screenContextScope = try container.decodeIfPresent(PickyScreenContextScope.self, forKey: .screenContextScope) ?? defaults.screenContextScope
        screenshotQuality = try container.decodeIfPresent(PickyScreenshotQuality.self, forKey: .screenshotQuality) ?? defaults.screenshotQuality
        useConversationCard = try container.decodeIfPresent(Bool.self, forKey: .useConversationCard) ?? defaults.useConversationCard
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
        // Existing installs that predate localization decode as `.system` —
        // they'll follow whatever language they were already comfortable with
        // (the OS preference) without any visible change.
        appLanguage = try container.decodeIfPresent(PickyLanguage.self, forKey: .appLanguage) ?? defaults.appLanguage
        detachedPanelFrames = try container.decodeIfPresent([String: PickyDetachedPanelFrame].self, forKey: .detachedPanelFrames) ?? defaults.detachedPanelFrames
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
        case .invalidDefaultCwd(let path): "Pickle default cwd does not exist or is not a directory: \(path)"
        case .invalidMainAgentCwd(let path): "Picky cwd does not exist or is not a directory: \(path)"
        case .invalidWorktreeParent(let path): "Worktree parent does not exist or is not a directory: \(path)"
        }
    }
}

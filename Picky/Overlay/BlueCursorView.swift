//
//  BlueCursorView.swift
//  Picky
//
//  SwiftUI cursor buddy rendering and navigation animation.
//

import AppKit
import Combine
import Darwin
import SwiftUI

// Picky needs to know when the *system* mouse cursor is hidden so the Picky
// mascot can hide alongside it (full-screen video players, games, the system
// idle-hide timer, the text-input auto-hide, etc.).
//
// Apple's only API for this question — `CGCursorIsVisible()` — is documented
// as deprecated since macOS 10.9 with "No replacement" (Apple's deprecation
// appendix). Because Picky's deployment target is well past 10.9, Swift's
// importer treats the declaration as unavailable and refuses to compile a
// direct call. The underlying implementation, however, is still exported by
// CoreGraphics and faithfully reflects the WindowServer's cursor-visibility
// state in practice, so we resolve the symbol dynamically. If some future
// macOS finally drops it, `dlsym` returns nil and `systemMouseCursorIsVisible`
// degrades to a conservative "assume visible" — the mascot then behaves
// exactly like it did before this hook existed instead of vanishing forever.
private typealias CGCursorIsVisibleFn = @convention(c) () -> UInt32
private let _cgCursorIsVisibleSymbol: CGCursorIsVisibleFn? = {
    // RTLD_DEFAULT is `(void *)-2`; Swift cannot import the macro, but
    // `UnsafeMutableRawPointer(bitPattern: -2)` reproduces it.
    guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else {
        return nil
    }
    return unsafeBitCast(raw, to: CGCursorIsVisibleFn.self)
}()

func systemMouseCursorIsVisible() -> Bool {
    guard let fn = _cgCursorIsVisibleSymbol else { return true }
    return fn() != 0
}

// Runtime-tweakable style values for the Pi-shaped cursor buddy icon.
private struct PickyCursorStyle: Codable, Equatable {
    var colorHex = "#3380FF"
    var listeningColorHex = "#F0B440"
    var processingColorHex = "#FFB224"
    var respondingColorHex = "#3380FF"
    var frameSize = 39.0
    var glowOpacity = 0.3
    var glowBlur = 0.3
    var glowScale = 1.18
    var glowSize = 14.0
    var iconSize = 19.5
    var mascotSize = 25.0
    var highlightOpacity = 0.12
    var highlightOffsetX = -0.4
    var highlightOffsetY = -0.4
    var outerShadowOpacity = 0.6
    var outerShadowRadius = 4.0
    var outerShadowFlightMultiplier = 45.0

    var cursorColor: Color { Color(hex: colorHex) }
    var listeningColor: Color { Color(hex: listeningColorHex) }
    var processingColor: Color { Color(hex: processingColorHex) }
    var respondingColor: Color { Color(hex: respondingColorHex) }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = PickyCursorStyle()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? defaults.colorHex
        listeningColorHex = try container.decodeIfPresent(String.self, forKey: .listeningColorHex) ?? defaults.listeningColorHex
        processingColorHex = try container.decodeIfPresent(String.self, forKey: .processingColorHex) ?? defaults.processingColorHex
        respondingColorHex = try container.decodeIfPresent(String.self, forKey: .respondingColorHex) ?? defaults.respondingColorHex
        frameSize = try container.decodeIfPresent(Double.self, forKey: .frameSize) ?? defaults.frameSize
        glowOpacity = try container.decodeIfPresent(Double.self, forKey: .glowOpacity) ?? defaults.glowOpacity
        glowBlur = try container.decodeIfPresent(Double.self, forKey: .glowBlur) ?? defaults.glowBlur
        glowScale = try container.decodeIfPresent(Double.self, forKey: .glowScale) ?? defaults.glowScale
        glowSize = try container.decodeIfPresent(Double.self, forKey: .glowSize) ?? defaults.glowSize
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? defaults.iconSize
        mascotSize = try container.decodeIfPresent(Double.self, forKey: .mascotSize) ?? defaults.mascotSize
        highlightOpacity = try container.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? defaults.highlightOpacity
        highlightOffsetX = try container.decodeIfPresent(Double.self, forKey: .highlightOffsetX) ?? defaults.highlightOffsetX
        highlightOffsetY = try container.decodeIfPresent(Double.self, forKey: .highlightOffsetY) ?? defaults.highlightOffsetY
        outerShadowOpacity = try container.decodeIfPresent(Double.self, forKey: .outerShadowOpacity) ?? defaults.outerShadowOpacity
        outerShadowRadius = try container.decodeIfPresent(Double.self, forKey: .outerShadowRadius) ?? defaults.outerShadowRadius
        outerShadowFlightMultiplier = try container.decodeIfPresent(Double.self, forKey: .outerShadowFlightMultiplier) ?? defaults.outerShadowFlightMultiplier
    }
}

#if DEBUG
@MainActor
private final class PickyCursorStyleStore: ObservableObject {
    static let shared = PickyCursorStyleStore()
    static let styleURL = PickyAppSupport.defaultRoot().appendingPathComponent("dev-cursor-style.json", isDirectory: false)

    @Published private(set) var style = PickyCursorStyle()

    private var timer: Timer?
    private var lastSignature: String?
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private init() {
        writeDefaultStyleFileIfNeeded()
        reloadIfChanged()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadIfChanged()
            }
        }
    }

    deinit { timer?.invalidate() }

    private func writeDefaultStyleFileIfNeeded() {
        let url = Self.styleURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(PickyCursorStyle())
            try data.write(to: url, options: .atomic)
        } catch {
            print("🖱️ Picky cursor style — failed to write default style: \(error.localizedDescription)")
        }
    }

    private func reloadIfChanged() {
        let url = Self.styleURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = attributes[.size] as? NSNumber
        let signature = "\(modifiedAt):\(size?.uint64Value ?? 0)"
        guard signature != lastSignature else { return }
        lastSignature = signature

        do {
            let data = try Data(contentsOf: url)
            style = try decoder.decode(PickyCursorStyle.self, from: data)
        } catch {
            print("🖱️ Picky cursor style — keeping previous style; invalid JSON at \(url.path): \(error.localizedDescription)")
        }
    }
}
#else
@MainActor
private final class PickyCursorStyleStore: ObservableObject {
    static let shared = PickyCursorStyleStore()
    @Published private(set) var style = PickyCursorStyle()
    private init() {}
}
#endif

@MainActor
private final class PickyCursorPreferencesStore: ObservableObject {
    static let shared = PickyCursorPreferencesStore()

    @Published private(set) var preferences: PickyCursorPreferences

    private let settingsStore: PickySettingsStore
    private var settingsChangeCancellable: AnyCancellable?

    private init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        self.preferences = settingsStore.load().cursor
        settingsChangeCancellable = NotificationCenter.default.publisher(for: .pickySettingsDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.preferences = self.settingsStore.load().cursor
            }
    }
}

@MainActor
private final class PickyOverlayBubblePreferencesStore: ObservableObject {
    static let shared = PickyOverlayBubblePreferencesStore()

    @Published private(set) var preferences: PickyOverlayBubblePreferences

    private let settingsStore: PickySettingsStore
    private var settingsChangeCancellable: AnyCancellable?

    private init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        self.preferences = settingsStore.load().overlayBubbles
        settingsChangeCancellable = NotificationCenter.default.publisher(for: .pickySettingsDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.preferences = self.settingsStore.load().overlayBubbles
            }
    }
}

// Picky logo cursor buddy icon. The `tint` parameter overrides the base
// vector color so the buddy can shift through mood colors (idle / listening /
// processing / responding) without swapping in a different raster asset.
//
// The geometry is adapted from the desktop `picky_*.svg` symbol candidates:
// two upper circles are the eyes, and the large lower V/check stroke is the
// mouth. Keeping it as SwiftUI vector paths lets the overlay recolor and
// animate the mascot per state at runtime.
private struct PickyCursorMascotView: View {
    let style: PickyCursorStyle
    let tint: Color
    let voiceState: CompanionVoiceState
    let idleAnimationsEnabled: Bool
    let isStartled: Bool

    @ViewBuilder
    var body: some View {
        if needsTimelineAnimation {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                mascotBody(
                    expression: expression(at: time),
                    scale: internalScale(at: time),
                    rotation: internalRotation(at: time),
                    processingPulse: processingPulse(at: time)
                )
            }
        } else {
            mascotBody(expression: isStartled ? .startled : .normal, scale: 1.0, rotation: 0, processingPulse: 0)
        }
    }

    private var needsTimelineAnimation: Bool {
        switch voiceState {
        case .idle:
            return idleAnimationsEnabled && !isStartled
        case .listening, .processing, .responding:
            return true
        }
    }

    private func mascotBody(
        expression: PickyCursorMascotExpression,
        scale: CGFloat,
        rotation: Double,
        processingPulse: Double
    ) -> some View {
        let assetName = assetName(for: expression)

        return ZStack {
            cursorAsset(named: assetName, tint: tint.opacity(style.glowOpacity))
                .frame(width: CGFloat(style.glowSize), height: CGFloat(style.glowSize))
                .blur(radius: CGFloat(style.glowBlur))
                .scaleEffect(CGFloat(style.glowScale) * scale)

            cursorAsset(named: assetName, tint: tint)
                .frame(width: CGFloat(style.mascotSize), height: CGFloat(style.mascotSize))
                .scaleEffect(scale)
                .rotationEffect(.degrees(rotation))

            // Processing pulse: while Picky is thinking, fade a white copy
            // of the mascot in and out on top of the amber body so the
            // cursor cycles amber -> white -> amber as a calm loading
            // indicator. The pulse opacity is computed from the timeline so
            // the effect runs at 60fps without disturbing the tint state
            // machine.
            if processingPulse > 0 {
                cursorAsset(named: assetName, tint: .white)
                    .frame(width: CGFloat(style.mascotSize), height: CGFloat(style.mascotSize))
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(rotation))
                    .opacity(processingPulse)
            }

            cursorAsset(named: assetName, tint: .white.opacity(style.highlightOpacity))
                .frame(width: CGFloat(style.mascotSize), height: CGFloat(style.mascotSize))
                .scaleEffect(scale)
                .rotationEffect(.degrees(rotation))
                .offset(x: CGFloat(style.highlightOffsetX), y: CGFloat(style.highlightOffsetY))
        }
        .frame(width: CGFloat(style.frameSize), height: CGFloat(style.frameSize))
    }

    private func processingPulse(at time: TimeInterval) -> Double {
        guard voiceState == .processing else { return 0 }
        // 1.3s breathing period feels like a calm loading indicator while
        // Picky is preparing the response.
        let cycle = (sin(time * (2.0 * .pi / 1.3)) + 1.0) * 0.5  // 0...1
        return cycle * 0.85
    }

    private func cursorAsset(named assetName: String, tint: Color) -> some View {
        Image(assetName)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(tint)
            .scaledToFit()
    }

    private func assetName(for expression: PickyCursorMascotExpression) -> String {
        switch expression {
        case .normal:
            return "PickyCursorNormal"
        case .blink:
            return "PickyCursorBlink"
        case .happy:
            return "PickyCursorHappy"
        case .wink:
            return "PickyCursorWink"
        case .startled:
            return "PickyCursorStartled"
        }
    }

    private func expression(at time: TimeInterval) -> PickyCursorMascotExpression {
        if isStartled { return .startled }
        switch voiceState {
        case .idle:
            guard idleAnimationsEnabled else { return .normal }
            return time.truncatingRemainder(dividingBy: 5.2) > 4.94 ? .blink : .normal
        case .listening:
            return time.truncatingRemainder(dividingBy: 1.4) < 0.7 ? .happy : .normal
        case .processing:
            return time.truncatingRemainder(dividingBy: 1.1) < 0.32 ? .wink : .normal
        case .responding:
            return time.truncatingRemainder(dividingBy: 2.0) < 1.35 ? .happy : .normal
        }
    }

    private func internalScale(at time: TimeInterval) -> CGFloat {
        switch voiceState {
        case .idle:
            return 1.0
        case .listening:
            return 1.0 + CGFloat((sin(time * 7.0) + 1.0) * 0.018)
        case .processing:
            return 1.02
        case .responding:
            return 1.0 + CGFloat((sin(time * 4.6) + 1.0) * 0.012)
        }
    }

    private func internalRotation(at time: TimeInterval) -> Double {
        switch voiceState {
        case .processing:
            return sin(time * 8.0) * 3.0
        default:
            return 0
        }
    }
}

private enum PickyCursorMascotExpression {
    case normal
    case blink
    case happy
    case wink
    case startled
}

private struct PickleTargetCursorMascotView: View {
    let style: PickyCursorStyle
    let tint: Color
    let voiceState: CompanionVoiceState
    let idleAnimationsEnabled: Bool
    let isStartled: Bool

    var body: some View {
        if needsTimelineAnimation {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                targetIcon(
                    scale: scale(at: time),
                    rotation: rotation(at: time),
                    processingPulse: processingPulse(at: time)
                )
            }
        } else {
            targetIcon(scale: 1.0, rotation: isStartled ? -5 : 0, processingPulse: 0)
        }
    }

    private var needsTimelineAnimation: Bool {
        switch voiceState {
        case .idle:
            idleAnimationsEnabled || isStartled
        case .listening, .processing, .responding:
            true
        }
    }

    private func targetIcon(scale: CGFloat, rotation: Double, processingPulse: Double) -> some View {
        let frame = CGFloat(style.frameSize)
        let iconSize = CGFloat(style.mascotSize) * 0.86
        let glowSize = CGFloat(style.mascotSize) * 0.74
        // Armed Pickle cursor reuses the same voiceState->color mapping as the
        // regular Picky cursor (via the `tint` argument from `moodColor`), so
        // idle/listening/processing/responding all match across both cursors.
        let glowColor = tint
        return ZStack {
            PickleLogoGlyph()
                .fill(glowColor.opacity(0.30), style: FillStyle(eoFill: true))
                .frame(width: glowSize, height: glowSize)
                .blur(radius: 1.8)
                .scaleEffect(1.26)

            PickleLogoGlyph()
                .fill(glowColor, style: FillStyle(eoFill: true))
                .frame(width: iconSize, height: iconSize)
                .shadow(color: Color.black.opacity(0.22), radius: 1.6, x: 0, y: 0.8)

            // Processing pulse: mirror the Picky mascot's amber -> white ->
            // amber loading cadence on the Pickle glyph so the armed cursor
            // also signals "thinking" while preparing a response.
            if processingPulse > 0 {
                PickleLogoGlyph()
                    .fill(Color.white, style: FillStyle(eoFill: true))
                    .frame(width: iconSize, height: iconSize)
                    .opacity(processingPulse)
            }
        }
        .frame(width: frame, height: frame)
        .scaleEffect(scale)
        .rotationEffect(.degrees(rotation))
        .animation(.easeInOut(duration: 0.18), value: voiceState)
    }

    private func processingPulse(at time: TimeInterval) -> Double {
        guard voiceState == .processing else { return 0 }
        // Match PickyCursorMascotView's 1.3s breathing period so the two
        // cursors pulse in sync when both states are active.
        let cycle = (sin(time * (2.0 * .pi / 1.3)) + 1.0) * 0.5
        return cycle * 0.85
    }

    private func scale(at time: TimeInterval) -> CGFloat {
        if isStartled { return 1.05 }
        switch voiceState {
        case .idle:
            return idleAnimationsEnabled ? 1.0 + CGFloat((sin(time * 2.2) + 1.0) * 0.010) : 1.0
        case .listening:
            return 1.0 + CGFloat((sin(time * 7.0) + 1.0) * 0.014)
        case .processing:
            return 1.025
        case .responding:
            return 1.0 + CGFloat((sin(time * 4.6) + 1.0) * 0.010)
        }
    }

    private func rotation(at time: TimeInterval) -> Double {
        if isStartled { return -5 }
        switch voiceState {
        case .processing:
            return sin(time * 8.0) * 2.0
        default:
            return 0
        }
    }
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// pi icon when it is. During voice interaction, the pi icon is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var cursorStyleStore = PickyCursorStyleStore.shared
    @ObservedObject private var cursorPreferencesStore = PickyCursorPreferencesStore.shared
    @ObservedObject private var overlayBubblePreferencesStore = PickyOverlayBubblePreferencesStore.shared

    static let cursorTrackingInterval: TimeInterval = 1.0 / 60.0
    static let shakeReactionRequiredDuration: TimeInterval = 2.0
    static let shakeReactionMinimumSpeed: CGFloat = 720
    static let shakeReactionMinimumDominantDelta: CGFloat = 5.5
    static let shakeReactionRequiredDirectionChanges = 8

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool
    // Mirrors the system mouse cursor visibility. Polled inside the existing
    // 60fps tracking timer so the mascot disappears in the same frame the
    // system pointer does.
    @State private var systemCursorVisible: Bool

    init(screenFrame: CGRect, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        _cursorPosition = State(initialValue: PickyOverlayGeometry.cursorBuddyPosition(for: mouseLocation, in: screenFrame))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
        _systemCursorVisible = State(initialValue: systemMouseCursorIsVisible())
    }
    @State private var timer: Timer?
    @State private var responseBubbleSize: CGSize = .zero
    @State private var voicePromptBubbleSize: CGSize = .zero
    @State private var onboardingBubbleSize: CGSize = .zero
    @State private var shakeReactionBubbleSize: CGSize = .zero
    @State private var cursorOpacity: Double = 1.0

    @State private var shakeWindowStartAt: TimeInterval?
    @State private var lastShakeSampleLocation: CGPoint?
    @State private var lastShakeSampleAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    @State private var lastShakeActiveAt: TimeInterval = 0
    @State private var lastShakeDirection: Int = 0
    @State private var lastShakeDirectionChangeAt: TimeInterval = 0
    @State private var shakeDirectionChanges: Int = 0
    @State private var shakeReactionUntil: TimeInterval = 0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy pi icon during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    /// Stable pointer id for every delayed callback in the current navigation.
    @State private var activePointerID: String?

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    @ViewBuilder
    private var cursorMascot: some View {
        if companionManager.screenContextTargetSessionID != nil {
            PickleTargetCursorMascotView(
                style: cursorStyleStore.style,
                tint: moodColor,
                voiceState: companionManager.voiceState,
                idleAnimationsEnabled: cursorPreferencesStore.preferences.enableIdleAnimations,
                isStartled: isShakeReactionActive
            )
        } else {
            PickyCursorMascotView(
                style: cursorStyleStore.style,
                tint: moodColor,
                voiceState: companionManager.voiceState,
                idleAnimationsEnabled: cursorPreferencesStore.preferences.enableIdleAnimations,
                isStartled: isShakeReactionActive
            )
        }
    }

    private var cursorFollowAnimation: Animation? {
        cursorPreferencesStore.preferences.enableFollowSpringAnimation
            ? .spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0)
            : nil
    }

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            if companionManager.inkOverlayState.isActive || !companionManager.inkOverlayState.strokes.isEmpty {
                PickyInkOverlayView(screenFrame: screenFrame, state: companionManager.inkOverlayState)
                    .allowsHitTesting(false)
            }


            // Fixed target highlight — independent of the cursor buddy animation so
            // pointer requests remain visible even on another display or while
            // the buddy is flying in/out.
            if let pointerTargetPosition {
                PickyHighlightOverlayView(
                    kind: companionManager.detectedElementHighlightKind ?? .screenElement,
                    targetCenter: pointerTargetPosition,
                    targetSize: pointerTargetSizeInThisScreen,
                    bubbleText: companionManager.detectedElementBubbleText,
                    screenSize: CGSize(width: screenFrame.width, height: screenFrame.height)
                )
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.18), value: pointerTargetPosition)
            }

            // Onboarding guide bubble — only present when the onboarding flow
            // controller has set guidance text. Rendered above the standard
            // voice/prompt bubbles so it always wins when the demo is active.
            // Runs through PickyBubbleMarkdown so action words can be wrapped
            // in `**bold**` and read more clearly.
            if isCursorOnThisScreen, let guideText = companionManager.onboardingBubbleText {
                let renderedText = PickyBubbleMarkdown.displayString(for: guideText)
                let attributedText = PickyBubbleMarkdown.highlightedAttributedText(
                    for: guideText,
                    // Amber pops against the blue bubble background and matches
                    // the ink-highlight color used in the captured-context
                    // preview, so the visual language is consistent.
                    highlightColor: Color(red: 1.0, green: 0.85, blue: 0.2)
                )
                let textWidth = PickyBubbleLayout.textWidth(
                    for: renderedText,
                    font: .systemFont(ofSize: 11, weight: .medium),
                    maxWidth: 320
                )
                Text(attributedText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .frame(width: textWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: Color.black.opacity(0.32), radius: 12, x: 0, y: 4)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 8, x: 0, y: 0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.42), lineWidth: 0.8)
                    )
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: OnboardingBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .position(cursorBubbleCenter(for: onboardingBubbleSize))
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .animation(.easeOut(duration: 0.22), value: guideText)
                    .onPreferenceChange(OnboardingBubbleSizePreferenceKey.self) { newSize in
                        onboardingBubbleSize = newSize
                    }
            }

            // Voice prompt bubble — once the push-to-talk button is released,
            // keep the recognized user prompt visible while Picky is preparing
            // and waiting for the Picky response.
            // Suppressed while the onboarding guide bubble is up so the two
            // don't overlap; the onboarding flow takes priority during the
            // demo and the prompt is already in the user's head anyway.
            if isCursorOnThisScreen,
               overlayBubblePreferencesStore.preferences.showUserSpeechRecognitionBubble,
               companionManager.voicePromptBubbleState.isVisible,
               companionManager.onboardingBubbleText == nil {
                let bubbleText = companionManager.voicePromptBubbleState.displayText
                let textWidth = PickyBubbleLayout.textWidth(
                    for: bubbleText,
                    font: .systemFont(ofSize: 11, weight: .medium),
                    maxWidth: 282
                )
                VoicePromptCursorBubbleView(text: bubbleText, textWidth: textWidth)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: VoicePromptBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .position(cursorBubbleCenter(for: voicePromptBubbleSize))
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .animation(.easeOut(duration: 0.2), value: companionManager.voiceState)
                    .animation(.easeOut(duration: 0.16), value: companionManager.voicePromptBubbleState)
                    .onPreferenceChange(VoicePromptBubbleSizePreferenceKey.self) { newSize in
                        voicePromptBubbleSize = newSize
                    }
            }

            // Short voice response bubble — mirrors quick TTS replies next to the cursor
            // so simple checks do not require opening the long-running agent HUD.
            // Also suppressed during onboarding so the guide bubble is the
            // single signal driving the cursor at that moment.
            if isCursorOnThisScreen,
               overlayBubblePreferencesStore.preferences.showPickyResponseBubble,
               companionManager.voiceState == .responding,
               let responseText = companionManager.latestAgentSessionSummary,
               !responseText.isEmpty,
               companionManager.onboardingBubbleText == nil {
                let renderedText = PickyBubbleMarkdown.displayString(for: responseText)
                let attributedText = PickyBubbleMarkdown.attributedText(for: responseText)
                let textWidth = PickyBubbleLayout.textWidth(
                    for: renderedText,
                    font: .systemFont(ofSize: 11, weight: .medium),
                    maxWidth: 302
                )
                Text(attributedText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .frame(width: textWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 4)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.48), radius: 8, x: 0, y: 0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.38), lineWidth: 0.8)
                    )
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ResponseBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .position(cursorBubbleCenter(for: responseBubbleSize))
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .animation(.easeOut(duration: 0.2), value: companionManager.voiceState)
                    .onPreferenceChange(ResponseBubbleSizePreferenceKey.self) { newSize in
                        responseBubbleSize = newSize
                    }
            }

            if isCursorOnThisScreen, isShakeReactionActive {
                PickyShakeReactionBubbleView(text: PickyShakeReactionText.current)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ShakeReactionBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .position(cursorBubbleCenter(for: shakeReactionBubbleSize, horizontalGap: 10, verticalGap: 16))
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .onPreferenceChange(ShakeReactionBubbleSizePreferenceKey.self) { newSize in
                        shakeReactionBubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(cursorBubbleCenter(for: navigationBubbleSize, horizontalGap: 10, verticalGap: 18))
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Picky mascot cursor — shown for ALL voice states. Listening and
            // processing no longer swap in a separate waveform/spinner: the
            // icon itself shifts mood color (idle blue / listening cyan /
            // processing amber / responding purple) and expression animation.
            // Idle micro-behaviors stack as offset/rotation/scale on top of the
            // cursor-tracking spring without disturbing it.
            //
            // During cursor following: optional spring animation for smooth tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            if buddyIsVisibleOnThisScreen {
                cursorMascot
                    .shadow(
                        color: moodColor.opacity(companionManager.screenContextTargetSessionID == nil ? cursorStyleStore.style.outerShadowOpacity : 0),
                        radius: companionManager.screenContextTargetSessionID == nil ? CGFloat(cursorStyleStore.style.outerShadowRadius) + (buddyFlightScale - 1.0) * CGFloat(cursorStyleStore.style.outerShadowFlightMultiplier) : 0,
                        x: 0,
                        y: 0
                    )
                    .scaleEffect(buddyFlightScale)
                    .opacity(cursorOpacity)
                    .position(cursorPosition)
                    .animation(
                        buddyNavigationMode == .followingCursor ? cursorFollowAnimation : nil,
                        value: cursorPosition
                    )
                    .animation(.easeInOut(duration: 0.45), value: companionManager.voiceState)
            }

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = effectiveCursorGlobalPoint
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            self.cursorPosition = cursorBuddyPosition(for: mouseLocation)

            startTrackingCursor()
            startNavigatingToCurrentPointerTargetIfNeeded()

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            resetShakeDetection()
            shakeReactionUntil = 0
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { _, newLocation in
            startNavigatingToPointerTargetIfPresent(screenLocation: newLocation)
        }
        .onChange(of: companionManager.detectedElementPointerID) { _, pointerID in
            guard pointerID != nil else {
                cancelNavigationIfPointerCleared()
                return
            }
            startNavigatingToPointerTargetIfPresent(screenLocation: companionManager.detectedElementScreenLocation)
        }
    }

    private var effectiveCursorGlobalPoint: CGPoint {
        companionManager.inkOverlayState.virtualCursorGlobalPoint ?? NSEvent.mouseLocation
    }

    private func cursorBuddyPosition(for screenPoint: CGPoint) -> CGPoint {
        PickyOverlayGeometry.cursorBuddyPosition(for: screenPoint, in: screenFrame)
    }

    private var isShakeReactionActive: Bool {
        ProcessInfo.processInfo.systemUptime < shakeReactionUntil
    }

    private var isShakeDetectionEligible: Bool {
        cursorPreferencesStore.preferences.showPiCursor
            && companionManager.voiceState == .idle
            && buddyNavigationMode == .followingCursor
            && activePointerID == nil
            && isCursorOnThisScreen
            && !companionManager.isQuickInputPanelVisible
            && !companionManager.inkOverlayState.isActive
    }

    /// Whether the buddy pi icon should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When Quick Input
    /// is open, the text pill replaces the Pi cursor while the system cursor
    /// stays visible for normal pointer feedback. When another screen is
    /// navigating (detectedElementScreenLocation is set but this screen isn't
    /// the one animating), hide the cursor so only one buddy is ever visible.
    private var buddyIsVisibleOnThisScreen: Bool {
        guard cursorPreferencesStore.preferences.showPiCursor || companionManager.inkOverlayState.isActive || companionManager.screenContextTargetSessionID != nil else { return false }
        if companionManager.isQuickInputPanelVisible && !companionManager.inkOverlayState.isActive { return false }
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            // When the system pointer is hidden (full-screen video, games, the
            // idle-hide timer, text-input auto-hide), suppress the mascot too
            // so the buddy never draws on top of a surface the user explicitly
            // cleared. The anchored navigation/pointing modes intentionally
            // stay visible — they are not tethered to live cursor position.
            if !systemCursorVisible {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.cursorTrackingInterval, repeats: true) { _ in
            let mouseLocation = self.effectiveCursorGlobalPoint
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // Sync system cursor visibility into SwiftUI state. Reassigning
            // unconditionally would re-trigger body evaluation every frame,
            // so only commit when the value actually changes.
            let nowVisible = systemMouseCursorIsVisible()
            if nowVisible != self.systemCursorVisible {
                self.systemCursorVisible = nowVisible
            }

            // The buddy is never interrupted by mouse movement: fly-out runs to
            // completion, and fly-back uses a live-target spring chase that
            // already follows the cursor. So during any non-following mode we
            // simply yield position control to the navigation timer.
            if self.buddyNavigationMode != .followingCursor {
                self.resetShakeDetection()
                return
            }

            updateShakeDetection(mouseLocation: mouseLocation)
            cursorPosition = cursorBuddyPosition(for: mouseLocation)
        }
    }

    private func updateShakeDetection(mouseLocation: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isShakeDetectionEligible else {
            resetShakeDetection()
            return
        }

        guard let previousLocation = lastShakeSampleLocation else {
            lastShakeSampleLocation = mouseLocation
            lastShakeSampleAt = now
            return
        }

        defer {
            lastShakeSampleLocation = mouseLocation
            lastShakeSampleAt = now
        }

        let dt = max(now - lastShakeSampleAt, Self.cursorTrackingInterval)
        let dx = mouseLocation.x - previousLocation.x
        let dy = mouseLocation.y - previousLocation.y
        let dominantDelta = abs(dx) >= abs(dy) ? dx : dy
        let distance = hypot(dx, dy)
        let speed = distance / CGFloat(dt)
        let isActiveShakeSample = speed >= Self.shakeReactionMinimumSpeed && abs(dominantDelta) >= Self.shakeReactionMinimumDominantDelta

        guard isActiveShakeSample else {
            if let shakeWindowStartAt, now - max(lastShakeActiveAt, shakeWindowStartAt) > 0.25 {
                resetShakeDetection(keepingLastSample: true)
            }
            return
        }

        if shakeWindowStartAt == nil || now - lastShakeActiveAt > 0.25 {
            shakeWindowStartAt = now
            shakeDirectionChanges = 0
            lastShakeDirection = 0
            lastShakeDirectionChangeAt = 0
        }

        let direction = dominantDelta > 0 ? 1 : -1
        if lastShakeDirection != 0,
           direction != lastShakeDirection,
           now - lastShakeDirectionChangeAt > 0.08 {
            shakeDirectionChanges += 1
            lastShakeDirectionChangeAt = now
        }
        lastShakeDirection = direction
        lastShakeActiveAt = now

        if let shakeWindowStartAt,
           now - shakeWindowStartAt >= Self.shakeReactionRequiredDuration,
           shakeDirectionChanges >= Self.shakeReactionRequiredDirectionChanges,
           now >= shakeReactionUntil {
            triggerShakeReaction(now: now)
        }
    }

    private func triggerShakeReaction(now: TimeInterval) {
        shakeReactionUntil = now + 1.35
        resetShakeDetection(keepingLastSample: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard ProcessInfo.processInfo.systemUptime >= self.shakeReactionUntil else { return }
            self.shakeReactionUntil = 0
        }
    }

    private func resetShakeDetection(keepingLastSample: Bool = false) {
        shakeWindowStartAt = nil
        lastShakeActiveAt = 0
        lastShakeDirection = 0
        lastShakeDirectionChangeAt = 0
        shakeDirectionChanges = 0
        if !keepingLastSample {
            lastShakeSampleLocation = nil
            lastShakeSampleAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// Picks a bubble center position around the cursor that stays inside the
    /// current screen, falling back through bottom-right → bottom-left →
    /// top-right → top-left before clamping. Returns the bubble's center so
    /// it can plug straight into `.position(_:)`.
    private func cursorBubbleCenter(
        for bubbleSize: CGSize,
        horizontalGap: CGFloat = 12,
        verticalGap: CGFloat = 20
    ) -> CGPoint {
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: cursorPosition,
            bubbleSize: bubbleSize,
            screenSize: CGSize(width: screenFrame.width, height: screenFrame.height),
            horizontalGap: horizontalGap,
            verticalGap: verticalGap
        )
        return CGPoint(
            x: placement.topLeading.x + bubbleSize.width / 2,
            y: placement.topLeading.y + bubbleSize.height / 2
        )
    }

    private var pointerTargetPosition: CGPoint? {
        guard let screenLocation = companionManager.detectedElementScreenLocation else { return nil }
        guard PickyOverlayGeometry.targetBelongsToScreen(
            screenLocation: screenLocation,
            displayFrame: companionManager.detectedElementDisplayFrame,
            screenFrame: screenFrame
        ) else { return nil }

        let localPoint = PickyOverlayGeometry.swiftUICoordinates(for: screenLocation, in: screenFrame)
        return PickyOverlayGeometry.clamped(localPoint, to: CGSize(width: screenFrame.width, height: screenFrame.height))
    }

    /// SwiftUI-space size of the highlighted element's bounding box. When the
    /// detection only carries a point, falls back to a default size so the
    /// highlight ring still draws cleanly.
    private var pointerTargetSizeInThisScreen: CGSize {
        if let frame = companionManager.detectedElementTargetFrame, frame.width > 0, frame.height > 0 {
            return CGSize(width: frame.width, height: frame.height)
        }
        return CGSize(width: 28, height: 28)
    }

    // MARK: - Element Navigation

    private func startNavigatingToCurrentPointerTargetIfNeeded() {
        guard buddyNavigationMode == .followingCursor,
              let screenLocation = companionManager.detectedElementScreenLocation,
              PickyOverlayGeometry.targetBelongsToScreen(
                  screenLocation: screenLocation,
                  displayFrame: companionManager.detectedElementDisplayFrame,
                  screenFrame: screenFrame
              ) else {
            return
        }

        guard let pointerID = companionManager.detectedElementPointerID else { return }
        startNavigatingToElement(screenLocation: screenLocation, pointerID: pointerID)
    }

    private func pointerIsStillActive(_ pointerID: String) -> Bool {
        activePointerID == pointerID && companionManager.detectedElementPointerID == pointerID
    }

    private func startNavigatingToPointerTargetIfPresent(screenLocation newLocation: CGPoint?) {
        guard let screenLocation = newLocation,
              let displayFrame = companionManager.detectedElementDisplayFrame,
              let pointerID = companionManager.detectedElementPointerID else {
            cancelNavigationIfPointerCleared()
            return
        }

        // Only navigate if the target is on THIS screen. Use the resolved
        // point as the primary signal because adjacent displays can have
        // negative/non-zero origins and whole-screen frames may differ by a
        // fraction across ScreenCaptureKit/AppKit boundaries.
        guard PickyOverlayGeometry.targetBelongsToScreen(
            screenLocation: screenLocation,
            displayFrame: displayFrame,
            screenFrame: screenFrame
        ) else {
            return
        }

        startNavigatingToElement(screenLocation: screenLocation, pointerID: pointerID)
    }

    private func cancelNavigationIfPointerCleared(stalePointerID: String? = nil) {
        if let stalePointerID,
           let currentPointerID = companionManager.detectedElementPointerID,
           currentPointerID != stalePointerID {
            return
        }
        guard activePointerID != nil || buddyNavigationMode != .followingCursor else { return }
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        activePointerID = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
    }

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint, pointerID: String) {
        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = PickyOverlayGeometry.swiftUICoordinates(for: screenLocation, in: screenFrame)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Enter navigation mode — stop cursor following.
        activePointerID = pointerID
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget, pointerID: pointerID) {
            guard self.buddyNavigationMode == .navigatingToTarget,
                  self.pointerIsStillActive(pointerID) else { return }
            self.startPointingAtElement(pointerID: pointerID)
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The pi icon scales up at the midpoint for
    /// a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        pointerID: String,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.35s–1.4s so very short
        // hops don't drag visibly with the eased curve.
        let flightDurationSeconds = min(max(distance / 800.0, 0.35), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            guard self.pointerIsStillActive(pointerID) else {
                self.cancelNavigationIfPointerCleared(stalePointerID: pointerID)
                return
            }
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // easeInOutCubic — stronger ease than smoothstep so the start/end
            // accelerate/decelerate more visibly while the middle still moves quickly.
            let t: Double = linearProgress < 0.5
                ? 4.0 * linearProgress * linearProgress * linearProgress
                : 1.0 - pow(-2.0 * linearProgress + 2.0, 3.0) / 2.0

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement(pointerID: String) {
        guard pointerIsStillActive(pointerID) else { return }
        buddyNavigationMode = .pointingAtTarget

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager when available.
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0, pointerID: pointerID) {
            // All characters streamed — hold for the request duration, then fly back.
            let holdDuration = self.companionManager.detectedElementDisplayDuration ?? PickyPointerOverlayResolver.defaultDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
                guard self.buddyNavigationMode == .pointingAtTarget,
                      self.pointerIsStillActive(pointerID) else {
                    self.cancelNavigationIfPointerCleared(stalePointerID: pointerID)
                    return
                }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget,
                          self.pointerIsStillActive(pointerID) else {
                        self.cancelNavigationIfPointerCleared(stalePointerID: pointerID)
                        return
                    }
                    self.startFlyingBackToCursor(pointerID: pointerID)
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        pointerID: String,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget,
              pointerIsStillActive(pointerID) else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            guard self.pointerIsStillActive(pointerID) else {
                self.cancelNavigationIfPointerCleared(stalePointerID: pointerID)
                return
            }
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                pointerID: pointerID,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the cursor after pointing is done. Uses a
    /// damped spring that chases the LIVE mouse position each frame, so the
    /// landing stays in sync even if the user moves the cursor mid-flight.
    private func startFlyingBackToCursor(pointerID: String) {
        guard pointerIsStillActive(pointerID) else { return }
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateSpringChaseToLiveCursor(pointerID: pointerID) {
            self.finishNavigationAndResumeFollowing(pointerID: pointerID)
        }
    }

    /// Damped-spring chase toward the buddy's normal position relative to the
    /// live macOS mouse cursor. Used for fly-back so the landing point keeps
    /// up with cursor movement and the deceleration feels natural instead of
    /// snapping at the end of a static bezier arc.
    private func animateSpringChaseToLiveCursor(pointerID: String, onComplete: @escaping () -> Void) {
        navigationAnimationTimer?.invalidate()

        let frameInterval: Double = 1.0 / 60.0
        // Slightly underdamped (zeta ≈ 0.85) so the buddy lands quickly without
        // visible overshoot. Tuned by perceived feel rather than exact units.
        let stiffness: CGFloat = 220
        let damping: CGFloat = 25
        let mass: CGFloat = 1.0
        let convergenceEpsilon: CGFloat = 0.5
        let maxDurationSeconds: TimeInterval = 1.5

        var elapsed: TimeInterval = 0
        var velocity = CGPoint.zero

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            guard self.pointerIsStillActive(pointerID) else {
                self.cancelNavigationIfPointerCleared(stalePointerID: pointerID)
                return
            }
            elapsed += frameInterval

            let mouseLocation = self.effectiveCursorGlobalPoint
            let target = self.cursorBuddyPosition(for: mouseLocation)

            let dx = target.x - self.cursorPosition.x
            let dy = target.y - self.cursorPosition.y
            let ax = (stiffness * dx - damping * velocity.x) / mass
            let ay = (stiffness * dy - damping * velocity.y) / mass
            velocity.x += ax * CGFloat(frameInterval)
            velocity.y += ay * CGFloat(frameInterval)

            self.cursorPosition = CGPoint(
                x: self.cursorPosition.x + velocity.x * CGFloat(frameInterval),
                y: self.cursorPosition.y + velocity.y * CGFloat(frameInterval)
            )

            // Gently relax flight scale toward 1.0 in case fly-out left it elevated.
            self.buddyFlightScale = self.buddyFlightScale + (1.0 - self.buddyFlightScale) * 0.18

            let displacement = hypot(dx, dy)
            let speed = hypot(velocity.x, velocity.y)
            let converged = displacement < convergenceEpsilon && speed < convergenceEpsilon
            if converged || elapsed >= maxDurationSeconds {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = target
                self.buddyFlightScale = 1.0
                onComplete()
            }
        }
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing(pointerID: String) {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        activePointerID = nil
        companionManager.clearDetectedElementLocation(pointerID: pointerID)
    }

    // MARK: - Mood Colors

    /// Color the Picky mascot takes for the current voice state. Replaces the
    /// previous waveform/spinner overlays — the icon itself shifts color
    /// instead of swapping in a different shape.
    private var moodColor: Color {
        let style = cursorStyleStore.style
        switch companionManager.voiceState {
        case .idle:       return style.cursorColor
        case .listening:  return style.listeningColor
        case .processing: return style.processingColor
        case .responding: return style.respondingColor
        }
    }



}


// MARK: - Voice Prompt Bubble

private enum PickyShakeReactionText {
    static var current: String {
        // Use Picky's effective language (set via Settings → General) so the
        // exclamation matches whatever language the user is reading the rest
        // of the chrome in. Falls back to the OS preference snapshot when
        // the manager hasn't been touched yet.
        let identifier = LocaleManager.nonisolatedEffectiveLocale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let languageCode = identifier.split(separator: "-").first.map(String.init) ?? "en"

        switch languageCode {
        case "ko": return "꺄악"
        case "ja": return "きゃっ"
        case "zh": return "啊！"
        case "es": return "¡Ay!"
        case "fr": return "Ah !"
        case "de", "it": return "Ah!"
        case "pt": return "Ai!"
        case "vi": return "Á!"
        case "th": return "ว้าย!"
        default: return "Eek!"
        }
    }
}

private struct PickyShakeReactionBubbleView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 4)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.48), radius: 8, x: 0, y: 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.38), lineWidth: 0.8)
            )
            .fixedSize()
    }
}

private struct VoicePromptCursorBubbleView: View {
    let text: String
    let textWidth: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color.black.opacity(0.9))
            .multilineTextAlignment(.leading)
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(4)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.warning)
                    .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 3)
                    .shadow(color: DS.Colors.warning.opacity(0.5), radius: 8, x: 0, y: 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.22), lineWidth: 0.8)
            )
    }
}

// MARK: - Pointer Target Highlight

/// Pi-cursor-blue highlight overlay used when Picky points at something on
/// screen. Renders three concentric pulsing rings around the target and a
/// status tag with a tail; for in-screen targets it also dims the surrounding
/// area so the focus is unmistakable. Picky's own HUD chrome (e.g. the side
/// agent dock) opts out of the dim layer.
private struct PickyHighlightOverlayView: View {
    let kind: PickyDetectedHighlightKind
    let targetCenter: CGPoint
    let targetSize: CGSize
    let bubbleText: String?
    let screenSize: CGSize

    @State private var pulsePhase: Double = 0
    @State private var measuredTagSize: CGSize = CGSize(width: 132, height: 22)

    private var ringInnerRadius: CGFloat {
        max(max(targetSize.width, targetSize.height) / 2 + 4, 14)
    }

    private var ringMidRadius: CGFloat { ringInnerRadius + 6 }
    private var ringOuterRadius: CGFloat { ringInnerRadius + 13 }

    private var tagPlacement: PickyHighlightTagPlacement {
        PickyHighlightTagPlacement.compute(
            targetCenter: targetCenter,
            ringOuterRadius: ringOuterRadius,
            tagSize: measuredTagSize,
            screenSize: screenSize
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if kind == .screenElement {
                Canvas { context, size in
                    var path = Path()
                    path.addRect(CGRect(origin: .zero, size: size))
                    let r = ringInnerRadius
                    let hole = CGRect(
                        x: targetCenter.x - r,
                        y: targetCenter.y - r,
                        width: r * 2,
                        height: r * 2
                    )
                    path.addEllipse(in: hole)
                    context.fill(
                        path,
                        with: .color(Color(red: 10.0 / 255.0, green: 26.0 / 255.0, blue: 56.0 / 255.0).opacity(0.30)),
                        style: FillStyle(eoFill: true)
                    )
                }
                .frame(width: screenSize.width, height: screenSize.height)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            Circle()
                .stroke(DS.Colors.overlayCursorBlue.opacity(0.25), lineWidth: 0.6)
                .frame(width: ringOuterRadius * 2, height: ringOuterRadius * 2)
                .scaleEffect(0.95 + 0.18 * pulsePhase)
                .opacity(1.0 - 0.55 * pulsePhase)
                .position(targetCenter)

            Circle()
                .stroke(DS.Colors.overlayCursorBlue.opacity(0.55), lineWidth: 1.0)
                .frame(width: ringMidRadius * 2, height: ringMidRadius * 2)
                .scaleEffect(0.97 + 0.10 * pulsePhase)
                .opacity(1.0 - 0.30 * pulsePhase)
                .position(targetCenter)

            Circle()
                .stroke(DS.Colors.overlayCursorBlue, lineWidth: 1.6)
                .frame(width: ringInnerRadius * 2, height: ringInnerRadius * 2)
                .position(targetCenter)

            if let bubbleText, !bubbleText.isEmpty {
                PickyHighlightTagView(text: bubbleText, tailEdge: tagPlacement.tailEdge)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: PickyHighlightTagSizeKey.self, value: proxy.size)
                        }
                    )
                    .offset(x: tagPlacement.topLeading.x, y: tagPlacement.topLeading.y)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulsePhase = 1.0
            }
        }
        .onPreferenceChange(PickyHighlightTagSizeKey.self) { newSize in
            if newSize.width > 0, newSize.height > 0 {
                measuredTagSize = newSize
            }
        }
    }
}

private struct PickyHighlightTagSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct PickyHighlightTagView: View {
    let text: String
    let tailEdge: PickyHighlightTagPlacement.TailEdge

    private static let fillColor = Color(red: 230.0 / 255.0, green: 239.0 / 255.0, blue: 255.0 / 255.0)
    private static let textColor = Color(red: 14.0 / 255.0, green: 61.0 / 255.0, blue: 143.0 / 255.0)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Self.textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            PickyHighlightTagShape(tailEdge: tailEdge)
                .fill(Self.fillColor)
        )
        .overlay(
            PickyHighlightTagShape(tailEdge: tailEdge)
                .stroke(DS.Colors.overlayCursorBlue, lineWidth: 0.6)
        )
        .fixedSize()
    }
}

private struct PickyHighlightTagShape: Shape {
    let tailEdge: PickyHighlightTagPlacement.TailEdge
    var cornerRadius: CGFloat = 7
    var tailLength: CGFloat = 5
    var tailHalfBase: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius

        switch tailEdge {
        case .left:
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + tailHalfBase))
            path.addLine(to: CGPoint(x: rect.minX - tailLength, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY - tailHalfBase))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        case .right:
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - tailHalfBase))
            path.addLine(to: CGPoint(x: rect.maxX + tailLength, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + tailHalfBase))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        case .top:
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX - tailHalfBase, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY - tailLength))
            path.addLine(to: CGPoint(x: rect.midX + tailHalfBase, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX + tailHalfBase, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + tailLength))
            path.addLine(to: CGPoint(x: rect.midX - tailHalfBase, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}


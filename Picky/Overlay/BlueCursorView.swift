//
//  BlueCursorView.swift
//  Picky
//
//  SwiftUI cursor buddy rendering and navigation animation.
//

import AppKit
import Combine
import SwiftUI

// Runtime-tweakable style values for the Pi-shaped cursor buddy icon.
private struct PickyCursorStyle: Codable, Equatable {
    var colorHex = "#3380FF"
    var listeningColorHex = "#22C2C7"
    var processingColorHex = "#F0B440"
    var respondingColorHex = "#9F77E8"
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
    var outerShadowRadius = 8.0
    var outerShadowFlightMultiplier = 90.0

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

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                PickyCursorMascotGlyph(
                    expression: expression(at: time),
                    tint: tint.opacity(style.glowOpacity),
                    mouthApexOffset: mouthApexOffset(at: time)
                )
                .frame(width: CGFloat(style.glowSize), height: CGFloat(style.glowSize))
                .blur(radius: CGFloat(style.glowBlur))
                .scaleEffect(CGFloat(style.glowScale) * internalScale(at: time))

                PickyCursorMascotGlyph(
                    expression: expression(at: time),
                    tint: tint,
                    mouthApexOffset: mouthApexOffset(at: time)
                )
                .frame(width: CGFloat(style.mascotSize), height: CGFloat(style.mascotSize))
                .scaleEffect(internalScale(at: time))
                .rotationEffect(.degrees(internalRotation(at: time)))

                PickyCursorMascotGlyph(
                    expression: expression(at: time),
                    tint: .white.opacity(style.highlightOpacity),
                    mouthApexOffset: mouthApexOffset(at: time)
                )
                .frame(width: CGFloat(style.mascotSize), height: CGFloat(style.mascotSize))
                .scaleEffect(internalScale(at: time))
                .rotationEffect(.degrees(internalRotation(at: time)))
                .offset(x: CGFloat(style.highlightOffsetX), y: CGFloat(style.highlightOffsetY))
            }
            .frame(width: CGFloat(style.frameSize), height: CGFloat(style.frameSize))
        }
    }

    private func expression(at time: TimeInterval) -> PickyCursorMascotExpression {
        switch voiceState {
        case .idle:
            return time.truncatingRemainder(dividingBy: 5.2) > 4.94 ? .blink : .normal
        case .listening:
            return time.truncatingRemainder(dividingBy: 1.4) < 0.7 ? .happy : .normal
        case .processing:
            return time.truncatingRemainder(dividingBy: 1.1) < 0.32 ? .wink : .normal
        case .responding:
            return time.truncatingRemainder(dividingBy: 2.0) < 1.35 ? .happy : .normal
        }
    }

    private func mouthApexOffset(at time: TimeInterval) -> CGPoint {
        switch voiceState {
        case .idle:
            return .zero
        case .listening:
            return CGPoint(x: 0, y: CGFloat(-18 + sin(time * 5.0) * 3.0))
        case .processing:
            return CGPoint(x: CGFloat(sin(time * 6.0) * 5.0), y: -6)
        case .responding:
            return CGPoint(x: 0, y: CGFloat(-12 + sin(time * 4.2) * 4.0))
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
}

private struct PickyCursorMascotGlyph: View {
    let expression: PickyCursorMascotExpression
    let tint: Color
    let mouthApexOffset: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let scale = side / 512.0
            let origin = CGPoint(
                x: (geometry.size.width - side) / 2.0,
                y: (geometry.size.height - side) / 2.0
            )
            ZStack {
                mouthPath(origin: origin, scale: scale)
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: 80 * scale,
                            lineCap: .round,
                            lineJoin: .round,
                            miterLimit: 10
                        )
                    )

                eyes(origin: origin, scale: scale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func eyes(origin: CGPoint, scale: CGFloat) -> some View {
        switch expression {
        case .normal:
            normalEyes(origin: origin, scale: scale)
                .fill(tint)
        case .blink, .happy:
            happyEyes(origin: origin, scale: scale)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 40 * scale, lineCap: .round, lineJoin: .round, miterLimit: 10)
                )
        case .wink:
            Path(ellipseIn: ellipseRect(cx: 193.23, cy: 137.86, rx: 40, ry: 50, origin: origin, scale: scale))
                .fill(tint)
            winkEye(origin: origin, scale: scale)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 40 * scale, lineCap: .round, lineJoin: .round, miterLimit: 10)
                )
        }
    }

    private func mouthPath(origin: CGPoint, scale: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(102.5, 245.67, origin: origin, scale: scale))
        path.addLine(to: point(193.23 + mouthApexOffset.x, 367.37 + mouthApexOffset.y, origin: origin, scale: scale))
        path.addLine(to: point(425.04, 214.01, origin: origin, scale: scale))
        return path
    }

    private func normalEyes(origin: CGPoint, scale: CGFloat) -> Path {
        var path = Path()
        path.addPath(Path(ellipseIn: ellipseRect(cx: 193.23, cy: 137.86, rx: 40, ry: 50, origin: origin, scale: scale)))
        path.addPath(Path(ellipseIn: ellipseRect(cx: 308.32, cy: 137.86, rx: 40, ry: 50, origin: origin, scale: scale)))
        return path
    }

    private func happyEyes(origin: CGPoint, scale: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(213.06, 157.02, origin: origin, scale: scale))
        path.addCurve(
            to: point(153.40, 154.95, origin: origin, scale: scale),
            control1: point(198.32, 171.79, origin: origin, scale: scale),
            control2: point(170.26, 172.67, origin: origin, scale: scale)
        )
        path.move(to: point(272.13, 157.02, origin: origin, scale: scale))
        path.addCurve(
            to: point(331.79, 154.95, origin: origin, scale: scale),
            control1: point(286.87, 171.79, origin: origin, scale: scale),
            control2: point(314.93, 172.67, origin: origin, scale: scale)
        )
        return path
    }

    private func winkEye(origin: CGPoint, scale: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(286.16, 161.03, origin: origin, scale: scale))
        path.addCurve(
            to: point(342.77, 128.01, origin: origin, scale: scale),
            control1: point(297.11, 139.45, origin: origin, scale: scale),
            control2: point(322.97, 127.26, origin: origin, scale: scale)
        )
        return path
    }

    private func ellipseRect(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + (cx - rx) * scale,
            y: origin.y + (cy - ry) * scale,
            width: rx * 2 * scale,
            height: ry * 2 * scale
        )
    }

    private func point(_ x: CGFloat, _ y: CGFloat, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
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

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        _cursorPosition = State(initialValue: PickyOverlayGeometry.cursorBuddyPosition(for: mouseLocation, in: screenFrame))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var responseBubbleSize: CGSize = .zero
    @State private var voicePromptBubbleSize: CGSize = .zero
    @State private var cursorOpacity: Double = 1.0

    // MARK: - Idle Micro-Behaviors

    /// Transient offset/rotation/scale stacked on top of cursor following so
    /// the buddy can do small idle animations (look around, yawn, bob, tilt)
    /// without disturbing the normal mouse-tracking spring.
    @State private var idleOffsetX: CGFloat = 0
    @State private var idleOffsetY: CGFloat = 0
    @State private var idleRotation: Double = 0
    @State private var idleScale: CGFloat = 1.0
    @State private var idleShadowMultiplier: CGFloat = 1.0
    @State private var idleScheduleTimer: Timer?
    @State private var idleBehaviorActive: Bool = false
    @State private var lastCursorMoveAt: Date = Date()
    /// Anchor mouse location for slow-motion detection. Compared cumulatively
    /// (not per-tick) so slow drag/scroll motion still trips the threshold —
    /// per-tick delta against `cursorPosition` would miss anything below
    /// ~62 px/sec because `cursorPosition` is resynced to mouse each tick.
    @State private var lastStillMouseLocation: CGPoint?

    // MARK: - Mouse Movement Reactions

    /// Short-lived transform driven by mouse stop events. Fast cursor movement
    /// is sampled without adding lag; only a sudden stop produces one tiny
    /// overshoot before settling back to the normal cursor-follow target.
    @State private var motionOffsetX: CGFloat = 0
    @State private var motionOffsetY: CGFloat = 0
    @State private var motionRotation: Double = 0
    @State private var motionScale: CGFloat = 1.0
    @State private var lastCursorSamplePosition: CGPoint?
    @State private var lastCursorSampleTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    @State private var lastFastCursorDirection: CGVector = .zero
    @State private var wasCursorMovingFast: Bool = false
    @State private var motionOvershootActive: Bool = false
    @State private var lastOvershootAt: TimeInterval = 0
    @State private var motionReactionGeneration: Int = 0

    private enum IdleBehavior: CaseIterable {
        case lookAround, yawn, bob, tilt, shiver, wiggle, pulseGlow, lazyOrbit, tetheredRoam, figureEight
    }

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

            // Voice prompt bubble — once the push-to-talk button is released,
            // keep the recognized user prompt visible while Picky is preparing
            // and waiting for the Picky response.
            if isCursorOnThisScreen,
               overlayBubblePreferencesStore.preferences.showUserSpeechRecognitionBubble,
               companionManager.voicePromptBubbleState.isVisible {
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
                    .animation(.spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.2), value: companionManager.voiceState)
                    .animation(.easeOut(duration: 0.16), value: companionManager.voicePromptBubbleState)
                    .onPreferenceChange(VoicePromptBubbleSizePreferenceKey.self) { newSize in
                        voicePromptBubbleSize = newSize
                    }
            }

            // Short voice response bubble — mirrors quick TTS replies next to the cursor
            // so simple checks do not require opening the long-running agent HUD.
            if isCursorOnThisScreen,
               overlayBubblePreferencesStore.preferences.showPickyResponseBubble,
               companionManager.voiceState == .responding,
               let responseText = companionManager.latestAgentSessionSummary,
               !responseText.isEmpty {
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
                    .animation(.spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.2), value: companionManager.voiceState)
                    .onPreferenceChange(ResponseBubbleSizePreferenceKey.self) { newSize in
                        responseBubbleSize = newSize
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
                    .animation(.spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0), value: cursorPosition)
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
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            PickyCursorMascotView(
                style: cursorStyleStore.style,
                tint: moodColor,
                voiceState: companionManager.voiceState
            )
                .shadow(
                    color: moodColor.opacity(cursorStyleStore.style.outerShadowOpacity),
                    radius: (CGFloat(cursorStyleStore.style.outerShadowRadius) + (buddyFlightScale - 1.0) * CGFloat(cursorStyleStore.style.outerShadowFlightMultiplier)) * idleShadowMultiplier,
                    x: 0,
                    y: 0
                )
                .scaleEffect(buddyFlightScale * idleScale * motionScale)
                .rotationEffect(.degrees(idleRotation + motionRotation))
                .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
                .position(cursorPosition)
                .offset(x: idleOffsetX + motionOffsetX, y: idleOffsetY + motionOffsetY)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeInOut(duration: 0.45), value: companionManager.voiceState)

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
            scheduleNextIdleBehavior()

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            cancelIdleBehavior()
            resetMouseMovementReaction(animated: false)
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            startNavigatingToPointerTargetIfPresent(screenLocation: newLocation)
        }
        .onChange(of: companionManager.detectedElementPointerID) { pointerID in
            guard pointerID != nil else {
                cancelNavigationIfPointerCleared()
                return
            }
            startNavigatingToPointerTargetIfPresent(screenLocation: companionManager.detectedElementScreenLocation)
        }
        .onChange(of: companionManager.voiceState) { newState in
            if newState == .idle {
                scheduleNextIdleBehavior()
            } else {
                cancelIdleBehavior()
            }
        }
        .onChange(of: cursorPreferencesStore.preferences) { preferences in
            if !preferences.showPiCursor || !preferences.enableOvershootReaction {
                resetMouseMovementReaction(animated: true)
            }
            if preferences.showPiCursor && preferences.enableIdleAnimations {
                scheduleNextIdleBehavior()
            } else {
                cancelIdleBehavior()
            }
        }
    }

    private var effectiveCursorGlobalPoint: CGPoint {
        companionManager.inkOverlayState.virtualCursorGlobalPoint ?? NSEvent.mouseLocation
    }

    private func cursorBuddyPosition(for screenPoint: CGPoint) -> CGPoint {
        PickyOverlayGeometry.cursorBuddyPosition(for: screenPoint, in: screenFrame)
    }

    /// Whether the buddy pi icon should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When Quick Input
    /// is open, the text pill replaces the Pi cursor while the system cursor
    /// stays visible for normal pointer feedback. When another screen is
    /// navigating (detectedElementScreenLocation is set but this screen isn't
    /// the one animating), hide the cursor so only one buddy is ever visible.
    private var buddyIsVisibleOnThisScreen: Bool {
        guard cursorPreferencesStore.preferences.showPiCursor || companionManager.inkOverlayState.isActive else { return false }
        if companionManager.isQuickInputPanelVisible && !companionManager.inkOverlayState.isActive { return false }
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = self.effectiveCursorGlobalPoint
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // The buddy is never interrupted by mouse movement: fly-out runs to
            // completion, and fly-back uses a live-target spring chase that
            // already follows the cursor. So during any non-following mode we
            // simply yield position control to the navigation timer.
            if self.buddyNavigationMode != .followingCursor {
                self.resetMouseMovementReaction(animated: true)
                // Keep the still-anchor in sync during flight so the next
                // followingCursor tick doesn't see a fake jump as motion.
                self.lastStillMouseLocation = mouseLocation
                return
            }

            // Normal cursor following
            let newPosition = self.cursorBuddyPosition(for: mouseLocation)

            // Detect cursor motion against a fixed anchor (not per-tick) so
            // slow drag motion accumulates above the threshold. Comparing
            // per-tick against `cursorPosition` would miss anything below
            // ~62 px/sec because `cursorPosition` re-syncs to the mouse each
            // tick, hiding cumulative drift.
            let anchor = self.lastStillMouseLocation ?? mouseLocation
            let dx = mouseLocation.x - anchor.x
            let dy = mouseLocation.y - anchor.y
            if hypot(dx, dy) > 2.0 {
                self.lastCursorMoveAt = Date()
                self.lastStillMouseLocation = mouseLocation
                if self.idleBehaviorActive {
                    self.cancelIdleBehavior()
                    self.scheduleNextIdleBehavior()
                }
            } else if self.lastStillMouseLocation == nil {
                self.lastStillMouseLocation = mouseLocation
            }

            self.updateMouseMovementReaction(for: newPosition)
            self.cursorPosition = newPosition
        }
    }

    // MARK: - Mouse Movement Reactions

    private func updateMouseMovementReaction(for targetPosition: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime

        guard cursorPreferencesStore.preferences.showPiCursor,
              cursorPreferencesStore.preferences.enableOvershootReaction,
              isCursorOnThisScreen,
              !companionManager.isQuickInputPanelVisible,
              !companionManager.inkOverlayState.isActive,
              companionManager.voiceState == .idle else {
            resetMouseMovementReaction(animated: true)
            return
        }

        guard let previousPosition = lastCursorSamplePosition else {
            lastCursorSamplePosition = targetPosition
            lastCursorSampleTime = now
            return
        }

        defer {
            lastCursorSamplePosition = targetPosition
            lastCursorSampleTime = now
        }

        let sample = PickyCursorMotionReaction.sample(
            previousPosition: previousPosition,
            currentPosition: targetPosition,
            previousTime: lastCursorSampleTime,
            currentTime: now
        )

        if PickyCursorMotionReaction.isMeaningfulMovement(sample) {
            if motionOvershootActive {
                motionReactionGeneration += 1
                motionOvershootActive = false
                settleMouseMovementReaction(animated: true)
            }

            if PickyCursorMotionReaction.isFastMovement(sample) {
                wasCursorMovingFast = true
                lastFastCursorDirection = sample.direction
            }
        } else if PickyCursorMotionReaction.shouldTriggerStopOvershoot(
            sample: sample,
            wasCursorMovingFast: wasCursorMovingFast,
            overshootActive: motionOvershootActive,
            now: now,
            lastOvershootAt: lastOvershootAt
        ) {
            runCursorStopOvershoot(now: now)
        } else if sample.speed < PickyCursorMotionReaction.stoppedSpeed, !motionOvershootActive {
            settleMouseMovementReaction(animated: true)
            wasCursorMovingFast = false
        } else if !motionOvershootActive {
            settleMouseMovementReaction(animated: true)
        }
    }

    private func runCursorStopOvershoot(now: TimeInterval) {
        let direction = lastFastCursorDirection
        guard hypot(direction.dx, direction.dy) > 0.01 else {
            settleMouseMovementReaction(animated: true)
            wasCursorMovingFast = false
            return
        }

        lastOvershootAt = now
        wasCursorMovingFast = false
        motionOvershootActive = true
        motionReactionGeneration += 1
        let generation = motionReactionGeneration

        withAnimation(.interpolatingSpring(stiffness: 520, damping: 19)) {
            motionOffsetX = direction.dx * PickyCursorMotionReaction.overshootDistance
            motionOffsetY = direction.dy * PickyCursorMotionReaction.overshootDistance
            motionRotation = PickyCursorMotionReaction.overshootRotation(for: direction)
            motionScale = 1.035
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            guard self.motionReactionGeneration == generation,
                  self.motionOvershootActive else { return }
            self.settleMouseMovementReaction(animated: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                guard self.motionReactionGeneration == generation else { return }
                self.motionOvershootActive = false
            }
        }
    }

    private func settleMouseMovementReaction(animated: Bool) {
        let changes = {
            motionOffsetX = 0
            motionOffsetY = 0
            motionRotation = 0
            motionScale = 1.0
        }

        if animated {
            withAnimation(.interpolatingSpring(stiffness: 360, damping: 24)) {
                changes()
            }
        } else {
            changes()
        }
    }

    private func resetMouseMovementReaction(animated: Bool) {
        let hasReactionState = motionOffsetX != 0
            || motionOffsetY != 0
            || motionRotation != 0
            || motionScale != 1.0
            || motionOvershootActive
            || wasCursorMovingFast
            || lastCursorSamplePosition != nil
            || hypot(lastFastCursorDirection.dx, lastFastCursorDirection.dy) > 0.01
        guard hasReactionState else { return }

        motionReactionGeneration += 1
        motionOvershootActive = false
        wasCursorMovingFast = false
        lastFastCursorDirection = .zero
        lastCursorSamplePosition = nil
        settleMouseMovementReaction(animated: animated)
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
        scheduleNextIdleBehavior()
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
        cancelIdleBehavior()
        resetMouseMovementReaction(animated: true)

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
        resetMouseMovementReaction(animated: true)
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        activePointerID = nil
        companionManager.clearDetectedElementLocation(pointerID: pointerID)
        scheduleNextIdleBehavior()
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

    // MARK: - Idle Micro-Behaviors

    /// Whether the buddy is in a state where idle micro-behaviors may run.
    /// Used both to gate scheduling and to short-circuit a behavior mid-step.
    private var isIdleEligibleForScheduling: Bool {
        cursorPreferencesStore.preferences.showPiCursor
            && cursorPreferencesStore.preferences.enableIdleAnimations
            && companionManager.voiceState == .idle
            && buddyNavigationMode == .followingCursor
            && activePointerID == nil
            && !companionManager.isQuickInputPanelVisible
            && isCursorOnThisScreen
    }

    /// Arm the next idle behavior fire. When eligibility currently fails (most
    /// commonly because the cursor isn't on this screen at startup), still arm
    /// a longer retry timer so this view can recover the moment the cursor
    /// returns. Without this retry, a BlueCursorView whose `.onAppear` fired
    /// before the cursor reached its screen would stay silent forever — until
    /// the user toggled a cursor preference to force a re-schedule.
    private func scheduleNextIdleBehavior(delayRange: ClosedRange<Double> = 4...10) {
        idleScheduleTimer?.invalidate()
        let effectiveRange = isIdleEligibleForScheduling ? delayRange : 12.0...24.0
        let delay = Double.random(in: effectiveRange)
        idleScheduleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            self.runRandomIdleBehaviorIfEligible()
        }
    }

    private func cancelIdleBehavior() {
        idleScheduleTimer?.invalidate()
        idleScheduleTimer = nil
        idleBehaviorActive = false
        withAnimation(.easeOut(duration: 0.25)) {
            idleOffsetX = 0
            idleOffsetY = 0
            idleRotation = 0
            idleScale = 1.0
            idleShadowMultiplier = 1.0
        }
    }

    private func runRandomIdleBehaviorIfEligible() {
        guard isIdleEligibleForScheduling else {
            scheduleNextIdleBehavior(delayRange: 12...24)
            return
        }
        // Require the cursor to have been settled for 6 seconds so the
        // behavior doesn't kick in while the user is actively moving the mouse.
        if Date().timeIntervalSince(lastCursorMoveAt) < 6 {
            scheduleNextIdleBehavior(delayRange: 6...10)
            return
        }
        let behavior = IdleBehavior.allCases.randomElement() ?? .lookAround
        idleBehaviorActive = true
        switch behavior {
        case .lookAround:  runLookAroundBehavior()
        case .yawn:        runYawnBehavior()
        case .bob:         runBobBehavior()
        case .tilt:        runTiltBehavior()
        case .shiver:      runShiverBehavior()
        case .wiggle:      runWiggleBehavior()
        case .pulseGlow:   runPulseGlowBehavior()
        case .lazyOrbit:   runLazyOrbitBehavior()
        case .tetheredRoam: runTetheredRoamBehavior()
        case .figureEight: runFigureEightBehavior()
        }
    }

    private func finishIdleBehavior() {
        withAnimation(.easeOut(duration: 0.3)) {
            idleOffsetX = 0
            idleOffsetY = 0
            idleRotation = 0
            idleScale = 1.0
            idleShadowMultiplier = 1.0
        }
        idleBehaviorActive = false
        scheduleNextIdleBehavior()
    }

    private func runShiverBehavior() {
        let tickInterval: TimeInterval = 0.06
        let totalTicks = 6
        var tick = 0
        idleScheduleTimer?.invalidate()
        idleScheduleTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.idleScheduleTimer?.invalidate()
                self.finishIdleBehavior()
                return
            }
            tick += 1
            if tick >= totalTicks {
                self.idleScheduleTimer?.invalidate()
                self.finishIdleBehavior()
                return
            }
            let amp: CGFloat = tick % 2 == 0 ? 1.0 : -1.0
            withAnimation(.linear(duration: tickInterval)) {
                self.idleRotation = Double(amp * 2.5)
                self.idleScale = 1.0 + CGFloat(abs(amp)) * 0.04
            }
        }
    }

    private func runWiggleBehavior() {
        let steps: [Double] = [10, -10, 7, -7, 4, 0]
        var index = 0
        func nextStep() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard index < steps.count else {
                self.finishIdleBehavior()
                return
            }
            let rotation = steps[index]
            index += 1
            withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) {
                self.idleRotation = rotation
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                nextStep()
            }
        }
        nextStep()
    }

    private func runPulseGlowBehavior() {
        let phases: [CGFloat] = [1.0, 1.25, 1.0, 1.15, 1.0]
        var index = 0
        func nextPhase() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard index < phases.count else {
                self.finishIdleBehavior()
                return
            }
            withAnimation(.easeInOut(duration: 0.5)) {
                self.idleShadowMultiplier = phases[index]
            }
            index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                nextPhase()
            }
        }
        nextPhase()
    }

    private func runLazyOrbitBehavior() {
        let steps = 42
        let interval: TimeInterval = 0.12
        let radiusX = CGFloat.random(in: 8...14)
        let radiusY = CGFloat.random(in: 5...10)
        let direction = Bool.random() ? 1.0 : -1.0
        var step = 0
        func nextStep() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard step < steps else {
                self.finishIdleBehavior()
                return
            }
            let phase = Double(step) / Double(steps) * 2.0 * Double.pi * direction
            withAnimation(.easeInOut(duration: interval * 1.4)) {
                self.idleOffsetX = CGFloat(cos(phase)) * radiusX
                self.idleOffsetY = CGFloat(sin(phase)) * radiusY
                self.idleRotation = sin(phase) * 5.0
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                nextStep()
            }
        }
        nextStep()
    }

    private func runTetheredRoamBehavior() {
        let points = (0..<4).map { _ in
            CGPoint(
                x: CGFloat.random(in: -18...18),
                y: CGFloat.random(in: -14...14)
            )
        } + [.zero]
        var index = 0
        func nextPoint() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard index < points.count else {
                self.finishIdleBehavior()
                return
            }
            let point = points[index]
            let rotation = max(-6, min(6, Double(point.x) * 0.35))
            index += 1
            withAnimation(.easeInOut(duration: 0.85)) {
                self.idleOffsetX = point.x
                self.idleOffsetY = point.y
                self.idleRotation = rotation
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                nextPoint()
            }
        }
        nextPoint()
    }

    private func runFigureEightBehavior() {
        let steps = 50
        let interval: TimeInterval = 0.1
        let radiusX = CGFloat.random(in: 10...16)
        let radiusY = CGFloat.random(in: 4...8)
        var step = 0
        func nextStep() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard step <= steps else {
                self.finishIdleBehavior()
                return
            }
            let phase = Double(step) / Double(steps) * 2.0 * Double.pi
            withAnimation(.easeInOut(duration: interval * 1.5)) {
                self.idleOffsetX = CGFloat(sin(phase)) * radiusX
                self.idleOffsetY = CGFloat(sin(phase * 2.0)) * radiusY
                self.idleRotation = cos(phase) * 4.0
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                nextStep()
            }
        }
        nextStep()
    }

    private func runLookAroundBehavior() {
        let steps: [Double] = [-12, 12, -8, 0]
        var index = 0
        func nextStep() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard index < steps.count else {
                self.finishIdleBehavior()
                return
            }
            let rotation = steps[index]
            index += 1
            withAnimation(.easeInOut(duration: 0.4)) {
                self.idleRotation = rotation
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                nextStep()
            }
        }
        nextStep()
    }

    private func runYawnBehavior() {
        guard idleBehaviorActive, isIdleEligibleForScheduling else {
            finishIdleBehavior()
            return
        }
        withAnimation(.easeInOut(duration: 0.45)) {
            idleScale = 1.4
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            withAnimation(.easeOut(duration: 0.35)) {
                self.idleScale = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.finishIdleBehavior()
            }
        }
    }

    private func runBobBehavior() {
        let bobSteps = 5  // up, down, up, down, settle
        var step = 0
        func nextStep() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            if step >= bobSteps {
                self.finishIdleBehavior()
                return
            }
            let dy: CGFloat = step == bobSteps - 1 ? 0 : (step % 2 == 0 ? -6 : 6)
            withAnimation(.easeInOut(duration: 0.45)) {
                self.idleOffsetY = dy
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                nextStep()
            }
        }
        nextStep()
    }

    private func runTiltBehavior() {
        let steps: [Double] = [10, -8, 5, 0]
        var index = 0
        func nextStep() {
            guard self.idleBehaviorActive, self.isIdleEligibleForScheduling else {
                self.finishIdleBehavior()
                return
            }
            guard index < steps.count else {
                self.finishIdleBehavior()
                return
            }
            let rotation = steps[index]
            index += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                self.idleRotation = rotation
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                nextStep()
            }
        }
        nextStep()
    }

}


// MARK: - Voice Prompt Bubble

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


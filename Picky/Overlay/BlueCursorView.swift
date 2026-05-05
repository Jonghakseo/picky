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
    var frameSize = 30.0
    var glowOpacity = 0.3
    var glowBlur = 0.3
    var glowScale = 1.18
    var glowSize = 13.0
    var iconSize = 15.0
    var highlightOpacity = 0.12
    var highlightOffsetX = -0.4
    var highlightOffsetY = -0.4
    var outerShadowOpacity = 0.6
    var outerShadowRadius = 10.0
    var outerShadowFlightMultiplier = 90.0

    var cursorColor: Color { Color(hex: colorHex) }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = PickyCursorStyle()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? defaults.colorHex
        frameSize = try container.decodeIfPresent(Double.self, forKey: .frameSize) ?? defaults.frameSize
        glowOpacity = try container.decodeIfPresent(Double.self, forKey: .glowOpacity) ?? defaults.glowOpacity
        glowBlur = try container.decodeIfPresent(Double.self, forKey: .glowBlur) ?? defaults.glowBlur
        glowScale = try container.decodeIfPresent(Double.self, forKey: .glowScale) ?? defaults.glowScale
        glowSize = try container.decodeIfPresent(Double.self, forKey: .glowSize) ?? defaults.glowSize
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? defaults.iconSize
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

// Pi-shaped cursor buddy icon.
private struct PiCursorIconView: View {
    let style: PickyCursorStyle

    var body: some View {
        ZStack {
            Image("PiSymbol")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(style.cursorColor.opacity(style.glowOpacity))
                .frame(width: CGFloat(style.glowSize), height: CGFloat(style.glowSize))
                .blur(radius: CGFloat(style.glowBlur))
                .scaleEffect(CGFloat(style.glowScale))

            Image("PiSymbol")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(style.cursorColor)
                .frame(width: CGFloat(style.iconSize), height: CGFloat(style.iconSize))

            Image("PiSymbol")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(.white.opacity(style.highlightOpacity))
                .frame(width: CGFloat(style.iconSize), height: CGFloat(style.iconSize))
                .offset(x: CGFloat(style.highlightOffsetX), y: CGFloat(style.highlightOffsetY))
        }
        .frame(width: CGFloat(style.frameSize), height: CGFloat(style.frameSize))
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

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var responseBubbleSize: CGSize = .zero
    @State private var voicePromptBubbleSize: CGSize = .zero
    @State private var cursorOpacity: Double = 1.0

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
            // and waiting for the main agent response.
            if isCursorOnThisScreen,
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
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 8, x: 0, y: 0)
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

            // Blue pi cursor — shown when idle or while TTS is playing (responding).
            // All three states (pi icon, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            PiCursorIconView(style: cursorStyleStore.style)
                .shadow(
                    color: cursorStyleStore.style.cursorColor.opacity(cursorStyleStore.style.outerShadowOpacity),
                    radius: CGFloat(cursorStyleStore.style.outerShadowRadius) + (buddyFlightScale - 1.0) * CGFloat(cursorStyleStore.style.outerShadowFlightMultiplier),
                    x: 0,
                    y: 0
                )
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (companionManager.voiceState == .idle || companionManager.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)

            // Blue waveform — replaces the pi icon while listening
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while local capture/submission is processing
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.3, dampingFraction: 0.65, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()
            startNavigatingToCurrentPointerTargetIfNeeded()

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
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
    }

    /// Whether the buddy pi icon should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
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
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // The buddy is never interrupted by mouse movement: fly-out runs to
            // completion, and fly-back uses a live-target spring chase that
            // already follows the cursor. So during any non-following mode we
            // simply yield position control to the navigation timer.
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
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
        guard pointerTargetBelongsToThisScreen(
            screenLocation: screenLocation,
            displayFrame: companionManager.detectedElementDisplayFrame
        ) else { return nil }

        let localPoint = convertScreenPointToSwiftUICoordinates(screenLocation)
        return CGPoint(
            x: max(0, min(localPoint.x, screenFrame.width)),
            y: max(0, min(localPoint.y, screenFrame.height))
        )
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

    private func pointerTargetBelongsToThisScreen(screenLocation: CGPoint, displayFrame: CGRect?) -> Bool {
        let expandedScreenFrame = screenFrame.insetBy(dx: -1, dy: -1)
        if expandedScreenFrame.contains(screenLocation) { return true }

        guard let displayFrame else { return false }
        let displayCenter = CGPoint(x: displayFrame.midX, y: displayFrame.midY)
        let screenCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        return expandedScreenFrame.contains(displayCenter)
            || displayFrame.insetBy(dx: -1, dy: -1).contains(screenCenter)
    }

    // MARK: - Element Navigation

    private func startNavigatingToCurrentPointerTargetIfNeeded() {
        guard buddyNavigationMode == .followingCursor,
              let screenLocation = companionManager.detectedElementScreenLocation,
              pointerTargetBelongsToThisScreen(
                  screenLocation: screenLocation,
                  displayFrame: companionManager.detectedElementDisplayFrame
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
        guard pointerTargetBelongsToThisScreen(screenLocation: screenLocation, displayFrame: displayFrame) else {
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
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

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

            let mouseLocation = NSEvent.mouseLocation
            let mouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let target = CGPoint(x: mouseInSwiftUI.x + 35, y: mouseInSwiftUI.y + 25)

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

}


// MARK: - Cursor Bubble Placement

/// Picks a placement for a cursor-anchored bubble that stays within the host
/// screen. The function tries the four corners around the cursor in priority
/// order (bottom-right → bottom-left → top-right → top-left) and falls back
/// to clamping when no candidate fits. Pure logic so it can be unit tested.
struct PickyCursorBubblePlacement: Equatable {
    enum Side: Equatable { case bottomRight, bottomLeft, topRight, topLeft }
    let topLeading: CGPoint
    let side: Side

    static func compute(
        cursorPosition: CGPoint,
        bubbleSize: CGSize,
        screenSize: CGSize,
        horizontalGap: CGFloat = 12,
        verticalGap: CGFloat = 20,
        edgePadding: CGFloat = 8
    ) -> PickyCursorBubblePlacement {
        let candidates: [(Side, CGPoint)] = [
            (.bottomRight, CGPoint(x: cursorPosition.x + horizontalGap, y: cursorPosition.y + verticalGap)),
            (.bottomLeft, CGPoint(x: cursorPosition.x - horizontalGap - bubbleSize.width, y: cursorPosition.y + verticalGap)),
            (.topRight, CGPoint(x: cursorPosition.x + horizontalGap, y: cursorPosition.y - verticalGap - bubbleSize.height)),
            (.topLeft, CGPoint(x: cursorPosition.x - horizontalGap - bubbleSize.width, y: cursorPosition.y - verticalGap - bubbleSize.height)),
        ]

        for (side, origin) in candidates {
            let fitsHorizontally = origin.x >= edgePadding
                && origin.x + bubbleSize.width + edgePadding <= screenSize.width
            let fitsVertically = origin.y >= edgePadding
                && origin.y + bubbleSize.height + edgePadding <= screenSize.height
            if fitsHorizontally && fitsVertically {
                return PickyCursorBubblePlacement(topLeading: origin, side: side)
            }
        }

        let fallbackSide = candidates[0].0
        let fallbackOrigin = candidates[0].1
        let maxX = max(edgePadding, screenSize.width - bubbleSize.width - edgePadding)
        let maxY = max(edgePadding, screenSize.height - bubbleSize.height - edgePadding)
        let clampedX = min(max(fallbackOrigin.x, edgePadding), maxX)
        let clampedY = min(max(fallbackOrigin.y, edgePadding), maxY)
        return PickyCursorBubblePlacement(
            topLeading: CGPoint(x: clampedX, y: clampedY),
            side: fallbackSide
        )
    }
}

// MARK: - Voice Prompt Bubble

private struct VoicePromptCursorBubbleView: View {
    let text: String
    let textWidth: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color.black.opacity(0.82))
            .multilineTextAlignment(.leading)
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(4)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.warning)
                    .shadow(color: DS.Colors.warning.opacity(0.45), radius: 8, x: 0, y: 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
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

struct PickyHighlightTagPlacement: Equatable {
    enum TailEdge { case left, right, top, bottom }
    let topLeading: CGPoint
    let tailEdge: TailEdge

    static func compute(
        targetCenter: CGPoint,
        ringOuterRadius: CGFloat,
        tagSize: CGSize,
        screenSize: CGSize
    ) -> PickyHighlightTagPlacement {
        let gap: CGFloat = 12
        let edgePadding: CGFloat = 8
        let leftSpace = targetCenter.x - ringOuterRadius - gap
        let rightSpace = screenSize.width - targetCenter.x - ringOuterRadius - gap

        if rightSpace >= tagSize.width + edgePadding,
           rightSpace >= leftSpace {
            let originX = targetCenter.x + ringOuterRadius + gap
            let originY = targetCenter.y - tagSize.height / 2
            return PickyHighlightTagPlacement(
                topLeading: CGPoint(x: originX, y: clampY(originY, height: tagSize.height, screenSize: screenSize)),
                tailEdge: .left
            )
        }

        if leftSpace >= tagSize.width + edgePadding {
            let originX = targetCenter.x - ringOuterRadius - gap - tagSize.width
            let originY = targetCenter.y - tagSize.height / 2
            return PickyHighlightTagPlacement(
                topLeading: CGPoint(x: originX, y: clampY(originY, height: tagSize.height, screenSize: screenSize)),
                tailEdge: .right
            )
        }

        // Not enough horizontal space — anchor below or above the ring.
        let belowOrigin = CGPoint(
            x: clampX(targetCenter.x - tagSize.width / 2, width: tagSize.width, screenSize: screenSize),
            y: targetCenter.y + ringOuterRadius + gap
        )
        let belowFits = belowOrigin.y + tagSize.height + edgePadding <= screenSize.height
        if belowFits {
            return PickyHighlightTagPlacement(topLeading: belowOrigin, tailEdge: .top)
        }
        let aboveOrigin = CGPoint(
            x: clampX(targetCenter.x - tagSize.width / 2, width: tagSize.width, screenSize: screenSize),
            y: targetCenter.y - ringOuterRadius - gap - tagSize.height
        )
        return PickyHighlightTagPlacement(topLeading: aboveOrigin, tailEdge: .bottom)
    }

    private static func clampX(_ x: CGFloat, width: CGFloat, screenSize: CGSize) -> CGFloat {
        let minX: CGFloat = 8
        let maxX = max(minX, screenSize.width - width - 8)
        return min(max(x, minX), maxX)
    }

    private static func clampY(_ y: CGFloat, height: CGFloat, screenSize: CGSize) -> CGFloat {
        let minY: CGFloat = 8
        let maxY = max(minY, screenSize.height - height - 8)
        return min(max(y, minY), maxY)
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

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the pi cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the pi cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

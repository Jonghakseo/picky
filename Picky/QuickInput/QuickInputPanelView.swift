//
//  QuickInputPanelView.swift
//  Picky
//
//  Compact pill composer that floats next to the cursor when the user
//  double-taps Control. Single-line text field, send button, close button.
//  Layout matches the design reference: rounded capsule, leading text input,
//  trailing send (↑) glyph in a circle, and a dismissal × at the very right.
//

import Combine
import SwiftUI

enum QuickInputPanelLayout {
    static let pillWidth: CGFloat = 330
    static let capsuleHeight: CGFloat = 40
    static let historyPillSpacing: CGFloat = 6
    /// Component-level optical fades: shallow enough to leave the anchored
    /// prompt legible while still indicating additional scrollable content.
    static let historyTopFadeHeight: CGFloat = 18
    static let historyBottomFadeHeight: CGFloat = 24
    /// The card intentionally recedes into the desktop until the user scrolls.
    /// These component-level surface opacities preserve that hierarchy without
    /// changing transcript text contrast or the shared surface token.
    static let historyLightweightSurfaceTopOpacity: Double = 0.35
    static let historySolidSurfaceOpacity: Double = 0.96
    static let historyLightweightSurfaceBottomOpacity: Double = historySolidSurfaceOpacity
    static let historyLightweightBorderTopOpacity: Double = 0.18
    static let historyLightweightBorderBottomOpacity: Double = 0.55
    static let historyLightweightMainShadowOpacity: Double = 0.04
    static let historyLightweightTightShadowOpacity: Double = 0.02
    static let historyBackgroundTransitionDuration: Double = 0.15
    static let historyAnchorSettlingDuration: Double = 0.1
    static let mainShadowOpacity: Double = 0.08
    static let mainShadowRadius: CGFloat = 4
    static let mainShadowYOffset: CGFloat = 2
    static let tightShadowOpacity: Double = 0.04
    static let tightShadowRadius: CGFloat = 0.8
    static let tightShadowYOffset: CGFloat = 0.3
    static var shadowOutset: CGFloat {
        mainShadowRadius + abs(mainShadowYOffset)
    }
    static let panelWidth: CGFloat = pillWidth + shadowOutset * 2
    static let estimatedPanelHeight: CGFloat = capsuleHeight + shadowOutset * 2
}

@MainActor
final class QuickInputPanelViewModel: ObservableObject {
    @Published var draftText: String = ""
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published var recentMessages: [PickyMainAgentMessage] = []
    /// Increments after every panel presentation so a retained hosting view
    /// re-applies its transcript anchor when the panel becomes visible again.
    @Published private(set) var presentationID = 0
    /// Includes the card chrome and is reduced by the manager when the cursor
    /// has limited space above it on the active display.
    @Published var historyCardHeightLimit: CGFloat = QuickInputHistoryPolicy.defaultCardHeight

    var onSubmit: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Lets the AppKit panel remeasure after the transcript's SwiftUI content
    /// resolves its actual height.
    var onFittingSizeChanged: () -> Void = {}

    func submit() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        onSubmit(trimmed)
    }

    func close() {
        onClose()
    }

    func beginPresentation() {
        presentationID &+= 1
    }
}

struct QuickInputPanelView: View {
    @ObservedObject var viewModel: QuickInputPanelViewModel
    @FocusState private var isFieldFocused: Bool

    /// Capsule height — matches the reference pill shape.
    private let capsuleHeight: CGFloat = QuickInputPanelLayout.capsuleHeight
    private let pillWidth: CGFloat = QuickInputPanelLayout.pillWidth
    private let shadowOutset: CGFloat = QuickInputPanelLayout.shadowOutset

    var body: some View {
        VStack(alignment: .leading, spacing: QuickInputPanelLayout.historyPillSpacing) {
            if QuickInputHistoryPolicy.shouldDisplayCard(
                for: viewModel.recentMessages,
                cardHeightLimit: viewModel.historyCardHeightLimit
            ) {
                QuickInputHistoryCard(viewModel: viewModel)
            }

            HStack(spacing: 6) {
                TextField("Message Picky…", text: $viewModel.draftText, axis: .horizontal)
                    .textFieldStyle(.plain)
                    .font(PickyHUDTypography.bodyMedium)
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isFieldFocused)
                    .submitLabel(.send)
                    .onSubmit { viewModel.submit() }
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sendButton

                closeButton
                    .padding(.trailing, 8)
            }
            .frame(height: capsuleHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
                    )
                    .shadow(
                        color: Color.black.opacity(QuickInputPanelLayout.mainShadowOpacity),
                        radius: QuickInputPanelLayout.mainShadowRadius,
                        x: 0,
                        y: QuickInputPanelLayout.mainShadowYOffset
                    )
                    .shadow(
                        color: Color.black.opacity(QuickInputPanelLayout.tightShadowOpacity),
                        radius: QuickInputPanelLayout.tightShadowRadius,
                        x: 0,
                        y: QuickInputPanelLayout.tightShadowYOffset
                    )
            )

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: pillWidth, alignment: .leading)
        .padding(shadowOutset)
        .frame(width: QuickInputPanelLayout.panelWidth, alignment: .leading)
        .onAppear { isFieldFocused = true }
    }

    private var sendButton: some View {
        Button(action: { viewModel.submit() }) {
            Group {
                if viewModel.isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .pickyFont(size: 12, weight: .bold)
                }
            }
            .frame(width: 28, height: 28)
            .foregroundColor(isSendDisabled ? DS.Colors.textTertiary : Color.white)
            .background(
                Circle().fill(isSendDisabled ? DS.Colors.borderSubtle.opacity(0.7) : DS.Colors.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSendDisabled)
        .accessibilityLabel("Send")
        .accessibilityValue(viewModel.isSending ? "Sending" : "")
    }

    private var closeButton: some View {
        Button(action: { viewModel.close() }) {
            Image(systemName: "xmark")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Close")
    }

    private var isSendDisabled: Bool {
        viewModel.isSending
            || viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

private struct QuickInputHistoryCard: View {
    @ObservedObject var viewModel: QuickInputPanelViewModel
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @State private var trailingTurnHeight: CGFloat = 0
    @State private var backgroundMode: QuickInputHistoryBackgroundMode = .lightweight
    @State private var isApplyingAnchorScroll = true
    @State private var anchorScrollRequestID = 0
    /// Starts true so the initial scroll-to-last-turn presentation immediately
    /// shows the top fade when prior messages exist; the scroll offset
    /// preference clears it once the user reaches the transcript's actual top.
    @State private var hasContentAboveViewport = true
    @State private var hasContentBelowViewport = false

    private let scrollCoordinateSpaceName = "quickInputHistoryScroll"

    private var messages: [PickyMainAgentMessage] { viewModel.recentMessages }
    private var anchorMessageID: String? { QuickInputHistoryPolicy.anchorMessageID(in: messages) }
    private var hasEarlierMessages: Bool { QuickInputHistoryPolicy.hasEarlierMessages(in: messages) }
    private var showsTopFade: Bool {
        hasEarlierMessages && hasContentAboveViewport
    }
    private var effectiveBackgroundMode: QuickInputHistoryBackgroundMode {
        accessibilityReduceTransparency ? .solid : backgroundMode
    }
    private var topFadeSurfaceOpacity: Double {
        effectiveBackgroundMode == .solid
            ? QuickInputPanelLayout.historySolidSurfaceOpacity
            : QuickInputPanelLayout.historyLightweightSurfaceTopOpacity
    }
    private var bottomFadeSurfaceOpacity: Double {
        QuickInputPanelLayout.historySolidSurfaceOpacity
    }

    private var anchorIndex: Int {
        guard let anchorMessageID,
              let index = messages.firstIndex(where: { $0.id == anchorMessageID }) else {
            return messages.startIndex
        }
        return index
    }

    private var earlierMessages: [PickyMainAgentMessage] {
        Array(messages[..<anchorIndex])
    }

    private var currentTurnMessages: [PickyMainAgentMessage] {
        guard !messages.isEmpty else { return [] }
        return Array(messages[anchorIndex...])
    }

    private var maximumScrollHeight: CGFloat {
        QuickInputHistoryPolicy.scrollHeightLimit(
            cardHeightLimit: viewModel.historyCardHeightLimit
        ) ?? 0
    }

    private var scrollHeight: CGFloat {
        guard trailingTurnHeight > 0 else { return maximumScrollHeight }
        return min(trailingTurnHeight, maximumScrollHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: QuickInputHistoryScrollOffsetKey.self,
                            value: geometry.frame(in: .named(scrollCoordinateSpaceName)).minY
                        )
                    }
                    .frame(height: 0)

                    // The transcript is capped at 100 messages. Keep all rows
                    // materialized so the initial scroll-to-last-turn target
                    // exists before the proxy resolves it.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(earlierMessages) { message in
                            PickyMainAgentTranscriptRow(message: message)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(currentTurnMessages) { message in
                                PickyMainAgentTranscriptRow(message: message)
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: QuickInputHistoryTrailingTurnHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: QuickInputHistoryContentBottomKey.self,
                            value: geometry.frame(in: .named(scrollCoordinateSpaceName)).maxY
                        )
                    }
                )
            }
            .coordinateSpace(name: scrollCoordinateSpaceName)
            .frame(height: scrollHeight)
            .overlay(alignment: .top) {
                if showsTopFade {
                    LinearGradient(
                        colors: [
                            DS.Colors.surface1.opacity(topFadeSurfaceOpacity),
                            DS.Colors.surface1.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(QuickInputPanelLayout.historyTopFadeHeight, scrollHeight))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if hasContentBelowViewport {
                    LinearGradient(
                        colors: [
                            DS.Colors.surface1.opacity(0),
                            DS.Colors.surface1.opacity(bottomFadeSurfaceOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(QuickInputPanelLayout.historyBottomFadeHeight, scrollHeight))
                    .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 10)
            .accessibilityLabel("Recent conversation")
            .background(QuickInputHistoryCardBackground(mode: effectiveBackgroundMode))
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous))
            .onAppear { scrollToAnchor(proxy) }
            .onChange(of: viewModel.presentationID) { _ in
                hasContentAboveViewport = true
                hasContentBelowViewport = false
                resetBackgroundForPresentation()
                scrollToAnchor(proxy)
            }
            .onChange(of: viewModel.recentMessages.last?.id) { _ in
                hasContentAboveViewport = true
                hasContentBelowViewport = false
                scrollToAnchor(proxy)
            }
            .onPreferenceChange(QuickInputHistoryScrollOffsetKey.self) { offset in
                updateContentAboveViewport(offset)
                recordUserScrollIfNeeded()
            }
            .onPreferenceChange(QuickInputHistoryContentBottomKey.self) { bottom in
                updateContentBelowViewport(bottom)
            }
            .onPreferenceChange(QuickInputHistoryTrailingTurnHeightKey.self) { height in
                guard abs(trailingTurnHeight - height) > 0.5 else { return }
                trailingTurnHeight = height
                viewModel.onFittingSizeChanged()
            }
        }
    }

    private func updateContentAboveViewport(_ offset: CGFloat) {
        let nextValue = hasEarlierMessages && offset < -0.5
        guard hasContentAboveViewport != nextValue else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            hasContentAboveViewport = nextValue
        }
    }

    private func updateContentBelowViewport(_ contentBottom: CGFloat) {
        let nextValue = QuickInputHistoryPolicy.hasContentBelowViewport(
            contentBottom: contentBottom,
            viewportHeight: scrollHeight
        )
        guard hasContentBelowViewport != nextValue else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            hasContentBelowViewport = nextValue
        }
    }

    private func recordUserScrollIfNeeded() {
        // Offset changes from scroll wheels, trackpads, and scrollbars all flow
        // through this preference. Anchor positioning is explicitly gated so
        // the initial programmatic scroll cannot make the card solid.
        guard !isApplyingAnchorScroll, backgroundMode == .lightweight else { return }
        backgroundMode.recordUserScroll()
    }

    private func resetBackgroundForPresentation() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            backgroundMode.resetForPresentation()
        }
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchorMessageID else { return }
        isApplyingAnchorScroll = true
        anchorScrollRequestID &+= 1
        let requestID = anchorScrollRequestID
        // Let the revised transcript finish laying out before resolving the
        // anchor. This keeps a freshly appended turn at its prompt rather than
        // at the previous content height.
        DispatchQueue.main.async {
            proxy.scrollTo(anchorMessageID, anchor: .top)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + QuickInputPanelLayout.historyAnchorSettlingDuration
            ) {
                guard anchorScrollRequestID == requestID else { return }
                isApplyingAnchorScroll = false
            }
        }
    }
}

private struct QuickInputHistoryCardBackground: View {
    let mode: QuickInputHistoryBackgroundMode

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
    }

    var body: some View {
        ZStack {
            lightweightSurface
                .opacity(mode == .lightweight ? 1 : 0)
            solidSurface
                .opacity(mode == .solid ? 1 : 0)
        }
        // Keep the transition scoped to chrome so a scroll never animates the
        // card's height, rows, or viewport fades.
        .animation(
            .easeInOut(duration: QuickInputPanelLayout.historyBackgroundTransitionDuration),
            value: mode
        )
    }

    private var lightweightSurface: some View {
        shape
            .fill(
                LinearGradient(
                    colors: [
                        DS.Colors.surface1.opacity(QuickInputPanelLayout.historyLightweightSurfaceTopOpacity),
                        DS.Colors.surface1.opacity(QuickInputPanelLayout.historyLightweightSurfaceBottomOpacity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            DS.Colors.borderSubtle.opacity(QuickInputPanelLayout.historyLightweightBorderTopOpacity),
                            DS.Colors.borderSubtle.opacity(QuickInputPanelLayout.historyLightweightBorderBottomOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: Color.black.opacity(QuickInputPanelLayout.historyLightweightMainShadowOpacity),
                radius: QuickInputPanelLayout.mainShadowRadius,
                x: 0,
                y: QuickInputPanelLayout.mainShadowYOffset
            )
            .shadow(
                color: Color.black.opacity(QuickInputPanelLayout.historyLightweightTightShadowOpacity),
                radius: QuickInputPanelLayout.tightShadowRadius,
                x: 0,
                y: QuickInputPanelLayout.tightShadowYOffset
            )
    }

    private var solidSurface: some View {
        shape
            .fill(DS.Colors.surface1.opacity(QuickInputPanelLayout.historySolidSurfaceOpacity))
            .overlay(
                shape.stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
            )
            .shadow(
                color: Color.black.opacity(QuickInputPanelLayout.mainShadowOpacity),
                radius: QuickInputPanelLayout.mainShadowRadius,
                x: 0,
                y: QuickInputPanelLayout.mainShadowYOffset
            )
            .shadow(
                color: Color.black.opacity(QuickInputPanelLayout.tightShadowOpacity),
                radius: QuickInputPanelLayout.tightShadowRadius,
                x: 0,
                y: QuickInputPanelLayout.tightShadowYOffset
            )
    }
}

private struct QuickInputHistoryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct QuickInputHistoryContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct QuickInputHistoryTrailingTurnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

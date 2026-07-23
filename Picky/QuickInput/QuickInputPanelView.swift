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
    static let pillWidth: CGFloat = 360
    static let capsuleHeight: CGFloat = 44
    static let historyPillSpacing: CGFloat = 6
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

/// Whether the current Quick Input submission will carry a screenshot.
/// Driven by `CompanionManager` from `PickySettings.attachScreenshotsOnlyWhenInked`
/// combined with live ink state. Ink-drawn turns are surfaced as plain
/// `.attached` on purpose — the pill stays quiet, ink visibility is already
/// communicated by the on-screen overlay itself.
enum QuickInputScreenshotState: Equatable {
    /// Screenshot will be attached (with or without ink marks).
    case attached
    /// `attachScreenshotsOnlyWhenInked` is on and no ink was drawn, so the
    /// model payload will not include a screenshot.
    case gated
}

@MainActor
final class QuickInputPanelViewModel: ObservableObject {
    @Published var draftText: String = ""
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published var screenshotState: QuickInputScreenshotState = .attached
    @Published var recentMessages: [PickyMainAgentMessage] = []
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
            if QuickInputHistoryPolicy.shouldShowCard(for: viewModel.recentMessages) {
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

                screenshotIndicator

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

    private var screenshotIndicator: some View {
        // 22pt circle matching the trailing close-button rhythm. Two states
        // only: neutral camera when a screenshot will be attached, muted
        // camera with diagonal strike when the ink-only attachment gate is
        // suppressing it.
        let isGated = viewModel.screenshotState == .gated
        let tint: Color = isGated ? DS.Colors.textTertiary : DS.Colors.textSecondary
        return ZStack {
            Image(systemName: "camera")
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(tint)
            if isGated {
                // Diagonal strike to read as "no screenshot" without an extra
                // SF Symbol that ships differently across macOS versions.
                Rectangle()
                    .fill(tint)
                    .frame(width: 16, height: 1)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .help(L10n.t(screenshotIndicatorHelpKey))
        .accessibilityLabel(Text(L10n.t(screenshotIndicatorHelpKey)))
    }

    private var screenshotIndicatorHelpKey: String {
        switch viewModel.screenshotState {
        case .attached: "quickInput.screenshot.attached"
        case .gated: "quickInput.screenshot.gated"
        }
    }
}

private struct QuickInputHistoryCard: View {
    @ObservedObject var viewModel: QuickInputPanelViewModel
    @State private var trailingTurnHeight: CGFloat = 0

    private var messages: [PickyMainAgentMessage] { viewModel.recentMessages }
    private var anchorMessageID: String? { QuickInputHistoryPolicy.anchorMessageID(in: messages) }
    private var hasEarlierMessages: Bool { QuickInputHistoryPolicy.hasEarlierMessages(in: messages) }

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

    private var hintHeight: CGFloat {
        hasEarlierMessages ? 22 : 0
    }

    private var maximumScrollHeight: CGFloat {
        max(1, viewModel.historyCardHeightLimit - hintHeight - 20)
    }

    private var scrollHeight: CGFloat {
        guard trailingTurnHeight > 0 else { return maximumScrollHeight }
        return min(trailingTurnHeight, maximumScrollHeight)
    }

    private var showsBottomFade: Bool {
        trailingTurnHeight > maximumScrollHeight + 0.5
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if hasEarlierMessages {
                    Text(L10n.t("quickInput.history.scrollEarlier"))
                        .font(PickyHUDTypography.minimumMedium)
                        .foregroundStyle(DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityHint(L10n.t("quickInput.history.scrollEarlier"))
                }

                ZStack {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 14) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .frame(height: scrollHeight)
                    .accessibilityLabel("Recent conversation")

                    if hasEarlierMessages {
                        LinearGradient(
                            colors: [DS.Colors.surface1, DS.Colors.surface1.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: min(18, scrollHeight))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                    }

                    if showsBottomFade {
                        LinearGradient(
                            colors: [DS.Colors.surface1.opacity(0), DS.Colors.surface1],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: min(24, scrollHeight))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                    }
                }
            }
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
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
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous))
            .onAppear { scrollToAnchor(proxy) }
            .onChange(of: viewModel.recentMessages.last?.id) { _ in
                scrollToAnchor(proxy)
            }
            .onPreferenceChange(QuickInputHistoryTrailingTurnHeightKey.self) { height in
                guard abs(trailingTurnHeight - height) > 0.5 else { return }
                trailingTurnHeight = height
                viewModel.onFittingSizeChanged()
            }
        }
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchorMessageID else { return }
        // Let the revised transcript finish laying out before resolving the
        // anchor. This keeps a freshly appended turn at its prompt rather than
        // at the previous content height.
        DispatchQueue.main.async {
            proxy.scrollTo(anchorMessageID, anchor: .top)
        }
    }
}

private struct QuickInputHistoryTrailingTurnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

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

/// Whether (and how) the current Quick Input submission will carry a
/// screenshot of the user's screen. Driven by `CompanionManager` based on
/// live ink state plus `PickySettings.attachScreenshotsOnlyWhenInked`.
enum QuickInputScreenshotState: Equatable {
    /// Screenshot will be attached as-is (no ink marks drawn yet).
    case attached
    /// User drew at least one ink stroke — screenshot + marks will be attached.
    case annotated
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

    var onSubmit: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Message Picky…", text: $viewModel.draftText, axis: .horizontal)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
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
                    .font(.system(size: 10.5, weight: .medium))
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
                        .font(.system(size: 12, weight: .bold))
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
        .keyboardShortcut(.return, modifiers: [])
    }

    private var closeButton: some View {
        Button(action: { viewModel.close() }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var isSendDisabled: Bool {
        viewModel.isSending
            || viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var screenshotIndicator: some View {
        // 22pt circle matching the trailing close-button rhythm. Color-only
        // differentiation by design — no icon swap, no count badge.
        let tint: Color
        switch viewModel.screenshotState {
        case .attached:
            tint = DS.Colors.textSecondary
        case .annotated:
            tint = DS.Colors.accent
        case .gated:
            tint = DS.Colors.textTertiary
        }
        return ZStack {
            Image(systemName: "camera")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
            if viewModel.screenshotState == .gated {
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
        case .annotated: "quickInput.screenshot.annotated"
        case .gated: "quickInput.screenshot.gated"
        }
    }
}

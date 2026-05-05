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

@MainActor
final class QuickInputPanelViewModel: ObservableObject {
    @Published var draftText: String = ""
    @Published var isSending: Bool = false
    @Published var errorMessage: String?

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

    /// Capsule corner radius — matches the reference pill shape.
    private let capsuleHeight: CGFloat = 44
    private let panelWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Picky에 메시지…", text: $viewModel.draftText, axis: .horizontal)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
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
                    .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
            )

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: panelWidth, alignment: .leading)
        .padding(.vertical, 4)
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
}

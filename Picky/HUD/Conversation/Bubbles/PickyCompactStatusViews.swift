//
//  PickyCompactStatusViews.swift
//  Picky
//
//  Compacting status affordances for conversation cards.
//

import SwiftUI

struct PickyCompactingOverlayView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.56)
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(DS.Colors.info)
                Text("hud.compact.running")
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Capsule().fill(DS.Colors.surface1.opacity(0.96)))
            .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Compacting")
    }
}

struct PickyCompactCompletionBubbleView: View {
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(DS.Colors.info.opacity(0.34), lineWidth: 0.8)
                    Image(systemName: "checkmark")
                        .pickyFont(size: 8.5, weight: .bold)
                        .foregroundColor(DS.Colors.info)
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("hud.compact.done.title")
                        .font(PickyHUDTypography.labelSemibold)
                        .foregroundColor(DS.Colors.info)
                    Text("hud.compact.done.body")
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.info.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth, fraction: 0.86), alignment: .leading)
            .background(compactBubbleShape.fill(DS.Colors.accentSubtle.opacity(0.28)))
            .overlay(compactBubbleShape.stroke(DS.Colors.info.opacity(0.25), lineWidth: 0.7))
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PickyCompactFailureBubbleView: View {
    let message: PickySessionMessage
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(DS.Colors.destructiveText.opacity(0.42), lineWidth: 0.8)
                    Image(systemName: "exclamationmark")
                        .pickyFont(size: 9, weight: .bold)
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("hud.compact.failed.title")
                        .font(PickyHUDTypography.labelSemibold)
                        .foregroundColor(DS.Colors.destructiveText)
                    if let detail = message.compactFailureDetailText {
                        Text(detail)
                            .font(PickyHUDTypography.status)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth, fraction: 0.86), alignment: .leading)
            .background(compactBubbleShape.fill(DS.Colors.destructiveText.opacity(0.07)))
            .overlay(compactBubbleShape.stroke(DS.Colors.destructiveText.opacity(0.38), lineWidth: 0.7))
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private var compactBubbleShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
        topLeadingRadius: 12,
        bottomLeadingRadius: 4,
        bottomTrailingRadius: 12,
        topTrailingRadius: 12,
        style: .continuous
    )
}

extension PickySessionMessage {
    var isCompactCompletionMessage: Bool {
        guard kind == .system else { return false }
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized == "session compacted" || normalized == "session compacted after context overflow"
    }

    var isCompactFailureMessage: Bool {
        guard kind == .system else { return false }
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.hasPrefix("auto-compaction failed")
    }

    var compactFailureDetailText: String? {
        guard isCompactFailureMessage else { return nil }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = trimmed.components(separatedBy: .newlines)
        let detail = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : detail
    }
}

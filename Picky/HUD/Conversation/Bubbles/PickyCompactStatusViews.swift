//
//  PickyCompactStatusViews.swift
//  Picky
//
//  Compacting status affordances for conversation cards.
//

import SwiftUI

struct PickyCompactingOverlayView: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    var body: some View {
        ZStack {
            if accessibilityReduceTransparency {
                Rectangle()
                    .fill(DS.Colors.surface1)
            } else {
                Rectangle()
                    .fill(.regularMaterial)
                    .opacity(0.56)
            }
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
        .accessibilityLabel(L10n.t("hud.compact.running"))
    }
}

struct PickyCompactCompletionBubbleView: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: DS.Spacing.space1) {
                    Image(systemName: "checkmark.circle")
                        .font(PickyHUDTypography.statusSemibold)
                    Text("hud.compact.done.title")
                        .font(PickyHUDTypography.statusSemibold)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .pickyFont(size: 9, weight: .semibold)
                }
                .foregroundColor(DS.Colors.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(isExpanded ? "hud.compact.done.collapse" : "hud.compact.done.expand"))
            .accessibilityLabel(L10n.t("hud.compact.done.title"))
            .accessibilityValue(L10n.t(
                isExpanded ? "hud.conversation.turn.expanded" : "hud.conversation.turn.collapsed"
            ))
            .accessibilityHint(L10n.t(isExpanded ? "hud.compact.done.collapse" : "hud.compact.done.expand"))
            .hoverAffordance()

            if isExpanded {
                Text("hud.compact.done.body")
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.Spacing.space4)
            }
        }
        .padding(.vertical, DS.Spacing.space1)
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
    PickyConversationBubbleLayout.bubbleShape(side: .agent)
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

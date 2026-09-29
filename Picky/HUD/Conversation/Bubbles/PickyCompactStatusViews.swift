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
    var message: PickySessionMessage? = nil
    var onOpenAsReport: (() -> Void)? = nil
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: DS.Spacing.space1) {
                    Image(systemName: "checkmark.circle")
                        .font(PickyHUDTypography.statusSemibold)
                    Text("hud.compact.done.title")
                        .font(PickyHUDTypography.statusSemibold)
                    if let tokenChangeText {
                        Text(tokenChangeText)
                            .font(PickyHUDTypography.statusMonospacedMedium)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .pickyFont(size: 9, weight: .semibold)
                }
                .foregroundColor(DS.Colors.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(isExpanded ? "hud.compact.done.collapse" : "hud.compact.done.expand"))
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(L10n.t(
                isExpanded ? "hud.conversation.turn.expanded" : "hud.conversation.turn.collapsed"
            ))
            .accessibilityHint(L10n.t(isExpanded ? "hud.compact.done.collapse" : "hud.compact.done.expand"))
            .hoverAffordance()

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    Text("hud.compact.done.body")
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summaryPreview {
                        Text(summaryPreview)
                            .font(PickyHUDTypography.status)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(Self.summaryPreviewLineLimit)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if summaryPreview != nil, let onOpenAsReport {
                        Button(action: onOpenAsReport) {
                            Text("hud.extensionMessage.openAsReport")
                                .font(PickyHUDTypography.statusSemibold)
                                .foregroundColor(DS.Colors.accentText)
                        }
                        .buttonStyle(.plain)
                        .hoverAffordance()
                    }
                }
                .padding(.leading, DS.Spacing.space4)
            }
        }
        .padding(.vertical, DS.Spacing.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let summaryPreviewLineLimit = 6

    /// `128k → ~21k`; the after value is Pi's estimate of the kept context.
    var tokenChangeText: String? {
        guard let compaction = message?.compaction else { return nil }
        let before = Self.abbreviatedTokenCount(compaction.tokensBefore)
        guard let after = compaction.tokensAfter else { return before }
        return "\(before) → ~\(Self.abbreviatedTokenCount(after))"
    }

    var summaryPreview: String? {
        let summary = message?.compaction?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? nil : summary
    }

    private var accessibilityTitle: String {
        let title = L10n.t("hud.compact.done.title")
        guard let tokenChangeText else { return title }
        return "\(title), \(tokenChangeText)"
    }

    static func abbreviatedTokenCount(_ count: Double) -> String {
        let value = max(0, count)
        if value < 1_000 { return String(Int(value.rounded())) }
        if value < 10_000 {
            let thousands = (value / 100).rounded() / 10
            return thousands == thousands.rounded() ? "\(Int(thousands))k" : "\(thousands)k"
        }
        return "\(Int((value / 1_000).rounded()))k"
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
    /// Report body for a compaction row: Pi's summary when the daemon recorded one.
    var compactSummaryReportMarkdown: String? {
        guard isCompactCompletionMessage else { return nil }
        let summary = compaction?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? nil : summary
    }

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

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
                Text("Compacting…")
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
    var body: some View {
        HStack {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(DS.Colors.info.opacity(0.34), lineWidth: 0.8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(DS.Colors.info)
                }
                .frame(width: 18, height: 18)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Session compacted")
                        .font(PickyHUDTypography.labelSemibold)
                        .foregroundColor(DS.Colors.info)
                    Text("Older context was summarized. The agent can continue with a cleaner transcript.")
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.info.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.86, alignment: .leading)
            .background(compactBubbleShape.fill(DS.Colors.accentSubtle.opacity(0.28)))
            .overlay(compactBubbleShape.stroke(DS.Colors.info.opacity(0.25), lineWidth: 0.7))
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}

extension PickySessionMessage {
    var isCompactCompletionMessage: Bool {
        guard kind == .system else { return false }
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized == "session compacted" || normalized == "session compacted after context overflow"
    }
}

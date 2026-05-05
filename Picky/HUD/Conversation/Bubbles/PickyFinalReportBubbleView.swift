//
//  PickyFinalReportBubbleView.swift
//  Picky
//
//  Rich final report bubble for conversation cards.
//

import SwiftUI

struct PickyFinalReportBubbleView: View {
    let report: PickyFinalReport

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("▾ FINAL REPORT · status=\(report.status.rawValue)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(DS.Colors.success)
                    .lineLimit(1)
                Text(report.summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !report.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(.init(report.body))
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.artifacts.isEmpty {
                    artifactsRow
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.88, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(DS.Colors.success.opacity(0.07))
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .stroke(DS.Colors.success.opacity(0.58), lineWidth: 1)
            )
            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artifactsRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(report.artifacts.prefix(3).enumerated()), id: \.offset) { _, artifact in
                if let url = artifact.url {
                    Link(destination: url) { artifactPill(artifact) }
                        .buttonStyle(.plain)
                } else {
                    artifactPill(artifact)
                }
            }
            if report.artifacts.count > 3 {
                Text("+\(report.artifacts.count - 3)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func artifactPill(_ artifact: PickyFinalReport.Artifact) -> some View {
        HStack(spacing: 4) {
            Text(artifact.kind)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(DS.Colors.success)
            Text(artifact.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.72)))
        .overlay(Capsule().stroke(DS.Colors.success.opacity(0.38), lineWidth: 0.5))
    }
}

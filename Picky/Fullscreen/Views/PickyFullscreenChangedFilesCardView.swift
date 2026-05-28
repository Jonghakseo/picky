//
//  PickyFullscreenChangedFilesCardView.swift
//  Picky
//
//  Session-scoped changed-files summary for fullscreen conversation.
//

import SwiftUI

struct PickyFullscreenChangedFilesCardView: View {
    let changedFiles: [PickyChangedFile]

    var body: some View {
        if !changedFiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .pickyFont(size: 12, weight: .semibold)
                    Text("세션 변경 파일")
                        .pickyFont(size: 13, weight: .semibold)
                    Text("\(changedFiles.count)")
                        .pickyFont(size: 11, weight: .bold, design: .monospaced)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(changedFiles.prefix(Self.maxVisibleFiles).enumerated()), id: \.offset) { _, file in
                        changedFileRow(file)
                    }
                    if changedFiles.count > Self.maxVisibleFiles {
                        Text("+ \(changedFiles.count - Self.maxVisibleFiles)개 더 있음")
                            .pickyFont(size: 11.5, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("세션 변경 파일")
        }
    }

    private static let maxVisibleFiles = 6

    private func changedFileRow(_ file: PickyChangedFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(statusBadgeText(for: file.status))
                .pickyFont(size: 10, weight: .bold, design: .monospaced)
                .foregroundStyle(statusColor(for: file.status))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .pickyFont(size: 12, weight: .medium, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary = file.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    Text(summary)
                        .pickyFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func statusBadgeText(for status: String) -> String {
        switch status.lowercased() {
        case "added", "a", "new": "A"
        case "modified", "m", "changed": "M"
        case "deleted", "d", "removed": "D"
        case "renamed", "r": "R"
        default: "•"
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "added", "a", "new": .green
        case "modified", "m", "changed": .blue
        case "deleted", "d", "removed": .red
        case "renamed", "r": .purple
        default: .secondary
        }
    }
}

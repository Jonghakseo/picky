//
//  PickyToolActivityRow.swift
//  Picky
//
//  Tool activity row rendering for session details.
//

import SwiftUI

struct PickyToolActivityRow: View {
    let tool: PickyToolActivity

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                    if tool.riskLevel != .normal {
                        Text(riskLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(tool.riskLevel == .external ? DS.Colors.warning : DS.Colors.info)
                    }
                    Spacer()
                    Text(tool.status)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                if let preview = tool.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2.opacity(0.72)))
    }

    private var statusColor: Color {
        if tool.didFail { return DS.Colors.destructiveText }
        if tool.isActive { return DS.Colors.accentText }
        return DS.Colors.success
    }

    private var riskLabel: String {
        switch tool.riskLevel {
        case .normal: ""
        case .elevated: "local tool"
        case .external: "external"
        }
    }
}

private func shortCwd(_ cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "no cwd" }
    let url = URL(fileURLWithPath: cwd)
    let last = url.lastPathComponent
    return last.isEmpty ? cwd : last
}

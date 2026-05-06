//
//  PickyConversationContextLineView.swift
//  Picky
//
//  Compact cwd, git, and external-link context row for conversation cards.
//

import AppKit
import SwiftUI

struct PickyConversationContextLineView: View {
    let session: PickySessionListViewModel.SessionCard
    @State private var gitStatus: PickyGitRepositoryStatus?

    private var gitStatusRefreshKey: String {
        "\(session.cwd ?? "")|\(session.updatedAt.timeIntervalSince1970)"
    }

    var body: some View {
        HStack(spacing: 6) {
            if let compactCwd = session.compactCwdDescription {
                Button(action: { PickyFinderOpenRequest.open(cwd: session.cwd) }) {
                    Label {
                        Text(compactCwd)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .labelStyle(.titleAndIcon)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .help("Open working folder in Finder")
                .pointerCursor()
            }

            if let gitStatus {
                separatorDot
                HStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(gitStatus.branchDisplayName)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if gitStatus.insertions > 0 {
                        gitMetricPill("+\(gitStatus.insertions)", color: DS.Colors.success)
                            .help("Insertions")
                    }
                    if gitStatus.deletions > 0 {
                        gitMetricPill("-\(gitStatus.deletions)", color: DS.Colors.destructiveText)
                            .help("Deletions")
                    }
                    if gitStatus.aheadCount > 0 {
                        gitMetricPill("↑\(gitStatus.aheadCount)", color: DS.Colors.accentText)
                            .help("Ahead of upstream")
                    }
                    if gitStatus.behindCount > 0 {
                        gitMetricPill("↓\(gitStatus.behindCount)", color: DS.Colors.warningText)
                            .help("Behind upstream")
                    }
                }
                .layoutPriority(1)
            }

            if !session.linkBadgeArtifacts.isEmpty {
                separatorDot
                HStack(spacing: 4) {
                    ForEach(session.linkBadgeArtifacts.prefix(3)) { artifact in
                        if let url = artifact.url {
                            Link(destination: url) {
                                linkBadge(artifact)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(artifact.title)")
                        } else {
                            linkBadge(artifact)
                        }
                    }
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundColor(DS.Colors.textTertiary)
        .task(id: gitStatusRefreshKey) {
            if let cachedStatus = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cachedStatus
            }
            let loadedStatus = await PickyGitRepositoryStatus.load(cwd: session.cwd)
            guard !Task.isCancelled else { return }
            gitStatus = loadedStatus
        }
    }

    private var separatorDot: some View {
        Circle()
            .fill(DS.Colors.textTertiary.opacity(0.55))
            .frame(width: 3, height: 3)
    }

    private func linkBadge(_ artifact: PickyArtifact) -> some View {
        HStack(spacing: 3) {
            Image(systemName: linkBadgeIcon(for: artifact))
                .font(.system(size: 9.5, weight: .semibold))
            if let text = session.linkBadgeText(for: artifact) {
                Text(text)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundColor(DS.Colors.accentText)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(DS.Colors.accentSubtle.opacity(0.75)))
    }

    private func linkBadgeIcon(for artifact: PickyArtifact) -> String {
        switch artifact.linkBadgeKind {
        case .github:
            return "chevron.left.forwardslash.chevron.right"
        case .slack:
            return "number"
        case .notion:
            return "doc.text"
        case nil:
            return "link"
        }
    }

    private func gitMetricPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(color.opacity(0.92))
    }
}

enum PickyFinderOpenRequest {
    static func existingDirectoryURL(cwd: String?, fileManager: FileManager = .default) -> URL? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let path = NSString(string: trimmed).standardizingPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func open(cwd: String?, workspace: NSWorkspace = .shared) {
        guard let url = existingDirectoryURL(cwd: cwd) else { return }
        workspace.open(url)
    }
}

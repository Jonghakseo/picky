//
//  PickyConversationContextLineView.swift
//  Picky
//
//  Compact cwd, git, and external-link context row for conversation cards.
//

import AppKit
import SwiftUI
import UserNotifications

struct PickyConversationContextLineView: View {
    let session: PickySessionListViewModel.SessionCard
    @State private var gitStatus: PickyGitRepositoryStatus?
    @State private var inFlightGitAction: GitRemoteAction?
    @State private var manualRefreshTick: Int = 0

    private enum GitRemoteAction: Equatable {
        case push
        case pull

        var actionLabel: String {
            switch self {
            case .push: return "git push"
            case .pull: return "git pull"
            }
        }

        var arguments: [String] {
            switch self {
            case .push: return ["push"]
            case .pull: return ["pull"]
            }
        }
    }

    private var gitStatusRefreshKey: String {
        "\(session.cwd ?? "")|\(session.updatedAt.timeIntervalSince1970)|\(manualRefreshTick)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasPrimaryContext {
                primaryContextLine
            }

            if let gitStatus {
                gitContextLine(status: gitStatus)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundColor(DS.Colors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: gitStatusRefreshKey) {
            if let cachedStatus = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cachedStatus
            }
            let loadedStatus = await PickyGitRepositoryStatus.load(cwd: session.cwd)
            guard !Task.isCancelled else { return }
            gitStatus = loadedStatus
        }
    }

    private var hasPrimaryContext: Bool {
        session.compactCwdDescription != nil || !session.linkBadgeArtifacts.isEmpty
    }

    private var primaryContextLine: some View {
        HStack(spacing: 6) {
            if let compactCwd = session.compactCwdDescription {
                cwdButton(compactCwd)
            }

            if !session.linkBadgeArtifacts.isEmpty {
                if session.compactCwdDescription != nil {
                    separatorDot
                }
                linkBadges
                    .layoutPriority(2)
            }
        }
    }

    private func gitContextLine(status: PickyGitRepositoryStatus) -> some View {
        HStack(spacing: 6) {
            repositoryLabel(status: status)
                .layoutPriority(1)
            separatorDot
            branchLabel(status: status)
                .layoutPriority(1)
            HStack(spacing: 4) {
                gitMetrics(status: status)
            }
            .layoutPriority(2)
        }
    }

    private func cwdButton(_ compactCwd: String) -> some View {
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

    private var linkBadges: some View {
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

    @ViewBuilder
    private func repositoryLabel(status: PickyGitRepositoryStatus) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
            Text(status.repositoryDisplayName)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())

        if let url = status.remoteWebURL {
            Link(destination: url) {
                content
            }
            .buttonStyle(.plain)
            .help("Open \(url.absoluteString)")
            .pointerCursor()
        } else {
            content
        }
    }

    @ViewBuilder
    private func gitMetrics(status: PickyGitRepositoryStatus) -> some View {
        if status.insertions > 0 {
            gitMetricPill("+\(status.insertions)", color: DS.Colors.success)
                .help("Insertions")
        }
        if status.deletions > 0 {
            gitMetricPill("-\(status.deletions)", color: DS.Colors.destructiveText)
                .help("Deletions")
        }
        if status.aheadCount > 0 {
            Button(action: { runRemoteAction(.push) }) {
                gitMetricPill("↑\(status.aheadCount)", color: DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .disabled(inFlightGitAction != nil)
            .opacity(inFlightGitAction == .push ? 0.45 : 1)
            .help(inFlightGitAction == .push ? "Pushing…" : "git push (\(status.aheadCount) ahead of upstream)")
            .pointerCursor()
        }
        if status.behindCount > 0 {
            Button(action: { runRemoteAction(.pull) }) {
                gitMetricPill("↓\(status.behindCount)", color: DS.Colors.warningText)
            }
            .buttonStyle(.plain)
            .disabled(inFlightGitAction != nil)
            .opacity(inFlightGitAction == .pull ? 0.45 : 1)
            .help(inFlightGitAction == .pull ? "Pulling…" : "git pull (\(status.behindCount) behind upstream)")
            .pointerCursor()
        }
    }

    private var separatorDot: some View {
        Circle()
            .fill(DS.Colors.textTertiary.opacity(0.55))
            .frame(width: 3, height: 3)
    }

    @ViewBuilder
    private func branchLabel(status: PickyGitRepositoryStatus) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text(status.branchDisplayName)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())

        if let url = status.remoteWebURL {
            Link(destination: url) {
                content
            }
            .buttonStyle(.plain)
            .help("Open \(url.absoluteString)")
            .pointerCursor()
        } else {
            content
        }
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

    private func runRemoteAction(_ action: GitRemoteAction) {
        guard inFlightGitAction == nil else { return }
        guard let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else { return }
        inFlightGitAction = action
        Task {
            let outcome = await PickyGitRepositoryStatus.runCommand(action.arguments, cwd: cwd)
            await MainActor.run {
                inFlightGitAction = nil
                PickyGitRepositoryStatus.invalidateCache(cwd: cwd)
                manualRefreshTick &+= 1
                if !outcome.isSuccess {
                    deliverGitFailureNotification(action: action, outcome: outcome)
                }
            }
        }
    }

    private func deliverGitFailureNotification(action: GitRemoteAction, outcome: PickyGitRepositoryStatus.GitCommandOutcome) {
        let summary = outcome.combinedOutput.isEmpty ? "exit \(outcome.exitCode)" : outcome.combinedOutput
        let trimmedSummary = summary.split(whereSeparator: { $0.isNewline }).prefix(4).joined(separator: "\n")
        let content = UNMutableNotificationContent()
        content.title = "\(action.actionLabel) failed"
        content.body = String(trimmedSummary.prefix(280))
        content.sound = nil
        let request = UNNotificationRequest(identifier: "picky-git-\(action.actionLabel)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
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

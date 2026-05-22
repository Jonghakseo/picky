//
//  PickyConversationContextLineView.swift
//  Picky
//
//  Compact cwd, git, and external-link context row for conversation cards.
//

import AppKit
import SwiftUI
import UserNotifications

enum PickyGitContextRefreshPolicy {
    static let completedSessionRefreshIntervalNanoseconds: UInt64 = 60_000_000_000

    static func shouldAutoRefreshGit(for status: PickySessionStatus) -> Bool {
        status == .completed
    }
}

struct PickyConversationContextLineView: View {
    let session: PickySessionListViewModel.SessionCard
    @Environment(\.colorScheme) private var colorScheme
    @State private var gitStatus: PickyGitRepositoryStatus?
    @State private var pullRequestStatus: PickyGitHubPullRequestStatus?
    @State private var inFlightGitAction: GitRemoteAction?
    @State private var manualRefreshTick: Int = 0

    init(session: PickySessionListViewModel.SessionCard) {
        self.session = session
        // Seed @State synchronously from process-wide caches so the very first paint after a
        // session switch already has git/PR data — eliminates the staircase of layout shifts
        // that otherwise happens as each .task fires asynchronously.
        let cachedGit = PickyGitRepositoryStatus.cached(cwd: session.cwd)
        _gitStatus = State(initialValue: cachedGit)
        let cachedPR = PickyGitHubPullRequestStatus.cached(cwd: session.cwd, branch: cachedGit?.branchName)
        _pullRequestStatus = State(initialValue: cachedPR?.status ?? nil)
    }

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

    private var contextRefreshKey: String {
        "\(session.cwd ?? "")|\(session.updatedAt.timeIntervalSince1970)|\(manualRefreshTick)"
    }

    private var completedSessionRefreshKey: String {
        "\(session.id)|\(session.cwd ?? "")|\(session.status.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasPrimaryContext {
                primaryContextLine
            }

            if let gitStatus {
                gitContextLine(status: gitStatus)
            }

            if hasLinkContext {
                linkContextLine
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundColor(DS.Colors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: contextRefreshKey) {
            // SWR step 1: hydrate from cache in case cwd became valid after init seeding.
            if gitStatus == nil, let cachedStatus = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cachedStatus
            }

            // SWR step 2: revalidate git (cheap, always run so insertions/ahead-behind stay accurate).
            let freshGit = await PickyGitRepositoryStatus.load(cwd: session.cwd)
            guard !Task.isCancelled else { return }
            gitStatus = freshGit

            // SWR step 3: PR — paint cached value, only hit `gh` if cache is missing or stale.
            let branch = freshGit?.branchName
            let cachedPR = PickyGitHubPullRequestStatus.cached(cwd: session.cwd, branch: branch)
            if let cachedPR {
                pullRequestStatus = cachedPR.status
            }
            let needsPRFetch = cachedPR == nil || cachedPR?.isStale() == true
            guard needsPRFetch else { return }
            let freshPR = await PickyGitHubPullRequestStatus.load(cwd: session.cwd, branch: branch)
            guard !Task.isCancelled else { return }
            pullRequestStatus = freshPR
        }
        .task(id: completedSessionRefreshKey) {
            guard PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: session.status) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: PickyGitContextRefreshPolicy.completedSessionRefreshIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                manualRefreshTick &+= 1
            }
        }
    }

    private var hasLinkContext: Bool {
        !session.linkBadgeArtifacts.isEmpty || pullRequestStatus != nil
    }

    private var hasPrimaryContext: Bool {
        session.compactCwdDescription != nil
    }

    private var primaryContextLine: some View {
        HStack(spacing: 6) {
            if let compactCwd = session.compactCwdDescription {
                cwdButton(compactCwd)
            }
        }
    }

    private var linkContextLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.85))
                .accessibilityLabel("Links")
            linkBadges
                .layoutPriority(2)
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
                    .font(PickyHUDTypography.labelMedium)
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

    private var visibleLinkArtifacts: [PickyArtifact] {
        session.linkBadgeArtifacts(suppressingPullRequest: pullRequestStatus)
    }

    private var linkBadges: some View {
        let artifacts = visibleLinkArtifacts
        return HStack(spacing: 4) {
            if let pullRequestStatus {
                Link(destination: pullRequestStatus.url) {
                    pullRequestBadge(status: pullRequestStatus)
                }
                .buttonStyle(.plain)
                .help("Open PR #\(pullRequestStatus.number) — \(pullRequestStatus.title) [\(pullRequestStatus.state.rawValue)]")
                .pointerCursor()
            }
            ForEach(artifacts.prefix(6)) { artifact in
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
            let remainingCount = artifacts.count - min(artifacts.count, 6)
            if remainingCount > 0 {
                moreLinksBadge(count: remainingCount)
            }
        }
    }

    private func pullRequestBadge(status: PickyGitHubPullRequestStatus) -> some View {
        HStack(spacing: 4) {
            Image("github-logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text("PR")
                .font(PickyHUDTypography.metaMonospacedSemibold)
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Self.pullRequestBackground(for: status.state)))
    }

    static func pullRequestBackground(for state: PickyGitHubPullRequestStatus.State) -> Color {
        // GitHub Primer state-emphasis tokens.
        switch state {
        case .open:
            return Color(hex: "#1F883D")
        case .merged:
            return Color(hex: "#8250DF")
        case .closed:
            return Color(hex: "#CF222E")
        case .draft:
            return Color(hex: "#6E7781")
        }
    }

    @ViewBuilder
    private func repositoryLabel(status: PickyGitRepositoryStatus) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
            Text(status.repositoryDisplayName)
                .font(PickyHUDTypography.labelSemibold)
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
            Button(action: { openDiffViewer(status: status, initialScope: .worktree) }) {
                gitMetricPill("+\(status.insertions)", color: DS.Colors.success)
            }
            .buttonStyle(.plain)
            .help("Open worktree diff (\(status.insertions) insertions)")
            .pointerCursor()
        }
        if status.deletions > 0 {
            Button(action: { openDiffViewer(status: status, initialScope: .worktree) }) {
                gitMetricPill("-\(status.deletions)", color: DS.Colors.destructiveText)
            }
            .buttonStyle(.plain)
            .help("Open worktree diff (\(status.deletions) deletions)")
            .pointerCursor()
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
                .font(PickyHUDTypography.labelMonospacedMedium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())

        if canOpenDiffViewer {
            Button(action: { openDiffViewer(status: status, initialScope: .branch) }) {
                content
            }
            .buttonStyle(.plain)
            .help("Open branch diff")
            .pointerCursor()
        } else {
            content
        }
    }

    private func linkBadge(_ artifact: PickyArtifact) -> some View {
        HStack(spacing: linkBadgeText(for: artifact) == nil ? 0 : 4) {
            linkBadgeIcon(for: artifact)
            if let text = linkBadgeText(for: artifact) {
                Text(text)
                    .font(PickyHUDTypography.metaMonospacedSemibold)
                    .lineLimit(1)
            }
        }
        .foregroundColor(DS.Colors.accentText)
        .padding(.horizontal, linkBadgeText(for: artifact) == nil ? 4 : 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(DS.Colors.accentSubtle.opacity(0.75)))
    }

    private func linkBadgeText(for artifact: PickyArtifact) -> String? {
        session.linkBadgeText(for: artifact)
    }

    @ViewBuilder
    private func linkBadgeIcon(for artifact: PickyArtifact) -> some View {
        // Known Links badges must use official brand logo assets. Do not use
        // SF Symbols, emoji, or hand-drawn approximations for known services;
        // add the missing official asset first. Unknown links may use the
        // generic link icon below.
        switch artifact.linkBadgeKind {
        case .github:
            Image("github-logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
        case .slack:
            officialLinkLogo("slack-logo")
        case .notion:
            officialLinkLogo("notion-logo")
        case .jira:
            officialLinkLogo("jira-logo")
        case .sentry:
            officialTemplateLinkLogo("sentry-logo", color: sentryLogoColor)
        case .linear:
            officialLinkLogo("linear-logo")
        case .figma:
            officialLinkLogo("figma-logo")
        case .googleDocs:
            officialLinkLogo("google-docs-logo", side: googleWorkspaceLogoSide, plate: googleWorkspaceLogoPlate)
        case .googleSheets:
            officialLinkLogo("google-sheets-logo", side: googleWorkspaceLogoSide, plate: googleWorkspaceLogoPlate)
        case .googleSlides:
            officialLinkLogo("google-slides-logo", side: googleWorkspaceLogoSide, plate: googleWorkspaceLogoPlate)
        case .googleDrive:
            officialLinkLogo("google-drive-logo", side: googleWorkspaceLogoSide, plate: googleWorkspaceLogoPlate)
        case nil:
            Image(systemName: "link")
                .font(.system(size: 9.5, weight: .semibold))
                .accessibilityHidden(true)
        }
    }

    private func officialLinkLogo(_ assetName: String, side: CGFloat = 11, plate: Color? = nil) -> some View {
        ZStack {
            if let plate {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(plate)
                    .frame(width: side + 2, height: side + 2)
            }
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
        }
        .frame(width: plate == nil ? side : side + 2, height: plate == nil ? side : side + 2)
        .accessibilityHidden(true)
    }

    private func officialTemplateLinkLogo(_ assetName: String, color: Color, side: CGFloat = 11) -> some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .foregroundColor(color)
            .accessibilityHidden(true)
    }

    private var sentryLogoColor: Color {
        colorScheme == .dark ? .white : Color(hex: "#181225")
    }

    private var googleWorkspaceLogoSide: CGFloat { 12 }

    private var googleWorkspaceLogoPlate: Color? {
        colorScheme == .dark ? Color.white.opacity(0.92) : nil
    }

    private func moreLinksBadge(count: Int) -> some View {
        Text("+\(count)")
            .font(PickyHUDTypography.metaMonospacedSemibold)
            .foregroundColor(DS.Colors.accentText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(DS.Colors.accentSubtle.opacity(0.75)))
            .help("\(count) more links")
    }

    private func gitMetricPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PickyHUDTypography.statusMonospacedMedium)
            .foregroundColor(color.opacity(0.92))
            .contentShape(Rectangle())
    }

    private var canOpenDiffViewer: Bool {
        guard let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !cwd.isEmpty
    }

    private func openDiffViewer(status: PickyGitRepositoryStatus, initialScope: PickyGitDiffViewerScope) {
        guard let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else { return }
        PickyDiffViewerPresenter.shared.openDiff(
            sessionID: session.id,
            title: diffViewerTitle(status: status),
            cwd: cwd,
            initialScope: initialScope
        )
    }

    private func diffViewerTitle(status: PickyGitRepositoryStatus) -> String {
        let trimmedSessionTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSessionTitle.isEmpty {
            return trimmedSessionTitle
        }
        return "\(status.repositoryDisplayName) · \(status.branchName)"
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

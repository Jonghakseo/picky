//
//  PickyConversationContextLineView.swift
//  Picky
//
//  Compact cwd, git, and external-link context row for conversation cards.
//

import AppKit
import SwiftUI
import UserNotifications

enum PickyConversationContextLinkCountPolicy {
    static func count(visibleLinkArtifacts: [PickyArtifact], pullRequest: PickyGitHubPullRequestStatus?) -> Int {
        let linkKeys = Set(visibleLinkArtifacts.map { artifact in
            artifact.url?.absoluteString.lowercased() ?? "artifact:\(artifact.id)"
        })
        guard let pullRequest else { return linkKeys.count }
        // `visibleLinkArtifacts` normally removes this already, but count the
        // dedicated PR only when it is not a remaining visible link as well.
        return linkKeys.count + (linkKeys.contains(pullRequest.url.absoluteString.lowercased()) ? 0 : 1)
    }
}

struct PickyConversationContextSummaryPresentation: Equatable {
    let workspaceName: String?
    let branchDisplayName: String?

    var label: String? {
        switch (workspaceName, branchDisplayName) {
        case let (workspace?, branch?): return "\(workspace) - \(branch)"
        case let (workspace?, nil): return workspace
        case let (nil, branch?): return branch
        case (nil, nil): return nil
        }
    }
}

enum PickyConversationContextSummaryPolicy {
    static func presentation(
        repositoryDisplayName: String? = nil,
        branchDisplayName: String?,
        cwd: String?
    ) -> PickyConversationContextSummaryPresentation {
        let repository = repositoryDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let branch = branchDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = path.isEmpty
            ? ""
            : URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackFolder = folder.isEmpty || folder == "/" ? nil : folder

        return PickyConversationContextSummaryPresentation(
            workspaceName: repository.isEmpty ? fallbackFolder : repository,
            branchDisplayName: branch.isEmpty ? nil : branch
        )
    }

    static func label(
        repositoryDisplayName: String? = nil,
        branchDisplayName: String?,
        cwd: String?
    ) -> String? {
        presentation(
            repositoryDisplayName: repositoryDisplayName,
            branchDisplayName: branchDisplayName,
            cwd: cwd
        ).label
    }
}

/// Uncommitted line counts as the summary row renders them. The row shows the
/// working-tree diff only; the branch total lives in the details popover.
struct PickyConversationUncommittedDiffPresentation: Equatable {
    let insertionsText: String?
    let deletionsText: String?
}

/// Details-popover projection of the git line counts. The leading pair is the
/// whole branch measured from where it forked off the default branch; the
/// parenthesized pair is the uncommitted subset, shown only when it differs.
struct PickyGitChangeMetricsPresentation: Equatable {
    struct Pair: Equatable {
        let insertionsText: String?
        let deletionsText: String?

        init(stat: PickyGitRepositoryStatus.DiffStat) {
            insertionsText = stat.insertions > 0 ? "+\(stat.insertions)" : nil
            deletionsText = stat.deletions > 0 ? "-\(stat.deletions)" : nil
        }

        var hasContent: Bool { insertionsText != nil || deletionsText != nil }
    }

    let total: Pair
    let uncommitted: Pair?
    let totalLines: Int
    let uncommittedLines: Int

    init(status: PickyGitRepositoryStatus) {
        let uncommittedStat = PickyGitRepositoryStatus.DiffStat(
            insertions: status.insertions,
            deletions: status.deletions
        )
        // Without an origin remote there is no base to measure the branch
        // against, so the uncommitted pair is the only truthful total.
        let totalStat = status.branchDiff ?? uncommittedStat
        total = Pair(stat: totalStat)
        uncommitted = uncommittedStat.isEmpty || uncommittedStat == totalStat ? nil : Pair(stat: uncommittedStat)
        totalLines = totalStat.insertions + totalStat.deletions
        uncommittedLines = uncommittedStat.insertions + uncommittedStat.deletions
    }

    var hasContent: Bool { total.hasContent }
}

enum PickyConversationUncommittedDiffPolicy {
    static func presentation(status: PickyGitRepositoryStatus?) -> PickyConversationUncommittedDiffPresentation? {
        guard let status, status.hasUncommittedChanges else { return nil }
        let insertions = status.insertions > 0 ? "+\(status.insertions)" : nil
        let deletions = status.deletions > 0 ? "-\(status.deletions)" : nil
        guard insertions != nil || deletions != nil else { return nil }
        return PickyConversationUncommittedDiffPresentation(
            insertionsText: insertions,
            deletionsText: deletions
        )
    }

    /// The counts replace the dirty asterisk, so the summary keeps `*` only when
    /// the tree is dirty in a way that produces no countable line change (a bare
    /// rename or mode bit). Otherwise the marker would just be noise beside a number.
    static func summaryBranchLabel(status: PickyGitRepositoryStatus) -> String {
        presentation(status: status) == nil ? status.branchDisplayName : status.branchName
    }
}

struct PickyConversationContextSummaryWidthAllocation: Equatable {
    let folderWidth: CGFloat
    let separatorWidth: CGFloat
    let branchWidth: CGFloat
}

enum PickyConversationContextSummaryWidthPolicy {
    static let preferredFolderShare: CGFloat = 0.35

    static func resolve(
        availableWidth: CGFloat,
        folderIdealWidth: CGFloat,
        separatorIdealWidth: CGFloat,
        branchIdealWidth: CGFloat,
        spacing: CGFloat
    ) -> PickyConversationContextSummaryWidthAllocation {
        let folderIdealWidth = max(0, folderIdealWidth)
        let separatorIdealWidth = max(0, separatorIdealWidth)
        let branchIdealWidth = max(0, branchIdealWidth)
        let spacing = max(0, spacing)
        let naturalWidth = folderIdealWidth + separatorIdealWidth + branchIdealWidth + (spacing * 2)

        guard availableWidth.isFinite else {
            return PickyConversationContextSummaryWidthAllocation(
                folderWidth: folderIdealWidth,
                separatorWidth: separatorIdealWidth,
                branchWidth: branchIdealWidth
            )
        }

        let availableWidth = max(0, availableWidth)
        guard naturalWidth > availableWidth else {
            return PickyConversationContextSummaryWidthAllocation(
                folderWidth: folderIdealWidth,
                separatorWidth: separatorIdealWidth,
                branchWidth: branchIdealWidth
            )
        }

        let visibleSpacing = min(spacing * 2, availableWidth)
        let availableAfterSpacing = max(0, availableWidth - visibleSpacing)
        let separatorWidth = min(separatorIdealWidth, availableAfterSpacing)
        let contentWidth = max(0, availableAfterSpacing - separatorWidth)
        let preferredFolderWidth = contentWidth * preferredFolderShare

        let branchWidth: CGFloat
        let folderWidth: CGFloat
        if branchIdealWidth <= contentWidth - preferredFolderWidth {
            branchWidth = branchIdealWidth
            folderWidth = min(folderIdealWidth, contentWidth - branchWidth)
        } else {
            folderWidth = min(folderIdealWidth, preferredFolderWidth)
            branchWidth = min(branchIdealWidth, contentWidth - folderWidth)
        }

        return PickyConversationContextSummaryWidthAllocation(
            folderWidth: folderWidth,
            separatorWidth: separatorWidth,
            branchWidth: branchWidth
        )
    }
}

private struct PickyConversationContextSummaryLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = idealSizes.reduce(0) { $0 + $1.width } + (spacing * 2)
        let allocation = allocation(
            availableWidth: proposal.width ?? naturalWidth,
            idealSizes: idealSizes
        )
        let widths = [allocation.folderWidth, allocation.separatorWidth, allocation.branchWidth]
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        }.max() ?? 0

        return CGSize(
            width: min(naturalWidth, proposal.width ?? naturalWidth),
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard subviews.count == 3 else { return }
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let allocation = allocation(availableWidth: bounds.width, idealSizes: idealSizes)
        let widths = [allocation.folderWidth, allocation.separatorWidth, allocation.branchWidth]
        var x = bounds.minX

        for (index, subview) in subviews.enumerated() {
            let width = widths[index]
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: bounds.height))
            subview.place(
                at: CGPoint(x: x, y: bounds.midY - (size.height / 2)),
                proposal: ProposedViewSize(width: width, height: size.height)
            )
            x += width
            if index < subviews.count - 1 {
                x += spacing
            }
        }
    }

    private func allocation(
        availableWidth: CGFloat,
        idealSizes: [CGSize]
    ) -> PickyConversationContextSummaryWidthAllocation {
        PickyConversationContextSummaryWidthPolicy.resolve(
            availableWidth: availableWidth,
            folderIdealWidth: idealSizes[0].width,
            separatorIdealWidth: idealSizes[1].width,
            branchIdealWidth: idealSizes[2].width,
            spacing: spacing
        )
    }
}

enum PickyConversationContextDetailsPresentation {
    static let uncommittedMetricOpacity = 0.72
}

enum PickyGitContextRefreshPolicy {
    static let completedSessionRefreshIntervalNanoseconds: UInt64 = 60_000_000_000
    static let updatedAtRefreshBucketSeconds: TimeInterval = 5
    static let statusFreshnessDuration: TimeInterval = 5

    static func shouldAutoRefreshGit(for status: PickySessionStatus) -> Bool {
        status == .completed
    }
}

struct PickyConversationContextLineView: View {
    let commands: any PickySessionCommands
    /// Context owns exactly metadata (cwd/status/timestamp) and artifacts;
    /// transcript updates never enter this projection.
    let metaStore: PickySessionMetaStore
    let artifactStore: PickySessionArtifactStore
    private var session: PickyConversationContextProjection {
        PickyConversationContextProjection(metaStore: metaStore, artifactStore: artifactStore)
    }
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var faviconStore = PickyFaviconStore.shared
    @State private var gitStatus: PickyGitRepositoryStatus?
    @State private var pullRequestStatus: PickyGitHubPullRequestStatus?
    @State private var inFlightGitAction: GitRemoteAction?
    @State private var isDetailsPresented = false
    @State private var didCopyWorkspacePath = false
    @State private var workspaceCopyFeedbackGeneration = 0
    @State private var manualRefreshTick: Int = 0

    init(
        viewModel: any PickySessionCommands,
        metaStore: PickySessionMetaStore,
        artifactStore: PickySessionArtifactStore
    ) {
        self.commands = viewModel
        self.metaStore = metaStore
        self.artifactStore = artifactStore
        let projection = PickyConversationContextProjection(metaStore: metaStore, artifactStore: artifactStore)
        // Seed @State synchronously from process-wide caches so the very first paint after a
        // session switch already has git/PR data — eliminates the staircase of layout shifts
        // that otherwise happens as each .task fires asynchronously.
        let cachedGit = PickyGitRepositoryStatus.cached(cwd: projection.cwd)
        _gitStatus = State(initialValue: cachedGit)
        let cachedPR = PickyGitHubPullRequestStatus.cached(
            cwd: projection.cwd,
            repositoryURL: cachedGit?.remoteWebURL,
            branch: cachedGit?.branchName
        )
        _pullRequestStatus = State(initialValue: cachedPR?.status ?? nil)
    }

    /// Compatibility entry point for existing tests and previews.
    init(viewModel: any PickySessionCommands, session: PickyConversationSessionCard) {
        let metaStore = PickySessionMetaStore()
        metaStore.replace(PickySessionMetadata(card: session))
        let artifactStore = PickySessionArtifactStore()
        artifactStore.replace(artifacts: session.artifacts, changedFiles: session.changedFiles)
        self.init(viewModel: viewModel, metaStore: metaStore, artifactStore: artifactStore)
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

        var symbol: String {
            switch self {
            case .push: return "↑"
            case .pull: return "↓"
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
        let updatedAtBucket = Int(
            session.updatedAt.timeIntervalSince1970 / PickyGitContextRefreshPolicy.updatedAtRefreshBucketSeconds
        )
        return "\(session.cwd ?? "")|\(updatedAtBucket)|\(manualRefreshTick)"
    }

    private var completedSessionRefreshKey: String {
        "\(session.id)|\(session.cwd ?? "")|\(session.status.rawValue)"
    }

    var body: some View {
        let _ = PickyPerf.event("context_line_body")
        contextSummaryLine
        .pickyFont(size: 10.5, weight: .medium)
        .foregroundColor(DS.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(isPresented: $isDetailsPresented, arrowEdge: .bottom) {
            contextDetails
        }
        // These refresh tasks stay on the always-mounted summary root. Opening
        // Details only reveals existing state, so it cannot restart cache/SWR.
        .task(id: contextRefreshKey) {
            PickyPerf.event("context_line_refresh_task_start")
            // SWR step 1: hydrate from cache in case cwd became valid after init seeding.
            if gitStatus == nil, let cachedStatus = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cachedStatus
            }

            // SWR step 2: revalidate git when the short shared freshness window expires.
            // Rapid reopen and mini-preview callers coalesce on the same cwd/generation.
            let freshGit = await PickyPerf.interval("context_line_git_load") {
                await PickyGitRepositoryStatus.load(
                    cwd: session.cwd,
                    maximumAge: PickyGitContextRefreshPolicy.statusFreshnessDuration
                )
            }
            guard !Task.isCancelled else { return }
            PickyPerf.event("context_line_git_state_publish")
            gitStatus = freshGit

            // SWR step 3: PR — paint cached value, only hit `gh` if cache is missing or stale.
            let branch = freshGit?.branchName
            let repositoryURL = freshGit?.remoteWebURL
            let cachedPR = PickyGitHubPullRequestStatus.cached(
                cwd: session.cwd,
                repositoryURL: repositoryURL,
                branch: branch
            )
            if let cachedPR {
                PickyPerf.event("context_line_pr_cached_publish")
                pullRequestStatus = cachedPR.status
            }
            let needsPRFetch = cachedPR == nil || cachedPR?.isStale() == true
            guard needsPRFetch else { return }
            let freshPR = await PickyPerf.interval("context_line_pr_load") {
                await PickyGitHubPullRequestStatus.load(
                    cwd: session.cwd,
                    repositoryURL: repositoryURL,
                    branch: branch,
                    artifactURLs: session.artifacts.compactMap(\.url)
                )
            }
            guard !Task.isCancelled else { return }
            PickyPerf.event("context_line_pr_state_publish")
            pullRequestStatus = freshPR
        }
        .task(id: completedSessionRefreshKey) {
            PickyPerf.event("context_line_completed_refresh_task_start")
            guard PickyGitContextRefreshPolicy.shouldAutoRefreshGit(for: session.status) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: PickyGitContextRefreshPolicy.completedSessionRefreshIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                manualRefreshTick &+= 1
            }
        }
        .task(id: faviconPageURLs) {
            await faviconStore.load(pageURLs: faviconPageURLs)
        }
    }

    private var contextSummaryLine: some View {
        HStack(spacing: DS.Spacing.space1) {
            Button(action: { isDetailsPresented.toggle() }) {
                HStack(spacing: DS.Spacing.space1) {
                    Image(systemName: contextSummaryIconName)
                        .font(PickyHUDTypography.metaSemibold)
                        .accessibilityHidden(true)
                    contextSummaryText
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(contextSummaryLabel)\n\(L10n.t("hud.context.details.help"))")
            .accessibilityLabel(L10n.t("hud.context.details.accessibilityLabel"))
            .accessibilityValue(contextSummaryLabel)
            .accessibilityHint(L10n.t("hud.context.details.accessibilityHint"))
            .hoverAffordance()

            if let gitStatus {
                if let uncommittedDiffPresentation {
                    uncommittedDiffButton(
                        uncommittedDiffPresentation,
                        lineCount: gitStatus.insertions + gitStatus.deletions
                    )
                    .layoutPriority(3)
                }

                if uncommittedDiffPresentation != nil, hasRemoteActions(status: gitStatus) {
                    Divider()
                        .frame(height: DS.Spacing.space3)
                }

                remoteActionButtons(status: gitStatus)
            }

            if let pullRequestStatus {
                pullRequestLink(status: pullRequestStatus)
                    .layoutPriority(2)
            }

            Button(action: { isDetailsPresented.toggle() }) {
                Image(systemName: "chevron.down")
                    .font(PickyHUDTypography.metaSemibold)
                    .rotationEffect(.degrees(isDetailsPresented ? 180 : 0))
                    .frame(width: DS.Spacing.space6, height: DS.Spacing.space6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("hud.context.details.help"))
            .accessibilityHidden(true)
            .hoverAffordance()
        }
    }

    private var contextSummaryPresentation: PickyConversationContextSummaryPresentation {
        PickyConversationContextSummaryPolicy.presentation(
            repositoryDisplayName: gitStatus?.repositoryDisplayName,
            branchDisplayName: gitStatus.map(PickyConversationUncommittedDiffPolicy.summaryBranchLabel(status:)),
            cwd: session.cwd
        )
    }

    private var uncommittedDiffPresentation: PickyConversationUncommittedDiffPresentation? {
        PickyConversationUncommittedDiffPolicy.presentation(status: gitStatus)
    }

    private var contextSummaryLabel: String {
        contextSummaryPresentation.label ?? L10n.t("hud.context.section.links")
    }

    private func uncommittedDiffButton(
        _ presentation: PickyConversationUncommittedDiffPresentation,
        lineCount: Int
    ) -> some View {
        let counts = [presentation.insertionsText, presentation.deletionsText]
            .compactMap { $0 }
            .joined(separator: " ")
        let accessibilityLabel = L10n.t(
            "hud.context.summary.uncommitted.accessibilityValue",
            L10n.t("hud.context.section.git"),
            counts
        )

        return Button(action: runDiffChipAction) {
            HStack(spacing: DS.Spacing.space1) {
                if let insertionsText = presentation.insertionsText {
                    Text(insertionsText)
                        .foregroundColor(DS.Colors.successText)
                }
                if let deletionsText = presentation.deletionsText {
                    Text(deletionsText)
                        .foregroundColor(DS.Colors.destructiveText)
                }
            }
            .font(PickyHUDTypography.metaMonospacedSemibold)
            .padding(.horizontal, DS.Spacing.space1)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule())
        }
        .buttonStyle(PickyHUDCompactChipButtonStyle())
        .help(uncommittedDiffActionHelp(lineCount: lineCount))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(uncommittedDiffActionHelp(lineCount: lineCount))
    }

    @ViewBuilder
    private var contextSummaryText: some View {
        if let workspaceName = contextSummaryPresentation.workspaceName,
           let branchDisplayName = contextSummaryPresentation.branchDisplayName {
            PickyConversationContextSummaryLayout(spacing: DS.Spacing.space1) {
                Text(workspaceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("-")
                    .fixedSize(horizontal: true, vertical: false)
                Text(branchDisplayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(PickyHUDTypography.metaMedium)
            .accessibilityHidden(true)
        } else {
            Text(contextSummaryLabel)
                .font(PickyHUDTypography.metaMedium)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)
        }
    }

    private var contextSummaryIconName: String {
        if gitStatus != nil { return "point.3.connected.trianglepath.dotted" }
        if session.compactCwdDescription != nil { return "folder" }
        return "link"
    }

    private var contextDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if hasPrimaryContext {
                contextDetailsHeading(L10n.t("hud.context.section.workspace"))
                primaryContextLine
            }
            if let gitStatus {
                contextDetailsHeading(L10n.t("hud.context.section.git"))
                gitContextLine(status: gitStatus)
            }
            if hasLinkContext {
                contextDetailsHeading(L10n.t("hud.context.section.links"))
                linkContextLine
            }
        }
        .pickyFont(size: 10.5, weight: .medium)
        .foregroundColor(DS.Colors.textPrimary)
        .padding(DS.Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.context.details.accessibilityLabel"))
    }

    private func contextDetailsHeading(_ title: String) -> some View {
        Text(title)
            .font(PickyHUDTypography.metaSemibold)
            .foregroundColor(DS.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var contextLinkCount: Int {
        PickyConversationContextLinkCountPolicy.count(
            visibleLinkArtifacts: visibleLinkArtifacts,
            pullRequest: pullRequestStatus
        )
    }

    /// The card uses this before constructing the context row so sessions with no
    /// folder or artifact metadata do not retain an empty layout slot. Git and pull
    /// request state require a working directory, which already supplies the
    /// primary context line.
    static func hasContent(for session: PickyConversationSessionCard) -> Bool {
        let projection = PickyConversationContextProjection(card: session)
        return hasContent(for: projection)
    }

    static func hasContent(for projection: PickyConversationContextProjection) -> Bool {
        projection.compactCwdDescription != nil || !PickyArtifactTrayPresentation.trayArtifacts(from: projection.artifacts).isEmpty
    }

    private var trayArtifacts: [PickyArtifact] {
        PickyArtifactTrayPresentation.trayArtifacts(from: session.artifacts)
    }

    private var hasLinkContext: Bool {
        !trayArtifacts.isEmpty || pullRequestStatus != nil
    }

    private var hasPrimaryContext: Bool {
        session.compactCwdDescription != nil
    }

    private var primaryContextLine: some View {
        HStack(spacing: DS.Spacing.space1) {
            if let compactCwd = session.compactCwdDescription,
               let copyValue = PickyWorkspacePathCopyPolicy.value(cwd: session.cwd) {
                cwdButton(compactCwd)
                Spacer(minLength: DS.Spacing.space2)
                workspacePathCopyButton(copyValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var linkContextLine: some View {
        HStack(spacing: 6) {
            if !trayArtifacts.isEmpty {
                PickyArtifactTrayButton(artifacts: trayArtifacts)
            }
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
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .labelStyle(.titleAndIcon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .help(L10n.t("hud.context.workspace.open.help"))
        .hoverAffordance()
    }

    private func workspacePathCopyButton(_ copyValue: String) -> some View {
        Button(action: { copyWorkspacePath(copyValue) }) {
            Image(systemName: didCopyWorkspacePath ? "checkmark" : "doc.on.doc")
                .font(PickyHUDTypography.statusSemibold)
                .foregroundStyle(didCopyWorkspacePath ? DS.Colors.successText : DS.Colors.accentText)
                .frame(width: DS.Spacing.space6, height: DS.Spacing.space6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(didCopyWorkspacePath ? "hud.context.workspace.copy.copied" : "hud.context.workspace.copy.help"))
        .accessibilityLabel(L10n.t(didCopyWorkspacePath ? "hud.context.workspace.copy.copied" : "hud.context.workspace.copy.help"))
        .hoverAffordance()
    }

    private func copyWorkspacePath(_ copyValue: String) {
        commands.copyMessageText(copyValue)
        didCopyWorkspacePath = true
        workspaceCopyFeedbackGeneration &+= 1
        let feedbackGeneration = workspaceCopyFeedbackGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard workspaceCopyFeedbackGeneration == feedbackGeneration else { return }
            didCopyWorkspacePath = false
        }
    }

    private var visibleLinkArtifacts: [PickyArtifact] {
        session.linkBadgeArtifacts(suppressingPullRequest: pullRequestStatus)
    }

    private var faviconPageURLs: [URL] {
        visibleLinkArtifacts.prefix(6).compactMap { artifact in
            artifact.linkBadgeKind == .generic ? artifact.url : nil
        }
    }

    private var linkBadges: some View {
        let artifacts = visibleLinkArtifacts
        return HStack(spacing: 4) {
            if let pullRequestStatus {
                pullRequestLink(status: pullRequestStatus)
            }
            ForEach(artifacts.prefix(6)) { artifact in
                if let url = artifact.url {
                    Link(destination: url) {
                        linkBadge(artifact)
                    }
                    .buttonStyle(.plain)
                    .help(linkBadgeHelp(for: artifact))
                    .accessibilityLabel(linkBadgeHelp(for: artifact))
                    .hoverAffordance()
                } else {
                    linkBadge(artifact)
                }
            }
        }
    }

    private func pullRequestLink(status: PickyGitHubPullRequestStatus) -> some View {
        let help = L10n.t(
            "hud.context.pr.open.help",
            Int64(status.number),
            status.title,
            pullRequestStateLabel(for: status.state)
        )
        return Link(destination: status.url) {
            pullRequestBadge(status: status)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .hoverAffordance()
    }

    private func pullRequestBadge(status: PickyGitHubPullRequestStatus) -> some View {
        let stateColor = Self.pullRequestStateColor(for: status.state)

        return HStack(spacing: 4) {
            Image("github-logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(verbatim: "PR \(pullRequestStateLabel(for: status.state))")
                .font(PickyHUDTypography.metaMonospacedSemibold)
                .lineLimit(1)
        }
        .foregroundColor(stateColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        // Light keeps the tint at 5%: the fg-grade state colors sit near the
        // 4.5:1 AA floor on white, so a 10% tint would drag them under it.
        // Dark has more headroom and keeps the 10% tint for chip legibility.
        .background(Capsule().fill(stateColor.opacity(colorScheme == .dark ? 0.10 : 0.05)))
        .overlay(Capsule().stroke(stateColor.opacity(0.32), lineWidth: 0.5))
    }

    private func pullRequestStateLabel(for state: PickyGitHubPullRequestStatus.State) -> String {
        switch state {
        case .draft:
            return L10n.t("hud.context.pr.state.draft")
        case .open:
            return L10n.t("hud.context.pr.state.open")
        case .merged:
            return L10n.t("hud.context.pr.state.merged")
        case .closed:
            return L10n.t("hud.context.pr.state.closed")
        }
    }

    static func pullRequestStateColor(for state: PickyGitHubPullRequestStatus.State) -> Color {
        switch state {
        case .open:
            return DS.Integration.GitHub.prOpen
        case .merged:
            return DS.Integration.GitHub.prMerged
        case .closed:
            return DS.Integration.GitHub.prClosed
        case .draft:
            return DS.Integration.GitHub.prDraft
        }
    }

    @ViewBuilder
    private func repositoryLabel(status: PickyGitRepositoryStatus) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(DS.Colors.textSecondary)
            Text(status.repositoryDisplayName)
                .font(PickyHUDTypography.labelSemibold)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())

        if let url = status.remoteWebURL {
            Link(destination: url) {
                content
            }
            .buttonStyle(.plain)
            .help(L10n.t("hud.context.link.open.help", url.absoluteString))
            .hoverAffordance()
        } else {
            content
        }
    }

    @ViewBuilder
    private func gitMetrics(status: PickyGitRepositoryStatus) -> some View {
        gitChangeMetrics(status: status)
    }

    @ViewBuilder
    private func gitChangeMetrics(status: PickyGitRepositoryStatus) -> some View {
        let presentation = PickyGitChangeMetricsPresentation(status: status)
        if presentation.hasContent {
            HStack(spacing: DS.Spacing.space1) {
                diffPair(presentation.total, opacity: 1)
                if let uncommitted = presentation.uncommitted {
                    HStack(spacing: DS.Spacing.space1) {
                        gitMetricPill("(", color: DS.Colors.textTertiary)
                        diffPair(
                            uncommitted,
                            opacity: PickyConversationContextDetailsPresentation.uncommittedMetricOpacity
                        )
                        gitMetricPill(")", color: DS.Colors.textTertiary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(diffMetricsAccessibilityLabel(presentation))
        }
    }

    private func hasRemoteActions(status: PickyGitRepositoryStatus) -> Bool {
        status.aheadCount > 0 || status.behindCount > 0
    }

    @ViewBuilder
    private func remoteActionButtons(status: PickyGitRepositoryStatus) -> some View {
        if status.aheadCount > 0 {
            remoteActionButton(.push, count: status.aheadCount, color: DS.Colors.accentText)
        }
        if status.behindCount > 0 {
            remoteActionButton(.pull, count: status.behindCount, color: DS.Colors.warningText)
        }
    }

    private func remoteActionButton(
        _ action: GitRemoteAction,
        count: Int,
        color: Color
    ) -> some View {
        let isLoading = inFlightGitAction == action
        let isBlocked = inFlightGitAction != nil && !isLoading
        let label = remoteActionLabel(action, count: count, isLoading: isLoading)

        return Button(action: { runRemoteAction(action) }) {
            ZStack {
                gitMetricPill("\(action.symbol)\(count)", color: color)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: DS.Spacing.space4)
            .padding(.horizontal, DS.Spacing.space1)
            .background(
                Capsule()
                    .fill(isLoading ? DS.Colors.surface3.opacity(0.62) : .clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PickyHUDCompactChipButtonStyle())
        .disabled(inFlightGitAction != nil)
        .opacity(isBlocked ? 0.38 : 1)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func diffPair(_ pair: PickyGitChangeMetricsPresentation.Pair, opacity: Double) -> some View {
        HStack(spacing: 4) {
            if let insertionsText = pair.insertionsText {
                gitMetricPill(insertionsText, color: DS.Colors.successText)
                    .opacity(opacity)
            }
            if let deletionsText = pair.deletionsText {
                gitMetricPill(deletionsText, color: DS.Colors.destructiveText)
                    .opacity(opacity)
            }
        }
    }

    private var separatorDot: some View {
        Circle()
            .fill(DS.Colors.textTertiary.opacity(0.55))
            .frame(width: 3, height: 3)
    }

    private func branchLabel(status: PickyGitRepositoryStatus) -> some View {
        Button(action: { runBranchChipAction() }) {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text(status.branchDisplayName)
                    .font(PickyHUDTypography.labelMonospacedMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(DS.Colors.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(branchChipHelp(branch: status.branchName))
        .hoverAffordance()
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

    private func linkBadgeHelp(for artifact: PickyArtifact) -> String {
        if artifact.linkBadgeKind == .generic, let url = artifact.url {
            return L10n.t("hud.context.link.open.help", url.absoluteString)
        }
        return L10n.t("hud.context.link.open.help", artifact.title)
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
        case .generic:
            if let url = artifact.url, let favicon = faviconStore.image(for: url) {
                Image(nsImage: favicon)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
            } else {
                genericLinkIcon
            }
        case nil:
            genericLinkIcon
        }
    }

    private var genericLinkIcon: some View {
        Image(systemName: "link")
            .pickyFont(size: 9.5, weight: .semibold)
            .accessibilityHidden(true)
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
        DS.Integration.Sentry.logo
    }

    private var googleWorkspaceLogoSide: CGFloat { 12 }

    private var googleWorkspaceLogoPlate: Color? {
        colorScheme == .dark ? Color.white.opacity(0.92) : nil
    }

    private func gitMetricPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PickyHUDTypography.statusMonospacedMedium)
            .foregroundColor(color.opacity(0.92))
    }

    /// Click handler for the `+N` / `-N` chips. Reads the latest settings on
    /// every click so changes made in Settings → Pickle take effect without
    /// a relaunch.
    private func runDiffChipAction() {
        runChipAction(
            slot: PickySettingsStore().load().gitChipActions.diffAction,
            kindFallback: .pi
        )
    }

    /// Click handler for the branch label.
    private func runBranchChipAction() {
        runChipAction(
            slot: PickySettingsStore().load().gitChipActions.branchAction,
            kindFallback: .pi
        )
    }

    private func runChipAction(slot: PickyGitChipAction?, kindFallback: PickyGitChipActionKind) {
        guard let action = slot, action.isConfigured else {
            // Unconfigured chip — surface the Pickle settings so the user can
            // wire up the click. Mirrors how `picky://` markdown links route
            // through the same dispatcher.
            if let url = URL(string: "picky://settings/pickle") {
                PickyDeepLinkDispatcher.shared.handle(url)
            }
            return
        }
        let sessionID = session.id
        let status = session.status
        let cwd = session.cwd
        Task { @MainActor in
            await PickyGitChipActionRunner.run(
                action: action,
                sessionID: sessionID,
                status: status,
                cwd: cwd,
                viewModel: commands
            )
        }
    }

    private func uncommittedDiffActionHelp(lineCount: Int) -> String {
        let configured = PickySettingsStore().load().gitChipActions.diffAction?.command
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configured.isEmpty {
            return L10n.t("hud.context.diff.configure.help", Int64(lineCount))
        }
        return L10n.t("hud.context.diff.action.help", configured, Int64(lineCount))
    }

    private func diffMetricsAccessibilityLabel(_ presentation: PickyGitChangeMetricsPresentation) -> String {
        guard presentation.uncommitted != nil else {
            return L10n.t("hud.context.diff.branch.accessibilityLabel", Int64(presentation.totalLines))
        }
        return L10n.t(
            "hud.context.diff.branch.uncommitted.accessibilityLabel",
            Int64(presentation.totalLines),
            Int64(presentation.uncommittedLines)
        )
    }

    private func remoteActionLabel(_ action: GitRemoteAction, count: Int, isLoading: Bool) -> String {
        if isLoading {
            return action == .push ? "Pushing…" : "Pulling…"
        }
        switch action {
        case .push:
            return "git push (\(count) ahead of upstream)"
        case .pull:
            return "git pull (\(count) behind upstream)"
        }
    }

    private func branchChipHelp(branch: String) -> String {
        let configured = PickySettingsStore().load().gitChipActions.branchAction?.command
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configured.isEmpty {
            return L10n.t("hud.context.branch.configure.help", branch)
        }
        return L10n.t("hud.context.branch.action.help", configured, branch)
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

enum PickyWorkspacePathCopyPolicy {
    static func value(cwd: String?) -> String? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        return NSString(string: expanded).standardizingPath
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

//
//  PickyFullscreenWorkInfoPanelView.swift
//  Picky
//
//  Read-only 변경사항 panel for fullscreen workspace.
//

import SwiftUI

struct PickyFullscreenWorkInfoPanelView: View {
    let session: PickySessionListViewModel.SessionCard?
    @Binding var isVisible: Bool
    @State private var gitStatus: PickyGitRepositoryStatus?
    @State private var didLoadGitStatus = false
    @State private var diffProvider: PickyFullscreenFileDiffProvider?
    @State private var fileNumstat: [String: PickyFullscreenFileDiffProvider.Numstat] = [:]
    @State private var expandedDiffPaths: Set<String> = []
    @State private var loadingDiffPaths: Set<String> = []
    @State private var fileDiffs: [String: String] = [:]
    @State private var failedDiffPaths: Set<String> = []
    @State private var didLoadNumstat = false

    init(session: PickySessionListViewModel.SessionCard?, isVisible: Binding<Bool>) {
        self.session = session
        _isVisible = isVisible
        _gitStatus = State(initialValue: PickyGitRepositoryStatus.cached(cwd: session?.cwd))
        _didLoadGitStatus = State(initialValue: false)
        _diffProvider = State(initialValue: Self.makeDiffProvider(cwd: session?.cwd))
    }

    private var snapshot: PickyFullscreenWorkInfoSnapshot? {
        session.map(PickyFullscreenWorkInfoSnapshot.make)
    }

    private var hasVisibleSections: Bool {
        guard let snapshot else { return false }
        return gitStatus != nil || !snapshot.changedFiles.isEmpty || !snapshot.artifacts.isEmpty
    }

    var body: some View {
        content
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.56))
            .task(id: gitTaskID) {
                await refreshGitStatus()
            }
            .task(id: diffTaskID) {
                await refreshNumstatIfNeeded()
            }
            .onChange(of: gitTaskID) { _, _ in
                didLoadGitStatus = false
                gitStatus = PickyGitRepositoryStatus.cached(cwd: session?.cwd)
            }
            .onChange(of: diffProviderKey) { _, _ in
                resetDiffState()
            }
            .onChange(of: didLoadGitStatus) { _, loaded in
                autoCollapseIfEmpty(loaded: loaded)
            }
            .onChange(of: snapshot?.changedFiles.count ?? 0) { _, _ in
                autoCollapseIfEmpty(loaded: didLoadGitStatus)
            }
            .onChange(of: snapshot?.artifacts.count ?? 0) { _, _ in
                autoCollapseIfEmpty(loaded: didLoadGitStatus)
            }
    }

    @ViewBuilder
    private var content: some View {
        if isVisible {
            panel
                .frame(minWidth: 316, idealWidth: 336, maxWidth: 376, maxHeight: .infinity)
        } else {
            collapsedRail
                .frame(width: 56, alignment: .topLeading)
                .frame(maxHeight: .infinity)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("변경사항")
                    .pickyFont(size: 16, weight: .semibold)
                Spacer(minLength: 0)
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .pickyFont(size: 13, weight: .semibold)
                }
                .buttonStyle(.borderless)
                .help("변경사항 숨기기")
                .accessibilityLabel("변경사항 패널 숨기기")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let gitStatus {
                            branchSection(gitStatus)
                        }
                        if !snapshot.changedFiles.isEmpty {
                            changedFilesSection(snapshot.changedFiles, gitStatus: gitStatus)
                        }
                        if !snapshot.artifacts.isEmpty {
                            artifactsSection(snapshot.artifacts)
                        }
                        if !hasVisibleSections {
                            emptyChanges
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                }
            } else {
                emptySelection
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("변경사항")
    }

    private var collapsedRail: some View {
        VStack(spacing: 0) {
            Button {
                isVisible = true
            } label: {
                Image(systemName: "sidebar.right")
                    .pickyFont(size: 14, weight: .semibold)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("변경사항 보기")
            .accessibilityLabel("변경사항 패널 보기")
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("변경사항")
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .pickyFont(size: 18, weight: .medium)
                .foregroundStyle(.secondary)
            Text("Pickle을 선택하세요")
                .pickyFont(size: 13, weight: .semibold)
            Text("선택한 Pickle의 브랜치, 변경 파일, 참조 링크가 여기에 표시됩니다.")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pickle을 선택하세요")
    }

    private var emptyChanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .pickyFont(size: 18, weight: .medium)
                .foregroundStyle(.secondary)
            Text("표시할 변경사항이 없습니다")
                .pickyFont(size: 13, weight: .semibold)
            Text("변경 파일이나 참조 링크가 생기면 여기에 표시됩니다.")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("표시할 변경사항이 없습니다")
    }

    private func branchSection(_ status: PickyGitRepositoryStatus) -> some View {
        section("브랜치") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status.repositoryDisplayName)
                        .pickyFont(size: 12, weight: .semibold, design: .monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status.branchDisplayName)
                        .pickyFont(size: 12, weight: .medium, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    metricPill("+\(status.insertions)", color: .green)
                    metricPill("-\(status.deletions)", color: .red)
                    if status.aheadCount > 0 {
                        metricPill("↑\(status.aheadCount)", color: .blue)
                    }
                    if status.behindCount > 0 {
                        metricPill("↓\(status.behindCount)", color: .orange)
                    }
                    Spacer(minLength: 0)
                }

                if let url = status.branchWebURL ?? status.remoteWebURL {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right.square")
                            Text("GitHub에서 열기")
                        }
                        .pickyFont(size: 11.5, weight: .semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .help(url.absoluteString)
                }
            }
        }
    }

    private func changedFilesSection(_ files: [PickyChangedFile], gitStatus: PickyGitRepositoryStatus?) -> some View {
        section("세션 누적 변경 · \(files.count)개") {
            VStack(alignment: .leading, spacing: 8) {
                if let gitStatus {
                    HStack(spacing: 6) {
                        Text("작업 트리 합계")
                            .pickyFont(size: 11.5)
                            .foregroundStyle(.secondary)
                        metricPill("+\(gitStatus.insertions)", color: .green)
                        metricPill("-\(gitStatus.deletions)", color: .red)
                        Spacer(minLength: 0)
                    }
                }

                ForEach(Array(files.prefix(Self.maxVisibleChangedFiles).enumerated()), id: \.offset) { _, file in
                    changedFileRow(file)
                }
                if files.count > Self.maxVisibleChangedFiles {
                    emptyText("+ \(files.count - Self.maxVisibleChangedFiles)개 더 있음")
                }
            }
        }
    }

    private func changedFileRow(_ file: PickyChangedFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggleDiff(for: file.path)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expandedDiffPaths.contains(file.path) ? "chevron.down" : "chevron.right")
                        .pickyFont(size: 9.5, weight: .bold)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Circle()
                        .fill(changedFileColor(for: file.status))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(changedFileBadgeText(for: file.status))
                        .pickyFont(size: 10, weight: .bold, design: .monospaced)
                        .foregroundStyle(changedFileColor(for: file.status))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 12, alignment: .leading)
                    Text(file.path)
                        .pickyFont(size: 11.5, weight: .medium, design: .monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    fileNumstatText(for: file.path)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(file.path) diff 보기")

            if expandedDiffPaths.contains(file.path) {
                diffContent(for: file.path)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fileNumstatText(for path: String) -> some View {
        if let stat = fileNumstat[path] {
            HStack(spacing: 4) {
                Text("+\(stat.insertions)")
                    .foregroundStyle(.green)
                Text("−\(stat.deletions)")
                    .foregroundStyle(.red)
            }
            .pickyFont(size: 10.5, weight: .bold, design: .monospaced)
            .fixedSize(horizontal: true, vertical: false)
        } else if didLoadNumstat {
            Text("—")
                .pickyFont(size: 10.5, weight: .bold, design: .monospaced)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func diffContent(for path: String) -> some View {
        if loadingDiffPaths.contains(path) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("diff 불러오는 중…")
                    .pickyFont(size: 11.5)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if let diff = fileDiffs[path] {
            diffBlock(diff)
        } else if failedDiffPaths.contains(path) {
            Text("diff를 불러올 수 없습니다")
                .pickyFont(size: 11.5)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    private func diffBlock(_ diff: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .pickyFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(diffLineColor(String(line)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return .secondary
        }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary.opacity(0.74)
    }

    private func artifactsSection(_ artifacts: [PickyFullscreenWorkInfoSnapshot.Artifact]) -> some View {
        section("참조 링크 · \(artifacts.count)개") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(artifacts.suffix(Self.maxVisibleArtifacts).reversed()) { artifact in
                    artifactRow(artifact)
                }
                if artifacts.count > Self.maxVisibleArtifacts {
                    emptyText("+ \(artifacts.count - Self.maxVisibleArtifacts)개 더 있음")
                }
            }
        }
    }

    private func artifactRow(_ artifact: PickyFullscreenWorkInfoSnapshot.Artifact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Self.artifactBadgeText(for: artifact))
                    .pickyFont(size: 10, weight: .bold, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Text(nonEmpty(artifact.title) ?? "제목 없음")
                    .pickyFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }

            if let url = artifact.url {
                Link(destination: url) {
                    Text(url.absoluteString)
                        .pickyFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(url.absoluteString)
            } else if let path = nonEmpty(artifact.path) {
                Text(path)
                    .pickyFont(size: 11, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .pickyFont(size: 12, weight: .semibold)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
            )
        }
    }

    private func metricPill(_ value: String, color: Color) -> some View {
        Text(value)
            .pickyFont(size: 10.5, weight: .bold, design: .monospaced)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.6))
    }

    private func emptyText(_ value: String) -> some View {
        Text(value)
            .pickyFont(size: 11.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func changedFileBadgeText(for status: String) -> String {
        switch status.lowercased() {
        case "added", "a", "new": "A"
        case "modified", "m", "changed": "M"
        case "deleted", "d", "removed": "D"
        case "renamed", "r": "R"
        default: "•"
        }
    }

    private func changedFileColor(for status: String) -> Color {
        switch status.lowercased() {
        case "added", "a", "new": .green
        case "modified", "m", "changed": .blue
        case "deleted", "d", "removed": .red
        case "renamed", "r": .purple
        default: .secondary
        }
    }

    private var gitTaskID: String {
        "\(session?.id ?? "none")|\(session?.cwd ?? "")|\(session?.updatedAt.timeIntervalSince1970 ?? 0)"
    }

    private var diffProviderKey: String {
        session?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var diffTaskID: String {
        let changedFileKey = snapshot?.changedFiles.map(\.path).joined(separator: "\u{1f}") ?? ""
        return "\(isVisible)|\(diffProviderKey)|\(changedFileKey)"
    }

    private static func makeDiffProvider(cwd: String?) -> PickyFullscreenFileDiffProvider? {
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return PickyFullscreenFileDiffProvider(cwd: trimmed)
    }

    private func refreshGitStatus() async {
        if let cached = PickyGitRepositoryStatus.cached(cwd: session?.cwd) {
            gitStatus = cached
        }
        let freshGit = await PickyGitRepositoryStatus.load(cwd: session?.cwd)
        guard !Task.isCancelled else { return }
        gitStatus = freshGit
        didLoadGitStatus = true
    }

    private func refreshNumstatIfNeeded() async {
        guard isVisible, snapshot?.changedFiles.isEmpty == false, let diffProvider else { return }
        let stats = await diffProvider.fetchNumstat()
        guard !Task.isCancelled else { return }
        fileNumstat = stats
        didLoadNumstat = true
    }

    private func resetDiffState() {
        diffProvider = Self.makeDiffProvider(cwd: session?.cwd)
        fileNumstat = [:]
        expandedDiffPaths = []
        loadingDiffPaths = []
        fileDiffs = [:]
        failedDiffPaths = []
        didLoadNumstat = false
    }

    private func toggleDiff(for path: String) {
        if expandedDiffPaths.contains(path) {
            expandedDiffPaths.remove(path)
            return
        }
        expandedDiffPaths.insert(path)
        guard fileDiffs[path] == nil, !loadingDiffPaths.contains(path), !failedDiffPaths.contains(path) else { return }
        loadingDiffPaths.insert(path)
        Task {
            let diff = await diffProvider?.fetchDiff(path: path)
            guard !Task.isCancelled else { return }
            loadingDiffPaths.remove(path)
            if let diff {
                fileDiffs[path] = diff
                failedDiffPaths.remove(path)
            } else {
                failedDiffPaths.insert(path)
            }
        }
    }

    private func autoCollapseIfEmpty(loaded: Bool) {
        guard loaded, snapshot != nil, isVisible, !hasVisibleSections else { return }
        isVisible = false
    }

    static func artifactBadgeText(for artifact: PickyFullscreenWorkInfoSnapshot.Artifact) -> String {
        switch artifact.linkBadgeKind {
        case .github: "GitHub"
        case .slack: "Slack"
        case .notion: "Notion"
        case .jira: "Jira"
        case .sentry: "Sentry"
        case .linear: "Linear"
        case .figma: "Figma"
        case .googleDocs, .googleSheets, .googleSlides, .googleDrive: "Google"
        case nil:
            "링크"
        }
    }

    private static let maxVisibleChangedFiles = 10
    private static let maxVisibleArtifacts = 8
}

private extension PickyFullscreenWorkInfoSnapshot.Artifact {
    var asPickyArtifact: PickyArtifact {
        PickyArtifact(id: id, kind: kind, title: title, path: path, url: url, updatedAt: updatedAt)
    }

    var linkBadgeKind: PickyLinkBadgeKind? {
        asPickyArtifact.linkBadgeKind
    }
}

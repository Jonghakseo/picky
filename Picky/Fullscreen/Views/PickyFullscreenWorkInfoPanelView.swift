//
//  PickyFullscreenWorkInfoPanelView.swift
//  Picky
//
//  Read-only 작업 정보 panel for fullscreen workspace.
//

import SwiftUI

struct PickyFullscreenWorkInfoPanelView: View {
    let session: PickySessionListViewModel.SessionCard?
    @Binding var isVisible: Bool

    private var snapshot: PickyFullscreenWorkInfoSnapshot? {
        session.map(PickyFullscreenWorkInfoSnapshot.make)
    }

    var body: some View {
        content
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.56))
    }

    @ViewBuilder
    private var content: some View {
        if isVisible {
            panel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, maxHeight: .infinity)
        } else {
            collapsedRail
                .frame(minWidth: 44, idealWidth: 44, maxWidth: 44, maxHeight: .infinity)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("작업 정보")
                    .pickyFont(size: 16, weight: .semibold)
                Spacer(minLength: 0)
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .pickyFont(size: 13, weight: .semibold)
                }
                .buttonStyle(.borderless)
                .help("작업 정보 숨기기")
                .accessibilityLabel("작업 정보 패널 숨기기")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statusSection(snapshot)
                        runtimeSection(snapshot)
                        contextUsageSection(snapshot)
                        activitySection(snapshot)
                        toolsSection(snapshot)
                        changedFilesSection(snapshot)
                        artifactsSection(snapshot)
                        pendingInputSection(snapshot)
                    }
                    .padding(18)
                }
            } else {
                emptySelection
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("작업 정보")
    }

    private var collapsedRail: some View {
        VStack(spacing: 10) {
            Button {
                isVisible = true
            } label: {
                Image(systemName: "sidebar.right")
                    .pickyFont(size: 14, weight: .semibold)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("작업 정보 보기")
            .accessibilityLabel("작업 정보 패널 보기")

            Text("작업 정보")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(90))
                .fixedSize()
                .padding(.top, 26)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("작업 정보")
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "info.circle")
                .pickyFont(size: 18, weight: .medium)
                .foregroundStyle(.secondary)
            Text("Pickle을 선택하세요")
                .pickyFont(size: 13, weight: .semibold)
            Text("선택한 Pickle의 상태, 런타임, 도구, 산출물 정보가 여기에 표시됩니다.")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pickle을 선택하세요")
    }

    private func statusSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("상태") {
            infoRow("상태", snapshot.status.fullscreenWorkInfoDisplayText)
            infoRow("생성", formatDate(snapshot.createdAt))
            infoRow("업데이트", formatDate(snapshot.updatedAt))
            if let notifyMainOnCompletion = snapshot.notifyMainOnCompletion {
                infoRow("완료 알림", notifyMainOnCompletion ? "켜짐" : "꺼짐")
            }
            if snapshot.isPinned { infoRow("고정", "예") }
            if snapshot.isArchived { infoRow("아카이브", "예") }
        }
    }

    private func runtimeSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("런타임") {
            infoRow("모델", nonEmpty(snapshot.assistantModel) ?? "기록 없음")
            infoRow("Thinking", snapshot.assistantThinkingLevel?.rawValue ?? "기록 없음")
            infoRow("Pi 세션", snapshot.canResumePiSession ? "재개 가능" : "기록 없음")
        }
    }

    private func contextUsageSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("컨텍스트 사용량") {
            if let usage = snapshot.contextUsage {
                if let tokens = usage.tokens {
                    infoRow("토큰", formatInteger(tokens))
                } else {
                    infoRow("토큰", "기록 없음")
                }
                infoRow("컨텍스트 한도", formatInteger(usage.contextWindow))
                if let percent = usage.percent {
                    infoRow("사용률", Self.contextUsagePercentText(percent))
                } else {
                    infoRow("사용률", "기록 없음")
                }
            } else {
                emptyText("컨텍스트 사용량 기록이 없습니다.")
            }
        }
    }

    private func activitySection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("현재/마지막 턴 활동") {
            if let activity = snapshot.activity {
                infoRow("범위", activity.label)
                if activity.totalCount == 0 {
                    emptyText("기록된 활동이 없습니다.")
                } else {
                    activityRow("읽기", activity.summary.read)
                    activityRow("Bash", activity.summary.bash)
                    activityRow("편집", activity.summary.edit)
                    activityRow("쓰기", activity.summary.write)
                    activityRow("Thinking", activity.summary.thinking)
                    activityRow("기타", activity.summary.other)
                }
            } else {
                emptyText("턴 활동 스냅샷이 없습니다.")
            }
        }
    }

    private func toolsSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("도구 히스토리") {
            if snapshot.tools.isEmpty {
                emptyText("도구 실행 기록이 없습니다.")
            } else {
                ForEach(snapshot.tools.suffix(8).reversed()) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(tool.name)
                                .pickyFont(size: 12, weight: .semibold, design: .monospaced)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(tool.status)
                                .pickyFont(size: 10, weight: .bold, design: .monospaced)
                                .foregroundStyle(statusColor(for: tool.status))
                        }
                        if let preview = nonEmpty(tool.preview) {
                            Text(preview)
                                .pickyFont(size: 11.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let startedAt = tool.startedAt {
                            Text(toolTimeText(startedAt: startedAt, endedAt: tool.endedAt))
                                .pickyFont(size: 10.5)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func changedFilesSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("세션 변경 파일") {
            if snapshot.changedFiles.isEmpty {
                emptyText("세션 변경 파일 기록이 없습니다.")
            } else {
                ForEach(Array(snapshot.changedFiles.prefix(8).enumerated()), id: \.offset) { _, file in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(file.status.uppercased())
                                .pickyFont(size: 10, weight: .bold, design: .monospaced)
                                .foregroundStyle(changedFileColor(for: file.status))
                            Text(file.path)
                                .pickyFont(size: 11.5, weight: .medium, design: .monospaced)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let summary = nonEmpty(file.summary) {
                            Text(summary)
                                .pickyFont(size: 11.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if snapshot.changedFiles.count > 8 {
                    emptyText("+ \(snapshot.changedFiles.count - 8)개 더 있음")
                }
            }
        }
    }

    private func artifactsSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("링크와 산출물") {
            if snapshot.artifacts.isEmpty {
                emptyText("링크나 산출물 기록이 없습니다.")
            } else {
                ForEach(snapshot.artifacts.suffix(8).reversed()) { artifact in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(artifact.kind)
                                .pickyFont(size: 10, weight: .bold, design: .monospaced)
                                .foregroundStyle(.secondary)
                            Text(artifact.title)
                                .pickyFont(size: 12, weight: .semibold)
                                .lineLimit(1)
                        }
                        if let url = artifact.url {
                            Text(url.absoluteString)
                                .pickyFont(size: 11, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if let path = nonEmpty(artifact.path) {
                            Text(path)
                                .pickyFont(size: 11, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text("업데이트 \(formatDate(artifact.updatedAt))")
                            .pickyFont(size: 10.5)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func pendingInputSection(_ snapshot: PickyFullscreenWorkInfoSnapshot) -> some View {
        section("대기 중 입력") {
            if snapshot.pendingInput.isEmpty {
                emptyText("대기 중인 입력이 없습니다.")
            } else {
                if let title = snapshot.pendingInput.extensionRequestTitle {
                    infoRow("Extension UI", title)
                }
                if let method = snapshot.pendingInput.extensionRequestMethod {
                    infoRow("요청", method)
                }
                if snapshot.pendingInput.queuedSteerCount > 0 {
                    infoRow("대기 steer", "\(snapshot.pendingInput.queuedSteerCount)개")
                }
                if snapshot.pendingInput.queuedFollowUpCount > 0 {
                    infoRow("대기 follow-up", "\(snapshot.pendingInput.queuedFollowUpCount)개")
                }
            }
        }
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

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .pickyFont(size: 11.5)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .pickyFont(size: 11.5, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func activityRow(_ label: String, _ count: Int) -> some View {
        if count > 0 {
            infoRow(label, "\(count)")
        }
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

    private func formatDate(_ date: Date) -> String {
        Self.formatDate(date)
    }

    static func formatDate(_ date: Date, now: Date = Date.now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func formatInteger(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func contextUsagePercentText(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        return "\(Int(clamped.rounded()))%"
    }

    private func toolTimeText(startedAt: Date, endedAt: Date?) -> String {
        if let endedAt {
            return "\(formatDate(startedAt)) – \(formatDate(endedAt))"
        }
        return "시작 \(formatDate(startedAt))"
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "succeeded", "completed", "success": .green
        case "failed", "error": .red
        case "running", "active": .blue
        default: .secondary
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
}

private extension PickySessionStatus {
    var fullscreenWorkInfoDisplayText: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting_for_input: "Waiting for input"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

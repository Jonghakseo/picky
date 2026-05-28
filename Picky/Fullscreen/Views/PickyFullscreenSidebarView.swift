//
//  PickyFullscreenSidebarView.swift
//  Picky
//
//  Left Pickle browser for the fullscreen workspace. Selection is local to the
//  fullscreen state store and intentionally does not mutate HUD selection.
//

import SwiftUI

struct PickyFullscreenSidebarView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let recentPickleCwds: [String]
    let isCreatingPickle: Bool
    let onCreatePickleInRecentFolder: (String) -> Void
    let onChoosePickleFolder: () -> Void
    let onRemoveRecentPickleFolder: (String) -> Void
    @Binding var selectedSessionID: String?
    @State private var isRecentPickleFolderPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sessions) { session in
                            Button {
                                selectedSessionID = session.id
                            } label: {
                                PickyFullscreenSidebarRow(
                                    session: session,
                                    isSelected: selectedSessionID == session.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(session.title)
                            .accessibilityValue(session.accessibilitySummary)
                            .accessibilityHint(selectedSessionID == session.id ? "선택된 Pickle" : "Pickle 선택")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)

            Button {
                isRecentPickleFolderPickerPresented = true
            } label: {
                Label(isCreatingPickle ? "Pickle 생성 중…" : "새 Pickle", systemImage: "plus")
                    .pickyFont(size: 13, weight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isCreatingPickle)
            .recentPickleFolderPicker(
                isPresented: $isRecentPickleFolderPickerPresented,
                arrowEdge: .leading,
                recentPickleCwds: recentPickleCwds,
                onCreatePickleInRecentFolder: onCreatePickleInRecentFolder,
                onChooseFolder: onChoosePickleFolder,
                onRemoveRecentPickleFolder: onRemoveRecentPickleFolder
            )
            .help("최근 폴더에서 Pickle을 시작하거나 작업 폴더를 선택합니다.")
            .accessibilityLabel("새 Pickle")
            .accessibilityHint("최근 작업 폴더를 선택하거나 새 폴더를 찾습니다")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(minWidth: 236, idealWidth: 276, maxWidth: 296, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pickle 사이드바")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pickle 목록")
                .pickyFont(size: 16, weight: .semibold)
            Text("활성 \(sessions.count)개")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "tray")
                .pickyFont(size: 18, weight: .medium)
                .foregroundStyle(.secondary)
            Text("활성 Pickle 없음")
                .pickyFont(size: 13, weight: .semibold)
            Text("새 Pickle을 시작하세요.")
                .pickyFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("활성 Pickle 없음")
        .accessibilityHint("새 Pickle을 시작하세요")
    }
}

private struct PickyFullscreenSidebarRow: View {
    let session: PickySessionListViewModel.SessionCard
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                statusDot
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .pickyFont(size: 13.5, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let cwd = session.compactCwdDescription {
                        Text(cwd)
                            .pickyFont(size: 11.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text(session.status.fullscreenDisplayText)
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundStyle(session.status.fullscreenForegroundStyle)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text("\(session.elapsedSinceUpdate()) 전 업데이트")
                    .pickyFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(session.status.fullscreenStatusColor)
            .frame(width: 8, height: 8)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.58))
    }
}

private extension PickySessionListViewModel.SessionCard {
    var accessibilitySummary: String {
        var parts = [status.fullscreenDisplayText]
        if let cwd = compactCwdDescription {
            parts.append(cwd)
        }
        parts.append("\(elapsedSinceUpdate()) 전 업데이트")
        return parts.joined(separator: ", ")
    }
}

private extension PickySessionStatus {
    var fullscreenDisplayText: String {
        switch self {
        case .queued: "대기 중"
        case .running: "실행 중"
        case .waiting_for_input: "입력 대기"
        case .blocked: "차단됨"
        case .completed: "완료"
        case .failed: "실패"
        case .cancelled: "취소됨"
        }
    }

    var fullscreenStatusColor: Color {
        switch self {
        case .running: .blue
        case .queued: .orange
        case .waiting_for_input: .purple
        case .blocked, .failed: .red
        case .completed: .green
        case .cancelled: .gray
        }
    }

    var fullscreenForegroundStyle: Color {
        switch self {
        case .blocked, .failed: .red
        case .completed: .green
        case .running: .blue
        case .queued: .orange
        case .waiting_for_input: .purple
        case .cancelled: .secondary
        }
    }
}

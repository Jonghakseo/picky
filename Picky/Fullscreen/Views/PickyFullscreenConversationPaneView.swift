//
//  PickyFullscreenConversationPaneView.swift
//  Picky
//
//  Center pane for fullscreen's focused LLM chat UI.
//

import AppKit
import SwiftUI

struct PickyFullscreenConversationPaneView: View {
    let session: PickySessionListViewModel.SessionCard?
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var droppedFilePathsBySessionID: [String: [String]] = [:]
    @State private var isFileDropTargeted = false
    @State private var extendedTerminalOpenSessionIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                GeometryReader { proxy in
                    conversationContent(for: session)
                        .environment(\.pickyHUDDetailWidth, Self.responsiveConversationDetailWidth(forColumnWidth: proxy.size.width))
                        .onDrop(
                            of: PickyConversationFileDrop.acceptedTypeIdentifiers,
                            isTargeted: $isFileDropTargeted,
                            perform: { handleFileDrop($0, sessionID: session.id) }
                        )
                }
            } else {
                noSelectionView
            }
        }
        .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("대화")
    }

    private func conversationContent(for session: PickySessionListViewModel.SessionCard) -> some View {
        VStack(spacing: 0) {
            PickyFullscreenConversationListView(session: session, viewModel: viewModel)
                .padding(.trailing, Self.conversationDividerClearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isExtendedTerminalOpen(sessionID: session.id) {
                Divider()
                PickySessionExtendedTerminalView(session: session, viewModel: viewModel)
                    .transition(.opacity)
            }

            Divider()
            PickyConversationComposerView(
                session: session,
                viewModel: viewModel,
                droppedFilePaths: droppedFilePathsBinding(for: session.id),
                isFileDropTargeted: isFileDropTargeted,
                isExtendedTerminalOpen: isExtendedTerminalOpen(sessionID: session.id),
                copyStyle: .fullscreenKorean,
                onToggleExtendedTerminal: { toggleExtendedTerminal(sessionID: session.id) }
            )
            .id(session.id)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func droppedFilePathsBinding(for sessionID: String) -> Binding<[String]> {
        Binding(
            get: { droppedFilePathsBySessionID[sessionID, default: []] },
            set: { paths in
                if paths.isEmpty {
                    droppedFilePathsBySessionID.removeValue(forKey: sessionID)
                } else {
                    droppedFilePathsBySessionID[sessionID] = paths
                }
            }
        )
    }

    private func handleFileDrop(_ providers: [NSItemProvider], sessionID: String) -> Bool {
        let fileProviders = providers.filter(PickyConversationFileDrop.acceptsDrop)
        guard !fileProviders.isEmpty else { return false }

        Task {
            let paths = await PickyConversationFileDrop.filePaths(from: fileProviders)
            guard !paths.isEmpty else { return }
            await MainActor.run {
                droppedFilePathsBySessionID[sessionID, default: []].append(contentsOf: paths)
            }
        }
        return true
    }

    private func isExtendedTerminalOpen(sessionID: String) -> Bool {
        extendedTerminalOpenSessionIDs.contains(sessionID)
            && !(viewModel.isInlineTerminalMode(sessionID: sessionID))
    }

    private func toggleExtendedTerminal(sessionID: String) {
        if extendedTerminalOpenSessionIDs.contains(sessionID) {
            extendedTerminalOpenSessionIDs.remove(sessionID)
        } else {
            extendedTerminalOpenSessionIDs.insert(sessionID)
            viewModel.markSessionRead(sessionID: sessionID)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session?.title ?? "대화")
                    .pickyFont(size: 18, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let session {
                        statusPill(for: session.status)
                        if let runText = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(for: session)?.displayText {
                            Text(runText)
                                .pickyFont(size: 12, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Pickle을 선택하면 대화를 볼 수 있습니다.")
                            .pickyFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var noSelectionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .pickyFont(size: 30, weight: .medium)
                .foregroundStyle(.secondary)
            Text("Pickle을 선택하세요")
                .pickyFont(size: 16, weight: .semibold)
            Text("사이드바에서 Pickle을 선택하면 대화를 볼 수 있습니다.")
                .pickyFont(size: 13)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pickle을 선택하세요")
        .accessibilityHint("사이드바에서 Pickle을 선택하면 대화를 볼 수 있습니다")
    }

    private func statusPill(for status: PickySessionStatus) -> some View {
        Text(status.fullscreenConversationDisplayText)
            .pickyFont(size: 11, weight: .semibold)
            .foregroundStyle(status.fullscreenConversationColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(status.fullscreenConversationColor.opacity(0.12)))
            .overlay(Capsule().stroke(status.fullscreenConversationColor.opacity(0.28), lineWidth: 0.6))
            .accessibilityLabel("상태")
            .accessibilityValue(status.fullscreenConversationDisplayText)
    }

    static func responsiveConversationDetailWidth(forColumnWidth columnWidth: CGFloat) -> CGFloat {
        let availableWidth = columnWidth
            - conversationListInnerHorizontalPadding
            - conversationDividerClearance
            - conversationUserBubbleOppositeReserve
        return min(conversationDetailWidthMax, max(conversationDetailWidthMin, availableWidth))
    }

    static let conversationDividerClearance: CGFloat = 24
    static let conversationListInnerHorizontalPadding: CGFloat = 48
    static let conversationUserBubbleOppositeReserve: CGFloat = PickyConversationBubbleLayout.oppositeSideReserve
    private static let conversationDetailWidthMin: CGFloat = 260
    private static let conversationDetailWidthMax: CGFloat = 760
}

private extension PickySessionStatus {
    var fullscreenConversationDisplayText: String {
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

    var fullscreenConversationColor: Color {
        switch self {
        case .running: .blue
        case .queued: .orange
        case .waiting_for_input: .purple
        case .blocked, .failed: .red
        case .completed: .green
        case .cancelled: .gray
        }
    }
}

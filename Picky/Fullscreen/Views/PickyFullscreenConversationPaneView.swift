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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session?.title ?? "대화")
                    .pickyFont(size: 18, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let session {
                        statusPill(for: session.status)
                        if let cwd = session.compactCwdDescription {
                            Text(cwd)
                                .pickyFont(size: 12, weight: .medium, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("Pickle을 선택하면 대화를 볼 수 있습니다.")
                            .pickyFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if let session {
                PickyFullscreenHeaderMetaChips(session: session)
            }
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

private struct PickyFullscreenHeaderMetaChips: View {
    let session: PickySessionListViewModel.SessionCard

    var body: some View {
        HStack(spacing: 8) {
            if let runText = assistantRun?.displayText {
                Text(runText)
                    .pickyFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.6))
                    .accessibilityLabel("모델과 사고 수준")
                    .accessibilityValue(runText)
            }

            if let usage = session.contextUsage {
                PickyFullscreenContextUsageChip(display: .init(usage: usage))
            }
        }
    }

    private var assistantRun: PickyAssistantRunMetadata? {
        PickyFullscreenAssistantRunResolver.effectiveAssistantRun(for: session)
    }
}

private struct PickyFullscreenContextUsageChip: View {
    let display: PickyFullscreenContextUsageDisplay

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    if display.isKnown {
                        Capsule()
                            .fill(display.color)
                            .frame(width: geometry.size.width * CGFloat(max(0, min(1, display.fraction))))
                    }
                }
                .overlay(
                    Capsule()
                        .stroke(display.color.opacity(display.isKnown ? 0.42 : 0.28), style: StrokeStyle(lineWidth: 0.6, dash: display.isKnown ? [] : [2, 2]))
                )
            }
            .frame(width: 28, height: 5)

            Text("ctx \(display.label)")
                .pickyFont(size: 12, weight: .semibold, design: .monospaced)
                .foregroundStyle(display.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(display.color.opacity(0.10)))
        .overlay(Capsule().stroke(display.color.opacity(0.20), lineWidth: 0.6))
        .help(display.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("컨텍스트 사용량")
        .accessibilityValue(display.accessibilityValue)
    }
}

private struct PickyFullscreenContextUsageDisplay {
    let fraction: Double
    let label: String
    let color: Color
    let tooltip: String
    let isKnown: Bool

    init(usage: PickyContextUsage) {
        guard let percent = usage.percent else {
            self.fraction = 0
            self.label = "?%"
            self.color = .secondary
            self.tooltip = "Context usage unknown after compaction until the next model response"
            self.isKnown = false
            return
        }

        let clamped = max(0, min(100, percent))
        self.fraction = clamped / 100
        self.label = "\(Int(clamped.rounded()))%"
        switch clamped {
        case 90...:
            self.color = .red
        case 70..<90:
            self.color = .orange
        default:
            self.color = .green
        }
        if let tokens = usage.tokens {
            self.tooltip = "Context usage: \(tokens.formatted())/\(usage.contextWindow.formatted()) tokens (\(Int(clamped.rounded()))%)"
        } else {
            self.tooltip = "Context usage: \(Int(clamped.rounded()))% of \(usage.contextWindow.formatted()) tokens"
        }
        self.isKnown = true
    }

    var accessibilityValue: String {
        isKnown ? label : "알 수 없음"
    }
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

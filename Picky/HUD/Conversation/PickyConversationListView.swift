//
//  PickyConversationListView.swift
//  Picky
//
//  Message list for the conversation-style side-agent card.
//

import SwiftUI

struct PickyConversationListView: View {
    let session: PickySessionListViewModel.SessionCard

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.messages.isEmpty {
                        Color.clear
                            .frame(height: 24)
                    } else {
                        ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowSeparator(before: index) {
                                PickyConversationTimeSeparatorView(text: separatorText(before: index))
                            }
                            messageView(message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)
            .onAppear { scrollToLatest(proxy: proxy) }
            .onChange(of: session.messages.last?.id) { _, _ in
                scrollToLatest(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: PickySessionMessage) -> some View {
        switch message.kind {
        case .userText:
            PickyUserBubbleView(message: message)
        case .agentText:
            PickyAgentBubbleView(message: message)
        case .agentThinking:
            PickyTypingBubbleView(message: message)
        case .agentQuestion, .agentReport, .agentError, .system:
            PickyAgentBubbleView(message: message)
        }
    }

    private func shouldShowSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = session.messages[index - 1].createdAt
        let current = session.messages[index].createdAt
        return current.timeIntervalSince(previous) >= 60
    }

    private func separatorText(before index: Int) -> String {
        guard index > 0 else { return "now" }
        let previous = session.messages[index - 1].createdAt
        let current = session.messages[index].createdAt
        return elapsedText(seconds: max(0, Int(current.timeIntervalSince(previous))))
    }

    private func elapsedText(seconds: Int) -> String {
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m later" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m later"
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let latestID = session.messages.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(latestID, anchor: .bottom)
            }
        }
    }
}

private struct PickyConversationTimeSeparatorView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.55)).frame(height: 0.5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.55)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}

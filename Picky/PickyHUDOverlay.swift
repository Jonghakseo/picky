//
//  PickyHUDOverlay.swift
//  Picky
//
//  Minimal top-right long-running session HUD.
//

import AppKit
import SwiftUI

@MainActor
final class PickyHUDOverlayManager {
    private let viewModel: PickySessionListViewModel
    private var panel: NSPanel?
    private let width: CGFloat = 380
    private let collapsedHeight: CGFloat = 220

    init(viewModel: PickySessionListViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        viewModel.start()
        createPanelIfNeeded()
        positionTopRight()
        panel?.orderFrontRegardless()
    }

    func stop() {
        viewModel.stop()
        panel?.orderOut(nil)
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }
        let hudPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hudPanel.level = .statusBar
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = false
        hudPanel.hidesOnDeactivate = false
        hudPanel.isExcludedFromWindowsMenu = true
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostingView = NSHostingView(rootView: PickyHUDView(viewModel: viewModel).frame(width: width))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: collapsedHeight)
        hudPanel.contentView = hostingView
        panel = hudPanel
    }

    private func positionTopRight() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: width, height: collapsedHeight)
        let height = min(max(fittingSize.height, 96), visibleFrame.height - 32)
        let origin = CGPoint(x: visibleFrame.maxX - width - 16, y: visibleFrame.maxY - height - 16)
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }
}

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var expandedSessionID: String?

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(6))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if visibleSessions.isEmpty {
                EmptyView()
            } else {
                ForEach(visibleSessions) { session in
                    VStack(spacing: 8) {
                        PickySessionCardView(session: session, isExpanded: expandedSessionID == session.id)
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedSessionID = expandedSessionID == session.id ? nil : session.id
                                }
                            }
                        if expandedSessionID == session.id {
                            PickySessionDetailView(session: session, viewModel: viewModel)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
    }
}

private struct PickySessionCardView: View {
    let session: PickySessionListViewModel.SessionCard
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if session.status == .queued || session.status == .running {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.45)
                            .frame(width: 10, height: 10)
                    }
                    Text(session.status.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(statusColor)
                }

                HStack(spacing: 8) {
                    Text(shortCwd(session.cwd))
                    Text(session.elapsedDescription())
                    Text("\(session.toolCount) tools")
                }
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

                if !session.lastSummary.isEmpty {
                    Text(session.lastSummary)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 8)
        )
    }

    private var statusColor: Color {
        switch session.status {
        case .queued: DS.Colors.textTertiary
        case .running: DS.Colors.accentText
        case .waiting_for_input: DS.Colors.warning
        case .blocked: DS.Colors.warningText
        case .completed: DS.Colors.success
        case .failed: DS.Colors.destructiveText
        case .cancelled: DS.Colors.textTertiary
        }
    }
}

private struct PickySessionDetailView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var followUpText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pending = session.pendingExtensionUiRequest {
                PickyPendingInputView(request: pending, viewModel: viewModel)
            }

            if !session.lastSummary.isEmpty {
                detailSection(title: "Summary", text: session.lastSummary)
            }

            if !session.logPreview.isEmpty {
                detailSection(title: "Recent log", text: session.logPreview)
            }

            if !session.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Changed files")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    ForEach(session.changedFiles.prefix(4), id: \.path) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(file.status) · \(file.path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                            if let summary = file.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            let diffArtifacts = session.artifacts.filter { $0.kind == "diff" }
            if !diffArtifacts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diff preview")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    ForEach(diffArtifacts.prefix(2)) { artifact in
                        Text(artifact.title)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            if !session.prArtifacts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.prArtifacts) { artifact in
                        Text(artifact.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accentSubtle))
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Follow up…", text: $followUpText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitFollowUp() }
                Button("Send") { submitFollowUp() }
                    .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                Button("Open report") { Task { try? await viewModel.openReport(sessionID: session.id) } }
                    .disabled(session.reportArtifact == nil)
                Button("Debug") { viewModel.openTerminalDebug(sessionID: session.id) }
                Button("Follow up") { viewModel.select(sessionID: session.id) }
                Button("Stop") { Task { try? await viewModel.abort(sessionID: session.id) } }
                    .disabled(session.status.isTerminal)
                Button("Copy") { viewModel.copySummary(sessionID: session.id) }
                Button("Archive") { viewModel.archive(sessionID: session.id) }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 1))
        )
    }

    private func submitFollowUp() {
        let text = followUpText
        followUpText = ""
        Task { try? await viewModel.followUp(text: text, sessionID: session.id) }
    }

    private func detailSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(3)
        }
    }
}

private struct PickyPendingInputView: View {
    let request: PickyExtensionUiRequest
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var textValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for input")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.warning)
            Text(request.prompt ?? request.title ?? request.method)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(3)
            controls
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(DS.Colors.warning.opacity(0.12)))
    }

    @ViewBuilder
    private var controls: some View {
        switch request.method {
        case "confirm":
            HStack(spacing: 6) {
                Button("Allow") { answer(.bool(true)) }
                Button("Cancel") { cancel() }
            }
            .font(.system(size: 11, weight: .medium))
        case "select":
            let options = request.options ?? []
            if options.isEmpty {
                Button("Cancel") { cancel() }
                    .font(.system(size: 11, weight: .medium))
            } else {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { answer(.string(option)) }
                    }
                    Button("Cancel") { cancel() }
                }
                .font(.system(size: 11, weight: .medium))
            }
        case "input", "editor":
            HStack(spacing: 6) {
                TextField("Response…", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitText() }
                Button("Submit") { submitText() }
                    .disabled(textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { cancel() }
            }
            .font(.system(size: 11, weight: .medium))
        default:
            Button("Dismiss") { cancel() }
                .font(.system(size: 11, weight: .medium))
        }
    }

    private func submitText() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer(.string(trimmed))
    }

    private func answer(_ value: JSONValue) {
        Task { try? await viewModel.answerExtensionUi(sessionID: request.sessionId, requestID: request.id, value: value) }
    }

    private func cancel() {
        Task { try? await viewModel.cancelExtensionUi(sessionID: request.sessionId, requestID: request.id) }
    }
}

struct PickyToolActivityRow: View {
    let tool: PickyToolActivity

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                    if tool.riskLevel != .normal {
                        Text(riskLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(tool.riskLevel == .external ? DS.Colors.warning : DS.Colors.info)
                    }
                    Spacer()
                    Text(tool.status)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                if let preview = tool.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2.opacity(0.72)))
    }

    private var statusColor: Color {
        if tool.didFail { return DS.Colors.destructiveText }
        if tool.isActive { return DS.Colors.accentText }
        return DS.Colors.success
    }

    private var riskLabel: String {
        switch tool.riskLevel {
        case .normal: ""
        case .elevated: "local tool"
        case .external: "external"
        }
    }
}

private func shortCwd(_ cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "no cwd" }
    let url = URL(fileURLWithPath: cwd)
    let last = url.lastPathComponent
    return last.isEmpty ? cwd : last
}

#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}

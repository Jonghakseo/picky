//
//  PickyHUDOverlay.swift
//  Picky
//
//  Minimal top-right long-running session HUD.
//

import AppKit
import SwiftUI

enum PickyHUDExpansion {
    static let duration: TimeInterval = 0.22
    static let panelShrinkDelay: TimeInterval = duration + 0.03
    static let animation = Animation.easeInOut(duration: duration)

    static func cardSpacing(isExpanded: Bool) -> CGFloat {
        isExpanded ? 9 : 0
    }

    static func cardVerticalPadding(isExpanded: Bool) -> CGFloat {
        8
    }

    static func contentFrameHeight(isExpanded: Bool, measuredHeight: CGFloat) -> CGFloat? {
        guard isExpanded else { return 0 }
        return measuredHeight > 0 ? measuredHeight : nil
    }

    static let anchorsContentToPanelTopDuringDeferredShrink = true

    static func shouldDeferPanelShrink(currentHeight: CGFloat, targetHeight: CGFloat, deferShrink: Bool) -> Bool {
        deferShrink && targetHeight < currentHeight - 1
    }
}

enum PickyHUDExpandedContentPolicy {
    static let showsRecentLog = false
    static let summaryLineLimit: Int? = nil

    static func showsSummary(for status: PickySessionStatus) -> Bool {
        switch status {
        case .queued, .running, .waiting_for_input:
            return false
        case .blocked, .completed, .failed, .cancelled:
            return true
        }
    }
}

final class PickyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

@MainActor
final class PickyHUDOverlayManager {
    private let viewModel: PickySessionListViewModel
    private var panel: NSPanel?
    private var pendingPanelShrinkTask: Task<Void, Never>?
    private let width: CGFloat = 320
    private let collapsedHeight: CGFloat = 180
    private let minimumHeight: CGFloat = 48

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
        pendingPanelShrinkTask?.cancel()
        pendingPanelShrinkTask = nil
        viewModel.stop()
        panel?.orderOut(nil)
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }
        let hudPanel = PickyHUDPanel(
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

        let hostingView = NSHostingView(rootView: PickyHUDView(viewModel: viewModel) { [weak self] size in
            // SwiftUI animates the card reveal itself. Grow the transparent NSPanel
            // immediately, but defer shrinking it until the collapse animation has
            // finished so shadows/content aren't clipped by the outer container.
            self?.resizePanel(toContentSize: size, deferShrink: true)
        }.frame(width: width))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: collapsedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hudPanel.contentView = hostingView
        panel = hudPanel
    }

    private func positionTopRight() {
        resizePanel(toContentSize: panel?.contentView?.fittingSize ?? CGSize(width: width, height: collapsedHeight), deferShrink: false)
    }

    private func resizePanel(toContentSize contentSize: CGSize, deferShrink: Bool) {
        guard let panel else { return }
        guard let targetFrame = targetFrame(forContentSize: contentSize) else { return }
        let shouldDeferShrink = PickyHUDExpansion.shouldDeferPanelShrink(
            currentHeight: panel.frame.height,
            targetHeight: targetFrame.height,
            deferShrink: deferShrink
        )

        if shouldDeferShrink {
            pendingPanelShrinkTask?.cancel()
            pendingPanelShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(PickyHUDExpansion.panelShrinkDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.pendingPanelShrinkTask = nil
                self.resizePanel(toContentSize: contentSize, deferShrink: false)
            }
            return
        }

        pendingPanelShrinkTask?.cancel()
        pendingPanelShrinkTask = nil
        applyPanelFrame(targetFrame)
    }

    private func targetFrame(forContentSize contentSize: CGSize) -> NSRect? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return nil }
        let targetHeight = min(max(contentSize.height, minimumHeight), visibleFrame.height - 32)
        return NSRect(
            x: visibleFrame.maxX - width - 16,
            y: visibleFrame.maxY - targetHeight - 16,
            width: width,
            height: targetHeight
        )
    }

    private func applyPanelFrame(_ targetFrame: NSRect) {
        guard let panel, panel.frame.integral != targetFrame.integral else { return }
        panel.setFrame(targetFrame, display: true)
    }
}

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var onSizeChange: (CGSize) -> Void = { _ in }
    @State private var expandedSessionID: String?

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(6))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if visibleSessions.isEmpty {
                EmptyView()
            } else {
                ForEach(visibleSessions) { session in
                    PickySessionCardView(
                        session: session,
                        isExpanded: expandedSessionID == session.id,
                        viewModel: viewModel,
                        onToggle: {
                            expandedSessionID = expandedSessionID == session.id ? nil : session.id
                        }
                    )
                }
            }
        }
        .padding(8)
        .background(PickyHUDSizeReader())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: onSizeChange)
    }
}

private struct PickyHUDSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct PickyHUDSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PickyHUDSizePreferenceKey.self, value: proxy.size)
        }
    }
}

private struct PickyHUDCollapsibleContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct PickyHUDCollapsibleContent<Content: View>: View {
    let isExpanded: Bool
    private let content: Content
    @State private var measuredHeight: CGFloat = 0

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PickyHUDCollapsibleContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .frame(
                height: PickyHUDExpansion.contentFrameHeight(
                    isExpanded: isExpanded,
                    measuredHeight: measuredHeight
                ),
                alignment: .top
            )
            .opacity(isExpanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(PickyHUDExpansion.animation, value: isExpanded)
            .onPreferenceChange(PickyHUDCollapsibleContentHeightPreferenceKey.self) { height in
                measuredHeight = height
            }
    }
}

private struct PickySessionCardView: View {
    let session: PickySessionListViewModel.SessionCard
    let isExpanded: Bool
    @ObservedObject var viewModel: PickySessionListViewModel
    let onToggle: () -> Void
    @State private var followUpText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHUDExpansion.cardSpacing(isExpanded: isExpanded)) {
            header
            PickyHUDCollapsibleContent(isExpanded: isExpanded) {
                expandedContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, PickyHUDExpansion.cardVerticalPadding(isExpanded: isExpanded))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 7)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(session.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(PickyHUDExpansion.animation, value: isExpanded)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.35)

            if let cwd = session.cwd, !cwd.isEmpty {
                metaRow(icon: "folder", text: "CWD  \(cwd)")
            }
            metaRow(icon: "clock", text: session.elapsedDescription())

            if let pending = session.pendingExtensionUiRequest {
                PickyPendingInputView(request: pending, viewModel: viewModel)
            }

            if PickyHUDExpandedContentPolicy.showsSummary(for: session.status), !session.lastSummary.isEmpty {
                detailSection(
                    title: "Summary",
                    text: session.lastSummary,
                    lineLimit: PickyHUDExpandedContentPolicy.summaryLineLimit
                )
            }

            if PickyHUDExpandedContentPolicy.showsRecentLog, !session.logPreview.isEmpty {
                detailSection(title: "Recent log", text: session.logPreview)
            }

            if !session.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    detailTitle("Changed files")
                    ForEach(session.changedFiles.prefix(4), id: \.path) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(file.status) · \(file.path)")
                                .font(.system(size: 10.5, design: .monospaced))
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
                    detailTitle("Diff preview")
                    ForEach(diffArtifacts.prefix(2)) { artifact in
                        Text(artifact.title)
                            .font(.system(size: 10.5, design: .monospaced))
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
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DS.Colors.accentSubtle))
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Follow up…", text: $followUpText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitFollowUp() }
                iconButton(
                    systemName: "paperplane.fill",
                    help: "Send follow-up",
                    disabled: followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submitFollowUp
                )
            }

            HStack(spacing: 10) {
                iconButton(systemName: "doc.text.magnifyingglass", help: "Open report", disabled: session.reportArtifact == nil) {
                    Task { try? await viewModel.openReport(sessionID: session.id) }
                }
                iconButton(systemName: "terminal", help: "Resume in Ghostty", disabled: session.piSessionFilePath == nil || session.status == .running) {
                    viewModel.resumeInGhostty(sessionID: session.id)
                }
                iconButton(systemName: "text.bubble", help: "Use this session for voice follow-up") {
                    viewModel.select(sessionID: session.id)
                }
                iconButton(systemName: "stop.circle", help: "Stop session", disabled: session.status.isTerminal) {
                    Task { try? await viewModel.abort(sessionID: session.id) }
                }
                iconButton(systemName: "doc.on.doc", help: "Copy summary") {
                    viewModel.copySummary(sessionID: session.id)
                }
                iconButton(systemName: "archivebox", help: "Archive session") {
                    viewModel.archive(sessionID: session.id)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func submitFollowUp() {
        let text = followUpText
        followUpText = ""
        Task { try? await viewModel.followUp(text: text, sessionID: session.id) }
    }

    private func metaRow(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 12)
            Text(text)
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
        .foregroundColor(DS.Colors.textTertiary)
    }

    private func detailSection(title: String, text: String, lineLimit: Int? = 3) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            detailTitle(title)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(lineLimit)
        }
    }

    private func detailTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func iconButton(systemName: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.textSecondary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(help)
    }

    private var statusColor: Color {
        switch session.status.hudTone {
        case .inProgress: DS.Colors.warning
        case .error: DS.Colors.destructiveText
        case .completed: DS.Colors.success
        case .other: DS.Colors.accentText
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

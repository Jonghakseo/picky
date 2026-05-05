//
//  PickyHUDView.swift
//  Picky
//
//  SwiftUI composition for the long-running session HUD.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let pickyPointAtHUDDockSession = Notification.Name("pickyPointAtHUDDockSession")
}

struct PickyHUDDockPointerTarget: Equatable {
    let sessionID: String
    let title: String
    let screenFrame: CGRect
    let label: String
    let duration: TimeInterval

    var screenLocation: CGPoint {
        CGPoint(x: screenFrame.midX, y: screenFrame.midY)
    }
}

enum PickyHUDDockPointerTargetNotification {
    private static let sessionIDKey = "sessionID"
    private static let titleKey = "title"
    private static let screenFrameKey = "screenFrame"
    private static let labelKey = "label"
    private static let durationKey = "duration"
    private static let defaultDuration: TimeInterval = 2.8

    static func userInfo(sessionID: String, title: String, screenFrame: CGRect) -> [String: Any] {
        [
            sessionIDKey: sessionID,
            titleKey: title,
            screenFrameKey: NSValue(rect: screenFrame),
            labelKey: "New side agent: \(title)",
            durationKey: defaultDuration,
        ]
    }

    static func target(from notification: Notification) -> PickyHUDDockPointerTarget? {
        guard let userInfo = notification.userInfo,
              let sessionID = userInfo[sessionIDKey] as? String,
              let title = userInfo[titleKey] as? String,
              let frameValue = userInfo[screenFrameKey] as? NSValue else {
            return nil
        }
        let label = userInfo[labelKey] as? String ?? "New side agent: \(title)"
        let duration = userInfo[durationKey] as? TimeInterval ?? defaultDuration
        return PickyHUDDockPointerTarget(
            sessionID: sessionID,
            title: title,
            screenFrame: frameValue.rectValue,
            label: label,
            duration: duration
        )
    }
}

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var onSizeChange: (CGSize) -> Void = { _ in }
    @State private var pinnedSessionID: String?
    @State private var previewSessionID: String?
    @State private var isHUDHovered = false
    @State private var closeExpansionTask: Task<Void, Never>?
    @State private var gitSectionExpansionBySessionID: [String: Bool] = [:]
    @State private var dockIconScreenFramesBySessionID: [String: CGRect] = [:]

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(PickyHUDDockLayout.visibleSessionLimit).reversed())
    }

    private var activeSessionID: String? {
        PickyHUDDockLayout.activeSessionID(
            visibleIDs: visibleSessions.map(\.id),
            pinnedID: pinnedSessionID,
            previewID: previewSessionID
        )
    }

    private var activeSession: PickySessionListViewModel.SessionCard? {
        guard let activeSessionID else { return nil }
        return visibleSessions.first { $0.id == activeSessionID }
    }

    var body: some View {
        hudContent
            .background(PickyHUDSizeReader())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(PickyHUDExpansion.animation, value: activeSession?.id)
            .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: onSizeChange)
            .onDisappear {
                closeExpansionTask?.cancel()
                closeExpansionTask = nil
            }
    }

    private var hudContent: some View {
        HStack(alignment: .center, spacing: PickyHUDDockLayout.panelGap) {
            if let activeSession {
                PickySessionCardView(
                    session: activeSession,
                    isExpanded: true,
                    isGitSectionExpanded: gitSectionExpandedBinding(for: activeSession.id),
                    viewModel: viewModel,
                    showsDisclosure: false,
                    onToggle: { pinSession(activeSession.id) },
                    onHoverChanged: { _ in }
                )
                .id(activeSession.id)
                .frame(width: PickyHUDDockLayout.detailWidth)
                .transition(.opacity)
            }

            PickyHUDDockRailView(
                sessions: visibleSessions,
                activeSessionID: activeSession?.id,
                pinnedSessionID: pinnedSessionID,
                onHoverSession: previewDockSession,
                onPinSession: pinSession,
                onCreateSideAgent: chooseFolderForEmptySideAgent,
                onIconScreenFrameChange: recordDockIconScreenFrame
            )
            .frame(width: PickyHUDDockLayout.railWidth)
        }
        .padding(PickyHUDExpansion.outerPadding)
        .onHover(perform: handleHUDHover)
        .onChange(of: viewModel.pendingDockPointerSessionID) { _, _ in
            pointAtPendingDockSessionIfPossible()
        }
        .onChange(of: visibleSessions.map(\.id)) { _, visibleIDs in
            dockIconScreenFramesBySessionID = dockIconScreenFramesBySessionID.filter { visibleIDs.contains($0.key) }
            pointAtPendingDockSessionIfPossible()
        }
    }

    private func handleHUDHover(_ isHovering: Bool) {
        isHUDHovered = isHovering
        if isHovering {
            cancelPendingClose()
        } else {
            scheduleCloseIfNeeded()
        }
    }

    private func chooseFolderForEmptySideAgent() {
        let panel = NSOpenPanel()
        panel.title = "Choose a working folder"
        panel.prompt = "Start"
        panel.message = "Choose the folder where the new side agent should run."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { try? await viewModel.createEmptySideSession(cwd: url.path) }
        }
    }

    private func previewDockSession(_ sessionID: String) {
        isHUDHovered = true
        cancelPendingClose()
        previewSessionID = PickyHUDDockLayout.previewSessionIDAfterDockHover(
            current: previewSessionID,
            sessionID: sessionID,
            pinnedID: pinnedSessionID
        )
    }

    private func recordDockIconScreenFrame(sessionID: String, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        dockIconScreenFramesBySessionID[sessionID] = frame
        pointAtPendingDockSessionIfPossible()
    }

    private func pointAtPendingDockSessionIfPossible() {
        guard let sessionID = viewModel.pendingDockPointerSessionID else { return }
        guard let session = visibleSessions.first(where: { $0.id == sessionID }) else { return }
        guard let frame = dockIconScreenFramesBySessionID[sessionID], frame.width > 0, frame.height > 0 else { return }
        NotificationCenter.default.post(
            name: .pickyPointAtHUDDockSession,
            object: nil,
            userInfo: PickyHUDDockPointerTargetNotification.userInfo(
                sessionID: session.id,
                title: session.title,
                screenFrame: frame
            )
        )
        viewModel.markDockPointerDelivered(sessionID: sessionID)
    }

    private func gitSectionExpandedBinding(for sessionID: String) -> Binding<Bool> {
        Binding(
            get: {
                PickyHUDDockLayout.gitSectionExpansion(
                    sessionID: sessionID,
                    storedValues: gitSectionExpansionBySessionID
                )
            },
            set: { isExpanded in
                gitSectionExpansionBySessionID = PickyHUDDockLayout.gitSectionExpansionValues(
                    gitSectionExpansionBySessionID,
                    setting: isExpanded,
                    for: sessionID
                )
            }
        )
    }

    private func pinSession(_ sessionID: String) {
        cancelPendingClose()
        pinnedSessionID = PickyHUDDockLayout.pinnedSessionIDAfterClick(current: pinnedSessionID, clicked: sessionID)
        previewSessionID = pinnedSessionID == nil && isHUDHovered ? sessionID : nil
        if pinnedSessionID == nil && !isHUDHovered {
            scheduleCloseIfNeeded()
        }
    }

    private func scheduleCloseIfNeeded() {
        guard pinnedSessionID == nil else { return }
        closeExpansionTask?.cancel()
        closeExpansionTask = Task {
            do {
                try await Task.sleep(nanoseconds: PickyHUDDockLayout.closeDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewSessionID = PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(
                    current: previewSessionID,
                    pinnedID: pinnedSessionID,
                    isHUDHovered: isHUDHovered
                )
                closeExpansionTask = nil
            }
        }
    }

    private func cancelPendingClose() {
        closeExpansionTask?.cancel()
        closeExpansionTask = nil
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

private struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let activeSessionID: String?
    let pinnedSessionID: String?
    let onHoverSession: (String) -> Void
    let onPinSession: (String) -> Void
    let onCreateSideAgent: () -> Void
    let onIconScreenFrameChange: (String, CGRect) -> Void

    @State private var isAddSlotExpanded = false

    @ViewBuilder
    var body: some View {
        if sessions.isEmpty {
            addAgentSlotButton
        } else {
            VStack(spacing: 6) {
                VStack(spacing: 9) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        PickyHUDDockIconView(
                            session: session,
                            index: index,
                            isActive: activeSessionID == session.id,
                            isPinned: pinnedSessionID == session.id,
                            onHover: { onHoverSession(session.id) },
                            onPin: { onPinSession(session.id) },
                            onScreenFrameChange: { frame in onIconScreenFrameChange(session.id, frame) }
                        )
                    }
                }

                collapsibleAddAgentSlot
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(dockGlassBackground)
        }
    }

    /// Frosted-glass capsule that hosts the dock icons. Uses .ultraThinMaterial
    /// so the desktop / app underneath actually shows through, then layers a
    /// gradient stroke (bright top, dimmer bottom) for the macOS-style top
    /// gloss, and an ambient shadow so the dock no longer disappears against
    /// light backgrounds.
    private var dockGlassBackground: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
            )
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.10), radius: 3, x: 0, y: 1)
    }

    private var addAgentSlotButton: some View {
        Button(action: onCreateSideAgent) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        DS.Colors.textTertiary.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Start side agent")
        .accessibilityHint("Choose a working folder and start an empty side agent")
    }

    private var collapsibleAddAgentSlot: some View {
        Button(action: onCreateSideAgent) {
            ZStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            DS.Colors.textTertiary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(width: 36, height: 36)
                .opacity(isAddSlotExpanded ? 1 : 0)

                Capsule(style: .continuous)
                    .fill(DS.Colors.textTertiary.opacity(0.45))
                    .frame(width: 18, height: 1)
                    .opacity(isAddSlotExpanded ? 0 : 1)
            }
            .frame(width: 36, height: isAddSlotExpanded ? 36 : 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(PickyHUDExpansion.animation) {
                isAddSlotExpanded = hovering
            }
        }
        .accessibilityLabel("Start side agent")
        .accessibilityHint("Choose a working folder and start an empty side agent")
    }
}

private struct PickyHUDDockIconView: View {
    let session: PickySessionListViewModel.SessionCard
    let index: Int
    let isActive: Bool
    let isPinned: Bool
    let onHover: () -> Void
    let onPin: () -> Void
    let onScreenFrameChange: (CGRect) -> Void

    var body: some View {
        Button(action: onPin) {
            ZStack {
                dockIconBackground
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            }
            .frame(width: 36, height: 36)
            .background(PickyHUDDockIconScreenFrameReporter(onFrameChange: onScreenFrameChange))
            .overlay(alignment: .topTrailing) {
                statusDot.offset(x: -1.3, y: 1.3)
            }
            .overlay(alignment: .bottomTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(DS.Colors.surface1.opacity(0.96)))
                        .offset(x: 5, y: 5)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { onHover() }
        }
        .accessibilityLabel("Preview \(session.title)")
        .accessibilityHint("Click to pin this side agent")
    }

    private var dockIconBackground: some View {
        // Glass icon: ultraThinMaterial base + (active) status-tinted glaze +
        // (inactive) faint white film. The stroke is a top-bright / status-tinted
        // bottom gradient so the icon reads as a small piece of glass on the
        // bigger glass capsule rather than a flat fill.
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(statusColor.opacity(isActive ? 0.22 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.0 : 0.04))
            )
            .overlay {
                if usesAnimatedStatusBorder {
                    PickyHUDAnimatedStatusBorderView(
                        baseColor: statusColor,
                        highlightColor: statusLoadingHighlightColor,
                        duration: statusBorderAnimationDuration,
                        cornerRadius: 18
                    )
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            isActive ? statusColor.opacity(0.55) : statusColor.opacity(0.30),
                            lineWidth: isActive ? 1.0 : 0.7
                        )
                }
            }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(DS.Colors.surface1.opacity(0.94), lineWidth: 2))
            .accessibilityHidden(true)
    }

    private var usesAnimatedStatusBorder: Bool {
        session.status == .queued || session.status == .running
    }

    private var statusBorderAnimationDuration: Double {
        session.status == .running ? 2.4 : 4.2
    }

    private var statusLoadingHighlightColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .queued:
            return DS.Colors.floatingGradientPurple
        default:
            return statusColor
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return DS.Colors.accentText
        case .running:
            return DS.Colors.overlayCursorBlue
        case .waiting_for_input:
            return DS.Colors.warning
        case .blocked:
            return DS.Colors.warningText
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }
}

private struct PickyHUDDockIconScreenFrameReporter: NSViewRepresentable {
    let onFrameChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.onFrameChange = onFrameChange
        view.scheduleReport()
    }

    final class ReportingView: NSView {
        var onFrameChange: ((CGRect) -> Void)?
        private var lastReportedFrame = CGRect.null
        private var reportScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReport()
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.reportFrameIfNeeded()
            }
        }

        private func reportFrameIfNeeded() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let frameInWindow = convert(bounds, to: nil)
            let screenFrame = window.convertToScreen(frameInWindow)
            guard screenFrame.width > 0, screenFrame.height > 0 else { return }
            guard !screenFrame.isApproximatelyEqual(to: lastReportedFrame) else { return }
            lastReportedFrame = screenFrame
            onFrameChange?(screenFrame)
        }
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}

private struct PickySessionCardView: View {
    let session: PickySessionListViewModel.SessionCard
    let isExpanded: Bool
    @ObservedObject var viewModel: PickySessionListViewModel
    let showsDisclosure: Bool
    let onToggle: () -> Void
    let onHoverChanged: (Bool) -> Void
    @State private var followUpText = ""
    @State private var selectedSlashCommandIndex = 0
    @State private var isSlashCommandAutocompleteDismissed = false
    @State private var gitStatus: PickyGitRepositoryStatus?
    @Binding private var isGitSectionExpanded: Bool

    init(
        session: PickySessionListViewModel.SessionCard,
        isExpanded: Bool,
        isGitSectionExpanded: Binding<Bool>,
        viewModel: PickySessionListViewModel,
        showsDisclosure: Bool,
        onToggle: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.isExpanded = isExpanded
        _isGitSectionExpanded = isGitSectionExpanded
        self.viewModel = viewModel
        self.showsDisclosure = showsDisclosure
        self.onToggle = onToggle
        self.onHoverChanged = onHoverChanged
        _gitStatus = State(initialValue: PickyGitRepositoryStatus.cached(cwd: session.cwd))
    }

    private var isVoiceFollowUpTarget: Bool {
        if let activeVoiceFollowUpSessionID = viewModel.activeVoiceFollowUpSessionID {
            return activeVoiceFollowUpSessionID == session.id
        }
        return viewModel.hoveredVoiceFollowUpSessionID == session.id
    }

    private var gitStatusRefreshKey: String {
        "\(session.cwd ?? "")|\(session.updatedAt.timeIntervalSince1970)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHUDExpansion.cardSpacing(isExpanded: isExpanded)) {
            header
            PickyHUDCollapsibleContent(isExpanded: isExpanded) {
                expandedContent
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, PickyHUDExpansion.cardVerticalPadding(isExpanded: isExpanded))
        .background(cardBackground)
        .onHover { isHovering in
            onHoverChanged(isHovering)
            if isHovering {
                viewModel.beginHoveredVoiceFollowUp(sessionID: session.id)
            } else {
                viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
            }
        }
        .onDisappear {
            onHoverChanged(false)
            viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
        }
        .task(id: gitStatusRefreshKey) {
            if let cachedStatus = PickyGitRepositoryStatus.cached(cwd: session.cwd) {
                gitStatus = cachedStatus
            }
            let loadedStatus = await PickyGitRepositoryStatus.load(cwd: session.cwd)
            guard !Task.isCancelled else { return }
            gitStatus = loadedStatus
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            PickyHUDStatusBadgeView(color: statusColor, isActive: session.status == .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if isVoiceFollowUpTarget {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(DS.Colors.accentSubtle.opacity(0.95)))
                    .help("Voice steering target")
                    .transition(.scale.combined(with: .opacity))
            }
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(PickyHUDExpansion.animation, value: isExpanded)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                if let compactCwd = session.compactCwdDescription {
                    metaRow(icon: "folder", text: compactCwd)
                }

                if let gitStatus {
                    gitStatusLine(gitStatus)
                }
            }

            Divider().opacity(0.35)

            if let lastRequestText = session.lastRequestText {
                eventRow(
                    time: session.elapsedSinceLastRequest(),
                    label: "Request",
                    content: lastRequestText,
                    accent: DS.Colors.textTertiary
                )
            }

            if let currentWorkDescription {
                eventRow(
                    time: "now",
                    label: "Working",
                    content: currentWorkDescription,
                    accent: DS.Colors.info,
                    contentLineLimit: 2
                )
            }

            if let pending = session.pendingExtensionUiRequest {
                PickyPendingInputView(request: pending, viewModel: viewModel)
            }

            if PickyHUDExpandedContentPolicy.showsSummary(for: session.status), !session.lastSummary.isEmpty {
                eventRow(
                    time: summaryEventTime,
                    label: summaryEventLabel,
                    content: session.lastSummary,
                    accent: summaryEventAccent,
                    contentLineLimit: PickyHUDExpandedContentPolicy.summaryLineLimit
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

            if !session.linkBadgeArtifacts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.linkBadgeArtifacts) { artifact in
                        if let url = artifact.url {
                            Link(destination: url) {
                                linkBadge(artifact, text: session.linkBadgeText(for: artifact))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(artifact.title)")
                        } else {
                            linkBadge(artifact, text: session.linkBadgeText(for: artifact))
                        }
                    }
                }
            }

            replyField

            HStack(spacing: 4) {
                iconButton(systemName: "doc.text.magnifyingglass", label: "Report", help: "Open report", disabled: session.reportArtifact == nil) {
                    Task { try? await viewModel.openReport(sessionID: session.id) }
                }
                iconButton(systemName: "doc.on.doc", label: "Copy", help: "Copy Pi resume command", disabled: session.piSessionFilePath == nil) {
                    viewModel.copyTerminalResumeCommand(sessionID: session.id)
                }
                iconButton(systemName: "terminal", label: "Terminal", help: "Open Pi terminal", disabled: session.piSessionFilePath == nil || session.status.blocksTerminalOverlay) {
                    viewModel.openTerminalOverlay(sessionID: session.id)
                }
                if let notifyMainOnCompletion = session.notifyMainOnCompletion {
                    iconButton(
                        systemName: notifyMainOnCompletion ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                        label: notifyMainOnCompletion ? "Notify" : "Quiet",
                        help: notifyMainOnCompletion ? "Tell main agent when this side task finishes" : "Keep completion on this side card only"
                    ) {
                        Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: !notifyMainOnCompletion) }
                    }
                }
                Spacer(minLength: 0)
                iconButton(systemName: "stop.circle", label: "Stop", help: "Stop session", disabled: session.status.isTerminal) {
                    Task { try? await viewModel.abort(sessionID: session.id) }
                }
                iconButton(systemName: "archivebox", label: "Archive", help: "Archive session") {
                    viewModel.archive(sessionID: session.id)
                }
            }
            .padding(.top, 2)
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
                .truncationMode(.middle)
        }
        .foregroundColor(DS.Colors.textTertiary)
    }

    private func gitStatusLine(_ status: PickyGitRepositoryStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 12)
            Text(status.branchDisplayName)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if status.hasVisibleMetrics {
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if status.insertions > 0 {
                        gitMetricPill("+\(status.insertions)", color: DS.Colors.success)
                    }
                    if status.deletions > 0 {
                        gitMetricPill("-\(status.deletions)", color: DS.Colors.destructiveText)
                    }
                    if status.aheadCount > 0 {
                        gitMetricPill("↑\(status.aheadCount)", color: DS.Colors.accentText)
                    }
                    if status.behindCount > 0 {
                        gitMetricPill("↓\(status.behindCount)", color: DS.Colors.warningText)
                    }
                }
            }
        }
    }

    private func gitMetricPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(color.opacity(0.92))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.10)))
    }

    private func eventRow(
        time: String,
        label: String,
        content: String,
        accent: Color,
        contentLineLimit: Int? = 3
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(accent.opacity(0.85))
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent.opacity(0.9))
                    .tracking(0.4)
                Text(content)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(contentLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryEventLabel: String {
        PickyHUDSummaryEventPolicy.label(for: session.status, hasReportArtifact: session.reportArtifact != nil)
    }

    private var summaryEventTime: String {
        PickyHUDSummaryEventPolicy.time(for: session.status, summaryElapsed: session.elapsedSinceUpdate())
    }

    private var summaryEventAccent: Color {
        switch session.status {
        case .completed: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .blocked: return DS.Colors.warningText
        case .waiting_for_input: return DS.Colors.warning
        case .running, .queued, .cancelled: return DS.Colors.textTertiary
        }
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 5) {
            replyInputRow
            slashCommandAutocomplete
        }
        .onChange(of: followUpText) { _, text in
            selectedSlashCommandIndex = 0
            isSlashCommandAutocompleteDismissed = false
            if PickySlashCommandAutocompletePolicy.query(in: text) != nil {
                viewModel.ensureSlashCommandsLoaded(sessionID: session.id)
            }
        }
    }

    private var replyInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            PickyHUDSlashCommandTextField(
                placeholder: "Steer this agent…",
                text: $followUpText,
                onMoveUp: { moveSlashCommandSelection(.up) },
                onMoveDown: { moveSlashCommandSelection(.down) },
                onAutocomplete: { acceptSelectedSlashCommand() },
                onDismissAutocomplete: { dismissSlashCommandAutocomplete() },
                onSubmit: { handleReplySubmitKey() }
            )
            .frame(minHeight: 16)
            if followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("↵")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                    )
            } else {
                Button(action: submitFollowUp) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Send steering message")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
                )
        )
    }

    @ViewBuilder
    private var slashCommandAutocomplete: some View {
        if slashCommandAutocompleteIsVisible {
            let suggestions = slashCommandSuggestions
            if !suggestions.isEmpty {
                let selectedIndex = selectedSlashCommandIndex(for: suggestions)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                        Button {
                            acceptSlashCommand(command)
                        } label: {
                            slashCommandRow(command, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
                        )
                )
            } else if !viewModel.hasLoadedSlashCommands(sessionID: session.id) {
                slashCommandStatus("Loading commands…")
            } else {
                slashCommandStatus("No matching commands")
            }
        }
    }

    private func slashCommandRow(_ command: PickySlashCommand, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("/\(command.name)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            Text(command.source.displayName)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
            if let description = command.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var slashCommandAutocompleteIsVisible: Bool {
        PickySlashCommandAutocompletePolicy.query(in: followUpText) != nil && !isSlashCommandAutocompleteDismissed
    }

    private var slashCommandSuggestions: [PickySlashCommand] {
        guard PickySlashCommandAutocompletePolicy.query(in: followUpText) != nil else { return [] }
        return viewModel.slashCommandSuggestions(for: followUpText, sessionID: session.id)
    }

    private func selectedSlashCommandIndex(for suggestions: [PickySlashCommand]) -> Int {
        PickySlashCommandAutocompletePolicy.clampedSelectionIndex(selectedSlashCommandIndex, suggestionCount: suggestions.count)
    }

    private func moveSlashCommandSelection(_ direction: PickySlashCommandNavigationDirection) -> Bool {
        let suggestions = slashCommandSuggestions
        guard slashCommandAutocompleteIsVisible, !suggestions.isEmpty else { return false }
        selectedSlashCommandIndex = PickySlashCommandAutocompletePolicy.movedSelectionIndex(
            current: selectedSlashCommandIndex,
            suggestionCount: suggestions.count,
            direction: direction
        )
        return true
    }

    private func acceptSelectedSlashCommand() -> Bool {
        let suggestions = slashCommandSuggestions
        guard slashCommandAutocompleteIsVisible, !suggestions.isEmpty else { return false }
        acceptSlashCommand(suggestions[selectedSlashCommandIndex(for: suggestions)])
        return true
    }

    private func acceptSlashCommand(_ command: PickySlashCommand) {
        followUpText = PickySlashCommandAutocompletePolicy.completionText(for: command)
        selectedSlashCommandIndex = 0
        isSlashCommandAutocompleteDismissed = true
    }

    private func dismissSlashCommandAutocomplete() -> Bool {
        guard slashCommandAutocompleteIsVisible else { return false }
        isSlashCommandAutocompleteDismissed = true
        return true
    }

    private func handleReplySubmitKey() {
        if acceptSelectedSlashCommand() { return }
        submitFollowUp()
    }

    private func slashCommandStatus(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.8)
                    )
            )
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

    private func iconButton(systemName: String, label: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 16)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 38, minHeight: 32)
        }
        .buttonStyle(PickyHUDIconButtonStyle())
        .foregroundColor(DS.Colors.textSecondary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(help)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(session.status == .completed ? 0.88 : 0.95))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(statusColor.opacity(cardTintOpacity)))
            .overlay {
                if usesAnimatedStatusBorder {
                    PickyHUDAnimatedStatusBorderView(
                        baseColor: statusColor,
                        highlightColor: statusLoadingHighlightColor,
                        duration: statusBorderAnimationDuration
                    )
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(cardBorderColor, lineWidth: 1)
                }
            }
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.cardShadowOpacity),
                radius: PickyHUDExpansion.cardShadowRadius,
                x: 0,
                y: PickyHUDExpansion.cardShadowYOffset
            )
    }

    private var headerSubtitle: String {
        let elapsed = session.elapsedDescription()
        switch session.status {
        case .queued:
            return "queued · \(elapsed)"
        case .running:
            if let activeTool = session.activeTool {
                return "\(activeTool.name) · \(elapsed)"
            }
            return "working · \(elapsed)"
        case .waiting_for_input:
            return "input needed · \(elapsed)"
        case .blocked:
            return session.isRuntimeDetached ? "detached · resume needed · \(elapsed)" : "blocked · \(elapsed)"
        case .completed:
            return session.reportArtifact == nil ? "completed · \(elapsed)" : "report ready · \(elapsed)"
        case .failed:
            return "failed · \(elapsed)"
        case .cancelled:
            return "cancelled · \(elapsed)"
        }
    }

    private func linkBadge(_ artifact: PickyArtifact, text: String?) -> some View {
        HStack(spacing: 4) {
            linkBadgeIcon(for: artifact.linkBadgeKind)
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
            }
        }
        .padding(.horizontal, text == nil ? 6 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.accentSubtle))
    }

    @ViewBuilder
    private func linkBadgeIcon(for kind: PickyLinkBadgeKind?) -> some View {
        switch kind {
        case .github:
            Image("github-logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .foregroundColor(DS.Colors.accentText)
        case .slack:
            Image("slack-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
        case .notion:
            Image("notion-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
        case nil:
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
        }
    }

    private var currentWorkDescription: String? {
        guard session.status == .running else { return nil }
        return PickyHUDCurrentWorkPolicy.runningDescription(
            activeTool: session.activeTool,
            thinkingPreview: session.thinkingPreview
        )
    }

    private var cardTintOpacity: Double {
        switch session.status {
        case .running: 0.055
        case .queued: 0.035
        case .waiting_for_input: 0.08
        case .blocked, .failed: 0.07
        case .completed: 0.03
        case .cancelled: 0.02
        }
    }

    private var usesAnimatedStatusBorder: Bool {
        session.status == .queued || session.status == .running
    }

    private var statusBorderAnimationDuration: Double {
        session.status == .running ? 2.4 : 4.2
    }

    private var statusLoadingHighlightColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .queued:
            return DS.Colors.floatingGradientPurple
        default:
            return statusColor
        }
    }

    private var cardBorderColor: Color {
        if isVoiceFollowUpTarget {
            return DS.Colors.accentText.opacity(0.72)
        }

        switch session.status {
        case .waiting_for_input:
            return DS.Colors.warning.opacity(0.55)
        case .blocked:
            return DS.Colors.warningText.opacity(0.55)
        case .failed:
            return DS.Colors.destructiveText.opacity(0.55)
        case .completed:
            return DS.Colors.success.opacity(0.42)
        case .running:
            return statusColor.opacity(0.50)
        case .queued, .cancelled:
            return DS.Colors.borderSubtle.opacity(0.65)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return DS.Colors.accentText
        case .running:
            return DS.Colors.overlayCursorBlue
        case .waiting_for_input:
            return DS.Colors.warning
        case .blocked:
            return DS.Colors.warningText
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }
}

private struct PickyHUDSlashCommandTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onMoveUp: () -> Bool
    var onMoveDown: () -> Bool
    var onAutocomplete: () -> Bool
    var onDismissAutocomplete: () -> Bool
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.font = Self.font
        textField.textColor = NSColor(DS.Colors.textPrimary)
        textField.backgroundColor = .clear
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configureCell(textField.cell)
        updatePlaceholder(on: textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.font = Self.font
        textField.textColor = NSColor(DS.Colors.textPrimary)
        textField.backgroundColor = .clear
        configureCell(textField.cell)
        updatePlaceholder(on: textField)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static let font = NSFont.systemFont(ofSize: 11.5)

    private func updatePlaceholder(on textField: NSTextField) {
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }

    private func configureCell(_ cell: NSCell?) {
        guard let cell = cell as? NSTextFieldCell else { return }
        cell.usesSingleLineMode = true
        cell.isScrollable = true
        cell.wraps = false
        cell.lineBreakMode = .byTruncatingTail
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickyHUDSlashCommandTextField

        init(parent: PickyHUDSlashCommandTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            if parent.text != textField.stringValue {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveUp()
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveDown()
            case #selector(NSResponder.insertTab(_:)):
                return parent.onAutocomplete()
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onDismissAutocomplete()
            default:
                return false
            }
        }
    }
}

private struct PickyHUDIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? DS.Colors.surface3 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .modifier(PickyHUDIconButtonHoverModifier())
    }
}

private struct PickyHUDIconButtonHoverModifier: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface2.opacity(0.85) : Color.clear)
            )
            .onHover { isHovered = $0 }
    }
}

private struct PickyHUDAnimatedStatusBorderView: View {
    let baseColor: Color
    let highlightColor: Color
    let duration: Double
    var cornerRadius: CGFloat = 14
    @State private var isFlowing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(baseColor.opacity(0.24), lineWidth: 1)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: baseColor.opacity(0.20), location: 0.00),
                            .init(color: highlightColor.opacity(0.85), location: 0.11),
                            .init(color: Color.white.opacity(0.64), location: 0.17),
                            .init(color: baseColor.opacity(0.86), location: 0.24),
                            .init(color: baseColor.opacity(0.18), location: 0.42),
                            .init(color: highlightColor.opacity(0.30), location: 0.62),
                            .init(color: highlightColor.opacity(0.82), location: 0.79),
                            .init(color: baseColor.opacity(0.24), location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(isFlowing ? 360 : 0)
                    ),
                    lineWidth: 1.45
                )
                .shadow(color: highlightColor.opacity(0.26), radius: 3.4, x: 0, y: 0)
        }
        .onAppear {
            guard !isFlowing else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                isFlowing = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PickyHUDStatusBadgeView: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isActive ? 0.16 : 0.10))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(isActive ? 0.70 : 0.45), lineWidth: 0.8)
            Image("PiSymbol")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(color)
                .frame(width: 12.5, height: 12.5)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct PickyPendingInputView: View {
    let request: PickyExtensionUiRequest
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var textValue = ""
    @State private var formState = PickyAskUserQuestionFormState()
    @State private var seededFormRequestID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for input")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.warning)
            Text(request.prompt ?? request.title ?? request.method)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(3)
            if request.method == "askUserQuestion", let description = request.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
            }
            controls
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(DS.Colors.warning.opacity(0.12)))
        .onAppear { seedFormDefaultsIfNeeded() }
        .onChange(of: request.id) { _ in
            formState = PickyAskUserQuestionFormState()
            seededFormRequestID = nil
            seedFormDefaultsIfNeeded()
        }
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
        case "askUserQuestion":
            askUserQuestionForm
        default:
            Button("Dismiss") { cancel() }
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var askUserQuestionForm: some View {
        let questions = request.questions ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if questions.isEmpty {
                Text("No questions provided")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    formQuestion(question, index: index)
                }
            }
            HStack(spacing: 6) {
                Button("Submit") { submitAskUserQuestion() }
                    .disabled(!formState.isSubmittable(questions: questions))
                Button("Cancel") { cancel() }
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    private func formQuestion(_ question: PickyExtensionUiQuestion, index: Int) -> some View {
        let key = PickyAskUserQuestionFormState.key(for: question, index: index)
        return VStack(alignment: .leading, spacing: 5) {
            Text(question.prompt ?? question.label ?? key)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            switch question.type {
            case .radio:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options ?? []) { option in
                        optionButton(label: option.label, description: option.description, selected: formState.radioValues[key] == option.value) {
                            formState.selectRadio(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowOther ?? true {
                        optionButton(label: "Other…", description: nil, selected: formState.radioValues[key] == PickyAskUserQuestionFormState.otherSentinel) {
                            formState.selectRadio(question: question, index: index, value: PickyAskUserQuestionFormState.otherSentinel)
                        }
                        TextField("Other…", text: binding($formState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .disabled(formState.radioValues[key] != PickyAskUserQuestionFormState.otherSentinel)
                    }
                }
            case .checkbox:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options ?? []) { option in
                        optionButton(label: option.label, description: option.description, selected: formState.checkboxValues[key]?.contains(option.value) == true) {
                            formState.toggleCheckbox(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowOther ?? true {
                        TextField("Other…", text: binding($formState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }
            case .text:
                TextField(question.placeholder ?? "Response…", text: binding($formState.textValues, key: key))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 2)
    }

    private func optionButton(label: String, description: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? DS.Colors.accentSubtle : DS.Colors.surface2.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? DS.Colors.accentText : DS.Colors.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundColor(selected ? DS.Colors.accentText : DS.Colors.textPrimary)
    }

    private func binding(_ dictionary: Binding<[String: String]>, key: String) -> Binding<String> {
        Binding(
            get: { dictionary.wrappedValue[key] ?? "" },
            set: { dictionary.wrappedValue[key] = $0 }
        )
    }

    private func submitText() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer(.string(trimmed))
    }

    private func submitAskUserQuestion() {
        let questions = request.questions ?? []
        guard formState.isSubmittable(questions: questions) else { return }
        answer(.object(["value": .object(formState.answerObject(for: questions))]))
    }

    private func seedFormDefaultsIfNeeded() {
        guard request.method == "askUserQuestion", seededFormRequestID != request.id else { return }
        formState.seedDefaults(for: request.questions ?? [])
        seededFormRequestID = request.id
    }

    private func answer(_ value: JSONValue) {
        Task { try? await viewModel.answerExtensionUi(sessionID: request.sessionId, requestID: request.id, value: value) }
    }

    private func cancel() {
        Task { try? await viewModel.cancelExtensionUi(sessionID: request.sessionId, requestID: request.id) }
    }
}


#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}

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
    @State private var dockIconScreenFramesBySessionID: [String: CGRect] = [:]
    @State private var lastReportedHUDSize: CGSize = .zero
    @State private var lastReportedActiveSessionID: String?

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
            // Measure the HUD's intrinsic content height before the hosting view
            // applies the current panel height. Without this, active streaming
            // updates can report the already-clipped height and prevent growth.
            .fixedSize(horizontal: false, vertical: true)
            .background(PickyHUDSizeReader())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // Animate only expand/collapse. Switching between dock-hovered sessions should
            // swap content immediately; animating every activeSession id change cross-fades
            // different card heights and makes the HUD look like it is stretching/flickering.
            .animation(PickyHUDExpansion.animation, value: activeSession != nil)
            .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: handleHUDSizeChange)
            .onDisappear {
                closeExpansionTask?.cancel()
                closeExpansionTask = nil
            }
    }

    private func handleHUDSizeChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let activeID = activeSession?.id
        if activeID != lastReportedActiveSessionID {
            lastReportedActiveSessionID = activeID
            lastReportedHUDSize = size
            onSizeChange(size)
            return
        }

        let targetSize = PickyHUDExpansion.reportedHUDSize(
            measuredSize: size,
            previousReportedSize: lastReportedHUDSize,
            activeSessionChanged: false,
            shouldHoldHeight: shouldHoldPanelHeightDuringActiveTurn
        )

        guard !lastReportedHUDSize.isApproximatelyEqual(to: targetSize) else { return }
        lastReportedHUDSize = targetSize
        onSizeChange(targetSize)
    }

    private var shouldHoldPanelHeightDuringActiveTurn: Bool {
        switch activeSession?.status {
        case .running, .queued, .waiting_for_input:
            return true
        case .completed, .blocked, .cancelled, .failed, nil:
            return false
        }
    }

    private var hudContent: some View {
        HStack(alignment: .center, spacing: PickyHUDDockLayout.panelGap) {
            if let activeSession {
                PickyConversationCardView(viewModel: viewModel, session: activeSession)
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
        .padding(.horizontal, PickyHUDExpansion.outerPadding)
        .padding(.vertical, PickyHUDExpansion.dockShadowVerticalPadding)
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
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockShadowOpacity),
                radius: PickyHUDExpansion.dockShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockShadowYOffset
            )
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.dockTightShadowOpacity),
                radius: PickyHUDExpansion.dockTightShadowRadius,
                x: 0,
                y: PickyHUDExpansion.dockTightShadowYOffset
            )
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

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
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


#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}

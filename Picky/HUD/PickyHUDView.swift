//
//  PickyHUDView.swift
//  Picky
//
//  SwiftUI composition for the long-running session HUD.
//

import AppKit
import SwiftUI

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var onSizeChange: (CGSize) -> Void = { _ in }
    @State private var pinnedSessionID: String?
    @State private var previewSessionID: String?
    @State private var isHUDHovered = false
    @State private var closeExpansionTask: Task<Void, Never>?
    @State private var archiveUndoToast: PickyHUDArchiveUndoToast?
    @State private var archiveUndoDismissTask: Task<Void, Never>?
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
            .overlay(alignment: .bottomTrailing) {
                archiveUndoToastOverlay
            }
            // Animate only expand/collapse. Switching between dock-hovered sessions should
            // swap content immediately; animating every activeSession id change cross-fades
            // different card heights and makes the HUD look like it is stretching/flickering.
            .animation(PickyHUDExpansion.animation, value: activeSession != nil)
            .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: handleHUDSizeChange)
            .onDisappear {
                closeExpansionTask?.cancel()
                closeExpansionTask = nil
                archiveUndoDismissTask?.cancel()
                archiveUndoDismissTask = nil
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

            if !viewModel.isLoadingInitialSessionSnapshot {
                PickyHUDDockRailView(
                    sessions: visibleSessions,
                    activeSessionID: activeSession?.id,
                    pinnedSessionID: pinnedSessionID,
                    pendingDoneFlashSessionIDs: viewModel.pendingDoneFlashSessionIDs,
                    onHoverSession: previewDockSession,
                    onPinSession: pinSession,
                    onArchiveSession: archiveSessionFromDock,
                    onCreateSideAgent: chooseFolderForEmptySideAgent,
                    onDoneFlashConsumed: viewModel.markDoneFlashConsumed(sessionID:)
                )
                .frame(width: PickyHUDDockLayout.railWidth)
            }
        }
        .padding(.horizontal, PickyHUDExpansion.outerPadding)
        .padding(.vertical, PickyHUDExpansion.dockShadowVerticalPadding)
        .onHover(perform: handleHUDHover)
    }

    @ViewBuilder
    private var archiveUndoToastOverlay: some View {
        if let archiveUndoToast {
            PickyHUDArchiveUndoToastView(
                toast: archiveUndoToast,
                onUndo: { undoArchive(toast: archiveUndoToast) }
            )
            .padding(.trailing, PickyHUDDockLayout.railWidth + PickyHUDExpansion.outerPadding + 8)
            .padding(.bottom, PickyHUDExpansion.dockShadowVerticalPadding + 2)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .allowsHitTesting(true)
            .zIndex(10)
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

    private func pinSession(_ sessionID: String) {
        cancelPendingClose()
        pinnedSessionID = PickyHUDDockLayout.pinnedSessionIDAfterClick(current: pinnedSessionID, clicked: sessionID)
        previewSessionID = pinnedSessionID == nil && isHUDHovered ? sessionID : nil
        if pinnedSessionID == nil && !isHUDHovered {
            scheduleCloseIfNeeded()
        }
    }

    private func archiveSessionFromDock(_ sessionID: String) {
        cancelPendingClose()
        let title = visibleSessions.first(where: { $0.id == sessionID })?.title ?? "Side agent"
        viewModel.archive(sessionID: sessionID)
        if pinnedSessionID == sessionID { pinnedSessionID = nil }
        if previewSessionID == sessionID { previewSessionID = nil }
        showArchiveUndoToast(sessionID: sessionID, title: title)
    }

    private func showArchiveUndoToast(sessionID: String, title: String) {
        archiveUndoDismissTask?.cancel()
        let toast = PickyHUDArchiveUndoToast(sessionID: sessionID, title: title)
        withAnimation(PickyHUDExpansion.animation) {
            archiveUndoToast = toast
        }
        archiveUndoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PickyHUDArchiveHoldPolicy.undoToastDurationNanoseconds)
            guard !Task.isCancelled, archiveUndoToast?.id == toast.id else { return }
            withAnimation(PickyHUDExpansion.animation) {
                archiveUndoToast = nil
            }
            archiveUndoDismissTask = nil
        }
    }

    private func undoArchive(toast: PickyHUDArchiveUndoToast) {
        archiveUndoDismissTask?.cancel()
        archiveUndoDismissTask = nil
        viewModel.unarchive(sessionID: toast.sessionID)
        withAnimation(PickyHUDExpansion.animation) {
            archiveUndoToast = nil
        }
    }

    private func scheduleCloseIfNeeded() {
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

private enum PickyHUDArchiveHoldPolicy {
    static let duration: TimeInterval = 2
    static let maximumDistance: CGFloat = 10
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73
    static let undoToastDurationNanoseconds: UInt64 = 6_000_000_000
}

private struct PickyHUDArchiveUndoToast: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let title: String
}

private struct PickyHUDArchiveUndoToastView: View {
    let toast: PickyHUDArchiveUndoToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.warningText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(DS.Colors.warning.opacity(0.15)))

            VStack(alignment: .leading, spacing: 1) {
                Text("Session archived")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(toast.title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 128, alignment: .leading)

            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Colors.accentText.opacity(0.12))
                        .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.accentText.opacity(0.24), lineWidth: 0.7))
                )
                .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(DS.Colors.surface1.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session archived. Undo available.")
    }
}

private struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let activeSessionID: String?
    let pinnedSessionID: String?
    let pendingDoneFlashSessionIDs: Set<String>
    let onHoverSession: (String) -> Void
    let onPinSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onCreateSideAgent: () -> Void
    let onDoneFlashConsumed: (String) -> Void

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
                            shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                            onHover: { onHoverSession(session.id) },
                            onPin: { onPinSession(session.id) },
                            onArchive: { onArchiveSession(session.id) },
                            onDoneFlashConsumed: { onDoneFlashConsumed(session.id) }
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
    let shouldFlashCompletion: Bool
    let onHover: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onDoneFlashConsumed: () -> Void

    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @State private var isArchivePressing = false
    @State private var archiveProgress: Double = 0
    @State private var didCompleteArchiveHold = false

    var body: some View {
        ZStack {
            dockIconBackground
            Text("\(index + 1)")
                .font(PickyHUDTypography.supportingMonospacedSemibold)
                .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .opacity(isArchivePressing ? 0.64 : 1)
        }
        .frame(width: 36, height: 36)
        .scaleEffect(isArchivePressing ? 0.92 : 1)
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
        .overlay(alignment: .topLeading) {
            if isArchivePressing {
                archiveBadge
                    .offset(x: -5, y: -5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .center) {
            archiveProgressRing
        }
        .contentShape(Circle())
        .onTapGesture(perform: onPin)
        .onLongPressGesture(
            minimumDuration: PickyHUDArchiveHoldPolicy.duration,
            maximumDistance: PickyHUDArchiveHoldPolicy.maximumDistance,
            pressing: handleArchivePressing,
            perform: completeArchiveHold
        )
        .pointerCursor()
        .onHover { isHovering in
            if isHovering { onHover() }
        }
        .onAppear {
            if shouldFlashCompletion { runCompletionFlash() }
        }
        .onChange(of: shouldFlashCompletion) { _, shouldFlash in
            if shouldFlash { runCompletionFlash() }
        }
        .onDisappear {
            completionFlashTask?.cancel()
            completionFlashTask = nil
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: isArchivePressing)
        .accessibilityLabel("Preview \(session.title)")
        .accessibilityHint("Click to pin. Press and hold for 2 seconds to archive this side agent.")
        .accessibilityAddTraits(.isButton)
    }

    private var archiveProgressRing: some View {
        ZStack {
            archiveRingArc(progress: 1)
                .opacity(0.18)
            archiveRingArc(progress: archiveProgress)
        }
        .frame(width: 42, height: 42)
        .opacity(isArchivePressing || archiveProgress > 0 ? 1 : 0)
        .shadow(color: DS.Colors.warning.opacity(0.34), radius: 4, x: 0, y: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func archiveRingArc(progress: Double) -> some View {
        Circle()
            .trim(
                from: PickyHUDArchiveHoldPolicy.ringGapStartFraction,
                to: PickyHUDArchiveHoldPolicy.ringGapStartFraction + (max(0, min(progress, 1)) * PickyHUDArchiveHoldPolicy.ringUsableFraction)
            )
            .stroke(
                DS.Colors.warning,
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
            )
            .rotationEffect(.degrees(-90))
    }

    private var archiveBadge: some View {
        Image(systemName: "archivebox.fill")
            .font(.system(size: 7.5, weight: .bold))
            .foregroundColor(DS.Colors.warningText)
            .frame(width: 14, height: 14)
            .background(Circle().fill(DS.Colors.surface1.opacity(0.96)))
            .overlay(Circle().stroke(DS.Colors.warning.opacity(0.65), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var dockIconBackground: some View {
        // Glass icon: ultraThinMaterial base + (active) status-tinted glaze +
        // (inactive) faint white film. The stroke is a top-bright / status-tinted
        // bottom gradient so the icon reads as a small piece of glass on the
        // bigger glass capsule rather than a flat fill.
        // The completion flash temporarily boosts the success-tinted glaze + stroke
        // and adds an ambient glow so a Done transition feels celebratory without
        // disturbing the layout.
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
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.20 * archiveProgress))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DS.Colors.success.opacity(0.34 * completionFlashIntensity))
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
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(DS.Colors.warning.opacity(0.76 * archiveProgress), lineWidth: 1.35)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(DS.Colors.success.opacity(0.85 * completionFlashIntensity), lineWidth: 1.4)
            )
            .shadow(color: DS.Colors.warning.opacity(0.30 * archiveProgress), radius: 5, x: 0, y: 0)
            .shadow(color: DS.Colors.success.opacity(0.55 * completionFlashIntensity), radius: 6, x: 0, y: 0)
    }

    private func handleArchivePressing(_ isPressing: Bool) {
        if isPressing {
            beginArchiveHoldFeedback()
        } else if !didCompleteArchiveHold {
            cancelArchiveHoldFeedback()
        }
    }

    private func beginArchiveHoldFeedback() {
        didCompleteArchiveHold = false
        archiveProgress = 0
        isArchivePressing = true
        withAnimation(.linear(duration: PickyHUDArchiveHoldPolicy.duration)) {
            archiveProgress = 1
        }
    }

    private func cancelArchiveHoldFeedback() {
        isArchivePressing = false
        withAnimation(.easeOut(duration: 0.18)) {
            archiveProgress = 0
        }
    }

    private func completeArchiveHold() {
        didCompleteArchiveHold = true
        archiveProgress = 1
        onArchive()
    }

    private func runCompletionFlash() {
        completionFlashTask?.cancel()
        onDoneFlashConsumed()
        let task = Task { @MainActor in
            // Two pulses: rise quickly, fall slowly. Rough total duration ~1.4s so it lingers
            // long enough to register but doesn't compete with the dock's animated borders.
            for _ in 0..<2 {
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.18)) { completionFlashIntensity = 1.0 }
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.45)) { completionFlashIntensity = 0.0 }
                try? await Task.sleep(nanoseconds: 480_000_000)
            }
        }
        completionFlashTask = task
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

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
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

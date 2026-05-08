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
    /// Per-panel reactive placement state. The overlay manager updates
    /// `placement.availableCardMaxHeight` whenever the dock anchor or the screen
    /// configuration changes; the conversation card binds to it so it grows or
    /// shrinks within whatever space remains below the dock's top edge.
    @ObservedObject var placement: PickyHUDPlacement = PickyHUDPlacement()
    var onSizeChange: (CGSize) -> Void = { _ in }
    /// Live delta callback for the dock anchor handle. Argument is the cursor's
    /// bottom-up screen Y delta from drag start (`NSEvent.mouseLocation` based, so it
    /// stays correct even though the panel itself moves while we drag). The overlay
    /// manager converts the delta into a percentage of the dragged display's
    /// visibleFrame and updates the shared anchor across every panel.
    var onDockHandleDragChanged: (CGFloat) -> Void = { _ in }
    var onDockHandleDragEnded: () -> Void = { }
    var onArchiveUndoRequested: (_ sessionID: String, _ title: String) -> Void = { _, _ in }
    @State private var heldSession: PickyHUDDockHold?
    @State private var hoverPreviewSessionID: String?
    @State private var suppressedHoverSessionID: String?
    @State private var isHUDHovered = false
    @State private var isDockHovered = false
    @State private var closeExpansionTask: Task<Void, Never>?
    @State private var lastReportedHUDSize: CGSize = .zero
    @State private var lastReportedActiveSessionID: String?

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(PickyHUDDockLayout.visibleSessionLimit).reversed())
    }

    private var activeSessionID: String? {
        PickyHUDDockLayout.activeSessionID(
            visibleIDs: visibleSessions.map(\.id),
            held: heldSession,
            previewID: PickyHUDDockLayout.previewSessionID(
                hoveredID: hoverPreviewSessionID,
                heldID: heldSession?.sessionID
            )
        )
    }

    private var pinnedSessionID: String? {
        if case let .pinned(sessionID) = heldSession { return sessionID }
        return nil
    }

    private var openedSessionID: String? {
        if case let .open(sessionID) = heldSession { return sessionID }
        return nil
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
            // topTrailing keeps content stuck to the panel's top edge during the
            // shouldHoldHeight phase. With dock-top-anchored placement we want the
            // dock to coincide with the panel top (after vertical padding); a default
            // .center alignment would float the content vertically inside the held
            // panel and break the dock anchor math.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        // alignment: .top so the card and the dock-rail stack both anchor at the HStack
        // top edge. The dock anchor handle floats above the dock with a small gap (see
        // PickyHUDDockRailView.dockHandle), so the conversation card's top can sit at the
        // same Y as the dock's top — keeping the dock's screen position invariant under
        // changes to the conversation card height.
        HStack(alignment: .top, spacing: PickyHUDDockLayout.panelGap) {
            if let activeSession {
                PickyConversationCardView(
                    viewModel: viewModel,
                    session: activeSession,
                    onArchiveSession: archiveSession,
                    maxHeight: placement.availableCardMaxHeight,
                    isPreviewMode: isHoverPreviewSession(activeSession.id)
                )
                    .id(activeSession.id)
                    .frame(width: PickyHUDDockLayout.detailWidth)
                    .transition(.opacity)
            }

            if !viewModel.isLoadingInitialSessionSnapshot {
                PickyHUDDockRailView(
                    sessions: visibleSessions,
                    activeSessionID: activeSession?.id,
                    pinnedSessionID: pinnedSessionID,
                    openedSessionID: openedSessionID,
                    pendingDoneFlashSessionIDs: viewModel.pendingDoneFlashSessionIDs,
                    onHoverSession: previewDockSession,
                    onOpenSession: toggleOpenSession,
                    onPinSession: pinSession,
                    onArchiveSession: archiveSession,
                    onCreateSideAgent: chooseFolderForEmptySideAgent,
                    onDockHoverChanged: handleDockHover,
                    onDoneFlashConsumed: viewModel.markDoneFlashConsumed(sessionID:),
                    onDockHandleDragChanged: onDockHandleDragChanged,
                    onDockHandleDragEnded: onDockHandleDragEnded
                )
                .frame(width: PickyHUDDockLayout.railWidth)
                // Suppress the implicit layout animation triggered by the outer body's
                // `.animation(_:value: activeSession != nil)` for the dock rail. Without
                // this, the first hover that brings the conversation card in animates
                // the HStack height interpolation through the dock-rail subtree, which
                // briefly drops the dock capsule by a few points before the panel
                // resize settles — the "덜컹" the user reported.
                .transaction(value: activeSession?.id) { transaction in
                    transaction.animation = nil
                }
            }
        }
        .padding(.horizontal, PickyHUDExpansion.outerPadding)
        .padding(.vertical, PickyHUDExpansion.dockShadowVerticalPadding)
        .onHover(perform: handleHUDHover)
    }

    private var isPointerInsideHUDSurface: Bool {
        isHUDHovered || isDockHovered
    }

    private func handleHUDHover(_ isHovering: Bool) {
        isHUDHovered = isHovering
        if isHovering {
            cancelPendingClose()
        } else {
            scheduleCloseIfNeeded()
        }
    }

    private func handleDockHover(_ isHovering: Bool) {
        isDockHovered = isHovering
        if isHovering {
            cancelPendingClose()
        } else {
            scheduleCloseIfNeeded()
        }
    }

    private func isHoverPreviewSession(_ sessionID: String) -> Bool {
        hoverPreviewSessionID == sessionID && heldSession?.sessionID != sessionID
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
        isDockHovered = true
        cancelPendingClose()
        if suppressedHoverSessionID == sessionID { return }
        suppressedHoverSessionID = nil
        hoverPreviewSessionID = PickyHUDDockLayout.previewSessionIDAfterDockHover(
            current: hoverPreviewSessionID,
            sessionID: sessionID,
            pinnedID: pinnedSessionID
        )
    }

    private func toggleOpenSession(_ sessionID: String) {
        cancelPendingClose()
        let nextHeldSession = PickyHUDDockLayout.heldSessionAfterClick(
            current: heldSession,
            clicked: sessionID
        )
        heldSession = nextHeldSession
        if nextHeldSession == nil {
            if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
            suppressedHoverSessionID = sessionID
        } else {
            suppressedHoverSessionID = nil
        }
    }

    private func pinSession(_ sessionID: String) {
        cancelPendingClose()
        heldSession = PickyHUDDockLayout.heldSessionAfterDoubleClick(current: heldSession, doubleClicked: sessionID)
        if isPointerInsideHUDSurface && suppressedHoverSessionID != sessionID {
            hoverPreviewSessionID = sessionID
        }
    }

    private func archiveSession(_ sessionID: String) {
        cancelPendingClose()
        let title = (visibleSessions + viewModel.sessions).first(where: { $0.id == sessionID })?.title ?? "Side agent"
        viewModel.archive(sessionID: sessionID)
        if heldSession?.sessionID == sessionID { heldSession = nil }
        if hoverPreviewSessionID == sessionID { hoverPreviewSessionID = nil }
        if suppressedHoverSessionID == sessionID { suppressedHoverSessionID = nil }
        onArchiveUndoRequested(sessionID, title)
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
                let isStillInsideHUD = isPointerInsideHUDSurface
                hoverPreviewSessionID = PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(
                    current: hoverPreviewSessionID,
                    pinnedID: pinnedSessionID,
                    isDockHovered: isDockHovered
                )
                heldSession = PickyHUDDockLayout.heldSessionAfterCloseTimeout(
                    current: heldSession,
                    isHUDHovered: isStillInsideHUD
                )
                if !isStillInsideHUD { suppressedHoverSessionID = nil }
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

enum PickyHUDArchiveHoldPolicy {
    static let duration: TimeInterval = 2
    static let feedbackStartDelay: TimeInterval = 0.2
    static let feedbackStartDelayNanoseconds: UInt64 = 200_000_000
    static let maximumDistance: CGFloat = 10
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73

    static var feedbackAnimationDuration: TimeInterval {
        max(0, duration - feedbackStartDelay)
    }
}

private struct PickyHUDDockRailView: View {
    let sessions: [PickySessionListViewModel.SessionCard]
    let activeSessionID: String?
    let pinnedSessionID: String?
    let openedSessionID: String?
    let pendingDoneFlashSessionIDs: Set<String>
    let onHoverSession: (String) -> Void
    let onOpenSession: (String) -> Void
    let onPinSession: (String) -> Void
    let onArchiveSession: (String) -> Void
    let onCreateSideAgent: () -> Void
    let onDockHoverChanged: (Bool) -> Void
    let onDoneFlashConsumed: (String) -> Void
    let onDockHandleDragChanged: (CGFloat) -> Void
    let onDockHandleDragEnded: () -> Void

    @State private var isAddSlotExpanded = false
    @State private var isHandleHovered = false
    @State private var isHandleDragging = false

    var body: some View {
        // The handle is the first child INSIDE the dock capsule (after a small top
        // padding) so the dock body itself acts as the hit target. The capsule
        // background is opaque, which sidesteps SwiftUI's transparent-view hit-
        // testing quirks: clicks anywhere in the handle's row hit the NSView
        // backing the handle, not the empty space outside an external pill.
        VStack(spacing: 2) {
            dockAnchorHandle
            sessionsAndAddSlot
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(dockGlassBackground)
        .onHover(perform: onDockHoverChanged)
    }

    @ViewBuilder
    private var sessionsAndAddSlot: some View {
        if sessions.isEmpty {
            // Empty state still lives inside the capsule so the handle has somewhere
            // to anchor visually. Use the full-size add button (not the collapsible
            // one) since there are no sessions to keep it compact for.
            addAgentSlotButton
        } else {
            VStack(spacing: 9) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    PickyHUDDockIconView(
                        session: session,
                        index: index,
                        isActive: activeSessionID == session.id,
                        isPinned: pinnedSessionID == session.id,
                        isOpened: openedSessionID == session.id,
                        shouldFlashCompletion: pendingDoneFlashSessionIDs.contains(session.id),
                        onHover: { onHoverSession(session.id) },
                        onOpen: { onOpenSession(session.id) },
                        onPin: { onPinSession(session.id) },
                        onArchive: { onArchiveSession(session.id) },
                        onDoneFlashConsumed: { onDoneFlashConsumed(session.id) }
                    )
                }
            }
            collapsibleAddAgentSlot
                .padding(.top, 9)
        }
    }

    /// Drag handle that lives inside the dock capsule's top row. Backed by an
    /// `NSViewRepresentable` so AppKit handles hit testing, tracking area, and
    /// cursor rects — the same NSView bounds drive all three, which avoids the
    /// SwiftUI hit-test quirks that plagued earlier overlay-based attempts.
    /// The visible 22×4 pill is overlaid with `.allowsHitTesting(false)` so it's
    /// purely decorative and never claims clicks.
    private var dockAnchorHandle: some View {
        let isActive = isHandleHovered || isHandleDragging
        return PickyHUDDockAnchorHandleHost(
            onHoverChanged: { hovering in isHandleHovered = hovering },
            onDragChanged: { delta in
                if !isHandleDragging { isHandleDragging = true }
                onDockHandleDragChanged(delta)
            },
            onDragEnded: {
                isHandleDragging = false
                onDockHandleDragEnded()
            }
        )
        // Fill the capsule's available inner width (railWidth minus the dock's
        // 6pt horizontal padding on each side) so the handle row spans the
        // entire top of the capsule.
        .frame(maxWidth: .infinity)
        .frame(height: PickyHUDExpansion.dockHandleAreaHeight)
        .overlay {
            // Quiet by default — the pill should hint at draggability without
            // shouting. Hover and drag expand and darken it for a clear cue.
            Capsule(style: .continuous)
                .fill(DS.Colors.textTertiary.opacity(isActive ? 0.7 : 0.22))
                .frame(width: isActive ? 24 : 18, height: 3)
                .animation(.easeOut(duration: 0.14), value: isHandleHovered)
                .animation(.easeOut(duration: 0.14), value: isHandleDragging)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("HUD vertical position")
        .accessibilityHint("Drag up or down to move the side-agent dock between 2% and 70% of the screen.")
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
                    .fill(DS.Colors.textSecondary.opacity(0.78))
                    .frame(width: 18, height: 1)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, y: 0.4)
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
    let isOpened: Bool
    let shouldFlashCompletion: Bool
    let onHover: () -> Void
    let onOpen: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onDoneFlashConsumed: () -> Void

    @State private var completionFlashIntensity: Double = 0
    @State private var completionFlashTask: Task<Void, Never>?
    @State private var archiveFeedbackStartTask: Task<Void, Never>?
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
        .overlay(alignment: .leading) {
            if isOpened {
                openStateMarker
                    .offset(x: -7)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
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
        .overlay {
            PickyHUDDockIconClickHost(
                onHover: onHover,
                onOpen: onOpen,
                onPin: onPin,
                onArchivePressing: handleArchivePressing,
                onArchive: completeArchiveHold
            )
        }
        .pointerCursor()
        .onAppear {
            if shouldFlashCompletion { runCompletionFlash() }
        }
        .onChange(of: shouldFlashCompletion) { _, shouldFlash in
            if shouldFlash { runCompletionFlash() }
        }
        .onDisappear {
            completionFlashTask?.cancel()
            completionFlashTask = nil
            archiveFeedbackStartTask?.cancel()
            archiveFeedbackStartTask = nil
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: isArchivePressing)
        .accessibilityLabel("Preview \(session.title)")
        .accessibilityHint("Click to open or close. Double-click to pin or unpin. Press and hold for 2 seconds to archive this side agent.")
        .accessibilityAddTraits(.isButton)
    }

    private var openStateMarker: some View {
        Capsule(style: .continuous)
            .fill(DS.Colors.accentText.opacity(isActive ? 0.96 : 0.78))
            .frame(width: 3, height: 18)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.surface1.opacity(0.72), lineWidth: 0.6)
            )
            .shadow(color: DS.Colors.accentText.opacity(0.22), radius: 2, x: 0, y: 0)
            .accessibilityHidden(true)
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
            scheduleArchiveHoldFeedbackStart()
        } else if !didCompleteArchiveHold {
            cancelArchiveHoldFeedback()
        }
    }

    private func scheduleArchiveHoldFeedbackStart() {
        archiveFeedbackStartTask?.cancel()
        didCompleteArchiveHold = false
        archiveProgress = 0
        archiveFeedbackStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PickyHUDArchiveHoldPolicy.feedbackStartDelayNanoseconds)
            guard !Task.isCancelled else { return }
            archiveFeedbackStartTask = nil
            beginArchiveHoldFeedback()
        }
    }

    private func beginArchiveHoldFeedback() {
        isArchivePressing = true
        withAnimation(.linear(duration: PickyHUDArchiveHoldPolicy.feedbackAnimationDuration)) {
            archiveProgress = 1
        }
    }

    private func cancelArchiveHoldFeedback() {
        archiveFeedbackStartTask?.cancel()
        archiveFeedbackStartTask = nil
        isArchivePressing = false
        withAnimation(.easeOut(duration: 0.18)) {
            archiveProgress = 0
        }
    }

    private func completeArchiveHold() {
        archiveFeedbackStartTask?.cancel()
        archiveFeedbackStartTask = nil
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

// MARK: - Dock icon clicks (AppKit-backed for immediate single-click open)

private struct PickyHUDDockIconClickHost: NSViewRepresentable {
    var onHover: () -> Void
    var onOpen: () -> Void
    var onPin: () -> Void
    var onArchivePressing: (Bool) -> Void
    var onArchive: () -> Void

    final class Coordinator {
        var onHover: (() -> Void)?
        var onOpen: (() -> Void)?
        var onPin: (() -> Void)?
        var onArchivePressing: ((Bool) -> Void)?
        var onArchive: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHover = onHover
        context.coordinator.onOpen = onOpen
        context.coordinator.onPin = onPin
        context.coordinator.onArchivePressing = onArchivePressing
        context.coordinator.onArchive = onArchive
        let view = PickyHUDDockIconClickNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHover = onHover
        context.coordinator.onOpen = onOpen
        context.coordinator.onPin = onPin
        context.coordinator.onArchivePressing = onArchivePressing
        context.coordinator.onArchive = onArchive
    }
}

private final class PickyHUDDockIconClickNSView: NSView {
    weak var coordinator: PickyHUDDockIconClickHost.Coordinator?
    private var trackingArea: NSTrackingArea?
    private var archiveWorkItem: DispatchWorkItem?
    private var mouseDownPoint: NSPoint?
    private var didCompleteArchiveHold = false

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didCompleteArchiveHold = false
        guard event.clickCount == 1 else { return }
        coordinator?.onArchivePressing?(true)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.didCompleteArchiveHold = true
            self.coordinator?.onArchive?()
        }
        archiveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PickyHUDArchiveHoldPolicy.duration, execute: item)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint, archiveWorkItem != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > PickyHUDArchiveHoldPolicy.maximumDistance {
            cancelArchiveHoldFeedback()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedArchive = didCompleteArchiveHold
        cancelArchiveHoldFeedback()
        mouseDownPoint = nil
        didCompleteArchiveHold = false
        guard !completedArchive else { return }
        if event.clickCount >= 2 {
            coordinator?.onPin?()
        } else {
            coordinator?.onOpen?()
        }
    }

    private func cancelArchiveHoldFeedback() {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        coordinator?.onArchivePressing?(false)
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Dock anchor handle (AppKit-backed for reliable hit testing)

/// AppKit-backed handle for dragging the HUD dock's vertical anchor. Wrapping an
/// `NSView` directly avoids SwiftUI's transparent-view hit-testing quirks: AppKit's
/// `hitTest`, `NSTrackingArea`, and `addCursorRect` all key off the same NSView
/// bounds, so click + hover + cursor reliably react to the entire frame instead of
/// just the visible 22×4 capsule that SwiftUI's gesture system kept latching onto.
private struct PickyHUDDockAnchorHandleHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void

    final class Coordinator {
        var onHoverChanged: ((Bool) -> Void)?
        var onDragChanged: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        let view = PickyHUDDockAnchorHandleNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
    }
}

private final class PickyHUDDockAnchorHandleNSView: NSView {
    weak var coordinator: PickyHUDDockAnchorHandleHost.Coordinator?
    private var dragStartScreenY: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var hasClosedHandPushed = false

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capture all hits inside our bounds. Without this, AppKit could fall
        // through to a sibling/parent view if some subview opts out.
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenY = NSEvent.mouseLocation.y
        if !hasClosedHandPushed {
            NSCursor.closedHand.push()
            hasClosedHandPushed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startY = dragStartScreenY else { return }
        let delta = NSEvent.mouseLocation.y - startY
        coordinator?.onDragChanged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        if hasClosedHandPushed {
            NSCursor.pop()
            hasClosedHandPushed = false
        }
        dragStartScreenY = nil
        coordinator?.onDragEnded?()
    }

    override var acceptsFirstResponder: Bool { false }
}

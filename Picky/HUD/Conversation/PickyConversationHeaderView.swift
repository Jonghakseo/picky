//
//  PickyConversationHeaderView.swift
//  Picky
//
//  Header for the conversation-style Pickle card.
//

import SwiftUI

/// Visual + timing parameters for the header Pickle-badge long-press that
/// promotes the armed Pickle to sticky mode. Mirrors
/// `PickyHUDArchiveHoldPolicy` so both gestures feel consistent.
enum PickyConversationStickyArmHoldPolicy {
    static let duration: TimeInterval = 1.0
    static let feedbackStartDelay: TimeInterval = 0.15
    static let feedbackStartDelayNanoseconds: UInt64 = 150_000_000
    static let maximumDistance: CGFloat = 8
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73

    static var feedbackAnimationDuration: TimeInterval {
        max(0, duration - feedbackStartDelay)
    }
}

struct PickyConversationHeaderView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    /// Observed separately from `viewModel` so cursor enter/exit on the
    /// conversation card only invalidates this header (which reads the value
    /// for the pi-badge active-voice highlight) rather than every conversation
    /// subview observing the viewModel. Defaults to the viewModel's own store
    /// via the explicit init below so existing call sites (and tests) keep
    /// working without passing the parameter explicitly.
    @ObservedObject var voiceFollowUpHoverState: PickyVoiceFollowUpHoverState
    let session: PickySessionListViewModel.SessionCard
    var onArchiveSession: (String) -> Void = { _ in }
    var isCommandShortcutHintVisible = false

    init(
        viewModel: PickySessionListViewModel,
        session: PickySessionListViewModel.SessionCard,
        onArchiveSession: @escaping (String) -> Void = { _ in },
        isCommandShortcutHintVisible: Bool = false,
        voiceFollowUpHoverState: PickyVoiceFollowUpHoverState? = nil
    ) {
        self.viewModel = viewModel
        self.voiceFollowUpHoverState = voiceFollowUpHoverState ?? viewModel.voiceFollowUpHoverState
        self.session = session
        self.onArchiveSession = onArchiveSession
        self.isCommandShortcutHintVisible = isCommandShortcutHintVisible
    }

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var isTitleHovered = false
    @State private var stickyHoldFeedbackStartTask: Task<Void, Never>?
    @State private var isStickyHolding = false
    @State private var stickyHoldProgress: Double = 0
    @State private var didCompleteStickyHold = false
    @FocusState private var isTitleFieldFocused: Bool

    private var isVoiceFollowUpTarget: Bool {
        if let activeVoiceFollowUpSessionID = viewModel.activeVoiceFollowUpSessionID {
            return activeVoiceFollowUpSessionID == session.id
        }
        return voiceFollowUpHoverState.sessionID == session.id
    }

    private var isScreenContextArmed: Bool {
        viewModel.screenContextTargetSessionID == session.id
    }

    private var isScreenContextStickyArmed: Bool {
        isScreenContextArmed && viewModel.screenContextTargetSticky
    }

    var body: some View {
        let _ = PickyPerf.event("conversation_header_body")
        HStack(alignment: .center, spacing: 8) {
            leadingTitle
            trailingActions
        }
        .frame(width: PickyHUDDockLayout.detailContentWidth(for: pickyHUDDetailWidth), alignment: .trailing)
        .frame(minHeight: 26, alignment: .trailing)
    }

    private var leadingTitle: some View {
        HStack(alignment: .center, spacing: 7) {
            piBadgeSlot
            titleContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var titleContent: some View {
        if isEditingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.title)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($isTitleFieldFocused)
                .onAppear { focusAndSelectTitleField() }
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: isTitleFieldFocused) { _, focused in
                    // Treat blur as a commit so dragging focus away keeps the edit.
                    // commitTitleEdit clears isEditingTitle first to make this re-entry safe.
                    if !focused && isEditingTitle { commitTitleEdit() }
                }
                .accessibilityLabel("Pickle title")
                .accessibilityHint("Enter to rename, Escape to cancel")
        } else {
            Text(session.title)
                .font(PickyHUDTypography.title)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DS.Colors.surface2.opacity(isTitleHovered ? 0.65 : 0))
                )
                .contentShape(Rectangle())
                .onHover { isTitleHovered = $0 }
                .pointerCursor()
                .onTapGesture(count: 2) { beginTitleEdit() }
                .nativeTooltip(titleHelpText)
                .accessibilityHint(titleHelpText)
        }
    }

    private func beginTitleEdit() {
        titleDraft = session.title
        isEditingTitle = true
        // Focus + selection is driven by the TextField's own .onAppear so that
        // both the @FocusState routing and the NSTextField field editor land
        // before we ask AppKit to select the text.
    }

    private func focusAndSelectTitleField() {
        // Route focus on the next runloop tick so the TextField is in the
        // hierarchy when @FocusState applies. Then wait one more tick so the
        // backing NSTextField has installed its field editor as the window's
        // first responder, and select the prefilled title so a single keystroke
        // replaces it (matches Finder/macOS native inline-rename UX).
        DispatchQueue.main.async {
            isTitleFieldFocused = true
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            }
        }
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        isTitleFieldFocused = false
        titleDraft = ""
    }

    func commitTitleEdit() {
        guard isEditingTitle else { return }
        let command = Self.renameCommandText(forNewTitle: titleDraft, current: session.title)
        let sessionID = session.id
        let status = session.status
        isEditingTitle = false
        isTitleFieldFocused = false
        titleDraft = ""
        guard let command else { return }
        Task { try? await sendRenameCommand(command, sessionID: sessionID, status: status) }
    }

    static func renameCommandText(forNewTitle newTitle: String, current: String) -> String? {
        let trimmedNew = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return nil }
        if trimmedNew == current.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return "/name \(trimmedNew)"
    }

    private func sendRenameCommand(_ text: String, sessionID: String, status: PickySessionStatus) async throws {
        switch status {
        case .running, .queued, .waiting_for_input, .cancelled, .failed:
            try await viewModel.steer(text: text, sessionID: sessionID)
        case .completed, .blocked:
            try await viewModel.followUp(text: text, sessionID: sessionID)
        }
    }

    private var trailingActions: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsHeaderSessionMeta {
                PickyHeaderSessionMetaPill(
                    assistantRun: latestAssistantRun,
                    contextUsage: session.contextUsage,
                    onCycleModel: { cycleModel() },
                    onCycleThinkingLevel: { cycleThinkingLevel() }
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            conversationMenuButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var showsHeaderSessionMeta: Bool {
        latestAssistantRun?.hasHeaderText == true || session.contextUsage != nil
    }

    private var latestAssistantRun: PickyAssistantRunMetadata? {
        session.currentAssistantRun ?? session.messages.reversed().compactMap(\.assistantRun).first
    }

    var titleHelpText: String {
        "Double-click to rename · or use /name <new title>"
    }

    private var conversationMenuButton: some View {
        Menu {
            PickyConversationMenu(
                session: session,
                viewModel: viewModel,
                onArchive: { onArchiveSession(session.id) }
            )
        } label: {
            Image(systemName: "ellipsis")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .frame(width: 18, height: 18)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Conversation menu")
    }

    private var piBadgeSlot: some View {
        piBadge
            .overlay(alignment: .bottomTrailing) {
                if !isScreenContextArmed, isVoiceFollowUpTarget {
                    voiceTargetMicBadge
                }
            }
            .overlay(alignment: .center) {
                stickyHoldProgressRing
            }
            .overlay(alignment: .topLeading) {
                if isScreenContextStickyArmed {
                    stickyArmLockBadge
                        .offset(x: -4, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .pointerCursor()
            .onTapGesture { handleBadgeTap() }
            .onLongPressGesture(
                minimumDuration: PickyConversationStickyArmHoldPolicy.duration,
                maximumDistance: PickyConversationStickyArmHoldPolicy.maximumDistance,
                perform: { completeStickyHold() },
                onPressingChanged: { handleStickyHoldPressing($0) }
            )
            .onDisappear { cancelStickyHoldFeedback() }
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isScreenContextStickyArmed)
            .overlay(alignment: .topTrailing) {
                screenContextShortcutBadge
                    .offset(x: 11, y: -8)
                    .opacity(isCommandShortcutHintVisible ? 1 : 0)
                    .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                    .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                    .allowsHitTesting(false)
            }
            .help(piBadgeHelpText)
            .accessibilityLabel(piBadgeAccessibilityLabel)
            .accessibilityAction(named: Text("Toggle Pickle target")) { handleBadgeTap() }
            .accessibilityAction(named: Text("Lock Pickle as sticky target")) {
                viewModel.armScreenContextTarget(sessionID: session.id, sticky: true)
            }
    }

    private var stickyHoldProgressRing: some View {
        ZStack {
            stickyHoldRingArc(progress: 1)
                .opacity(0.18)
            stickyHoldRingArc(progress: stickyHoldProgress)
        }
        .frame(width: 28, height: 28)
        .opacity(isStickyHolding || stickyHoldProgress > 0 ? 1 : 0)
        .shadow(color: DS.Colors.accentText.opacity(0.34), radius: 4, x: 0, y: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stickyHoldRingArc(progress: Double) -> some View {
        Circle()
            .trim(
                from: PickyConversationStickyArmHoldPolicy.ringGapStartFraction,
                to: PickyConversationStickyArmHoldPolicy.ringGapStartFraction
                    + (max(0, min(progress, 1)) * PickyConversationStickyArmHoldPolicy.ringUsableFraction)
            )
            .stroke(
                DS.Colors.accentText,
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
            .rotationEffect(.degrees(-90))
    }

    private var stickyArmLockBadge: some View {
        Image(systemName: "lock.fill")
            .pickyFont(size: 6.8, weight: .bold)
            .foregroundColor(DS.Colors.accentText)
            .frame(width: 11, height: 11)
            .background(Circle().fill(DS.Colors.surface1))
            .overlay(Circle().stroke(DS.Colors.accentText.opacity(0.78), lineWidth: 0.9))
            .accessibilityHidden(true)
    }

    private func handleBadgeTap() {
        // The tap fires even when the long-press completed, so guard against
        // immediately undoing the sticky promotion the user just made.
        if didCompleteStickyHold {
            didCompleteStickyHold = false
            return
        }
        viewModel.toggleScreenContextTarget(sessionID: session.id)
    }

    private func handleStickyHoldPressing(_ isPressing: Bool) {
        if isPressing {
            scheduleStickyHoldFeedbackStart()
        } else if !didCompleteStickyHold {
            cancelStickyHoldFeedback()
        }
    }

    private func scheduleStickyHoldFeedbackStart() {
        stickyHoldFeedbackStartTask?.cancel()
        didCompleteStickyHold = false
        stickyHoldProgress = 0
        stickyHoldFeedbackStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PickyConversationStickyArmHoldPolicy.feedbackStartDelayNanoseconds)
            guard !Task.isCancelled else { return }
            stickyHoldFeedbackStartTask = nil
            beginStickyHoldFeedback()
        }
    }

    private func beginStickyHoldFeedback() {
        isStickyHolding = true
        withAnimation(.linear(duration: PickyConversationStickyArmHoldPolicy.feedbackAnimationDuration)) {
            stickyHoldProgress = 1
        }
    }

    private func cancelStickyHoldFeedback() {
        stickyHoldFeedbackStartTask?.cancel()
        stickyHoldFeedbackStartTask = nil
        isStickyHolding = false
        withAnimation(.easeOut(duration: 0.18)) {
            stickyHoldProgress = 0
        }
    }

    private func completeStickyHold() {
        stickyHoldFeedbackStartTask?.cancel()
        stickyHoldFeedbackStartTask = nil
        didCompleteStickyHold = true
        stickyHoldProgress = 1
        isStickyHolding = false
        viewModel.armScreenContextTarget(sessionID: session.id, sticky: true)
        // Fade the ring out shortly after the lock badge appears so the badge
        // is the primary signal that the gesture succeeded.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeOut(duration: 0.18)) {
                stickyHoldProgress = 0
            }
        }
    }

    private var screenContextShortcutBadge: some View {
        HStack(spacing: 1.5) {
            Image(systemName: "command")
                .pickyFont(size: 6.5, weight: .bold)
            Text("K")
                .pickyFont(size: 7.5, weight: .bold, design: .rounded)
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.70))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }

    private var voiceTargetMicBadge: some View {
        Image(systemName: "mic.fill")
            .pickyFont(size: 6.8, weight: .bold)
            .foregroundColor(DS.Colors.accentText)
            .frame(width: 11, height: 11)
            .background(Circle().fill(DS.Colors.surface1))
            .overlay(Circle().stroke(DS.Colors.accentText.opacity(0.65), lineWidth: 0.9))
            .offset(x: 3, y: 3)
    }

    private var piBadge: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isScreenContextArmed ? DS.Colors.accentSubtle.opacity(0.46) : statusColor.opacity(statusFillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isScreenContextArmed ? DS.Colors.accentText.opacity(0.82) : statusColor.opacity(0.38), lineWidth: isScreenContextArmed ? 1.15 : 0.8)
            )
            .frame(width: 22, height: 22)
            .overlay {
                if isScreenContextArmed {
                    Image("PickyCursorNormal")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(DS.Colors.accentText)
                        .scaledToFit()
                        .frame(width: 15.5, height: 15.5)
                } else {
                    PickleLogoGlyph()
                        .fill(statusColor, style: FillStyle(eoFill: true))
                        .frame(width: 15, height: 15)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isScreenContextArmed {
                    statusCornerIndicator
                }
            }
    }

    @ViewBuilder
    private var statusCornerIndicator: some View {
        switch session.status {
        case .running:
            Circle()
                .fill(statusColor)
                .frame(width: 7.5, height: 7.5)
                .overlay(Circle().stroke(DS.Colors.surface1, lineWidth: 1.4))
                .offset(x: 2.8, y: -2.8)
        case .waiting_for_input, .blocked:
            attentionIndicator("!")
                .offset(x: 3.2, y: -3.2)
        case .failed:
            attentionIndicator("×")
                .offset(x: 3.2, y: -3.2)
        case .completed, .cancelled, .queued:
            EmptyView()
        }
    }

    private func attentionIndicator(_ text: String) -> some View {
        Text(text)
            .pickyFont(size: 7.2, weight: .bold, design: .monospaced)
            .foregroundColor(.white)
            .frame(width: 10, height: 10)
            .background(Circle().fill(statusColor))
            .overlay(Circle().stroke(DS.Colors.surface1, lineWidth: 1.4))
    }

    private var statusFillOpacity: Double {
        switch session.status {
        case .running: return 0.22
        case .completed, .waiting_for_input, .failed, .blocked: return 0.18
        case .queued, .cancelled: return 0.13
        }
    }

    private var piBadgeHelpText: String {
        if isScreenContextStickyArmed {
            return "Pickle cursor is locked. Every Picky voice or quick text input keeps going to this Pickle until you click again or arm another. Long-press another Pickle to switch."
        }
        if isScreenContextArmed {
            return "Pickle cursor is armed. The next Picky voice or quick text input goes directly to this Pickle. Click or press ⌘K to cancel, or long-press to lock."
        }
        if isVoiceFollowUpTarget { return "\(statusDescription). Voice steering target" }
        return "\(statusDescription). Click or press ⌘K to route the next Picky screen-context input to this Pickle. Long-press to lock it as the sticky target."
    }

    private var piBadgeAccessibilityLabel: String {
        if isScreenContextStickyArmed { return "Session status: \(statusDescription), Pickle cursor locked" }
        if isScreenContextArmed { return "Session status: \(statusDescription), Pickle cursor armed" }
        return isVoiceFollowUpTarget ? "Session status: \(statusDescription), voice steering target" : "Session status: \(statusDescription)"
    }

    private var statusDescription: String {
        switch session.status {
        case .running: return "Working"
        case .completed: return "Done"
        case .waiting_for_input: return "Waiting for input"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .cancelled: return "Cancelled"
        case .queued: return "Queued"
        }
    }

    var statusColorName: String {
        switch session.status {
        case .running:
            return "blue"
        case .completed:
            return "green"
        case .waiting_for_input:
            return "amber"
        case .failed:
            return "red"
        case .blocked:
            return "warning"
        case .queued, .cancelled:
            return "tertiary"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .completed:
            return DS.Colors.success
        case .waiting_for_input:
            return DS.Colors.warning
        case .failed:
            return DS.Colors.destructiveText
        case .blocked:
            return DS.Colors.warningText
        case .queued, .cancelled:
            return DS.Colors.textTertiary
        }
    }

    private func cycleThinkingLevel() {
        Task { try? await viewModel.cycleThinkingLevel(sessionID: session.id) }
    }

    private func cycleModel() {
        Task { try? await viewModel.cycleModel(sessionID: session.id) }
    }
}

struct PickleLogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 512
        let xOffset = rect.midX - 256 * scale
        let yOffset = rect.midY - 256 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
        }

        var path = Path()
        path.move(to: point(481, 195.71))
        path.addLines([
            point(435.32, 152.47),
            point(420.72, 91.29),
            point(359.54, 76.69),
            point(316.30, 31.01),
            point(256.01, 48.95),
            point(195.72, 31.01),
            point(152.48, 76.69),
            point(91.30, 91.29),
            point(76.70, 152.47),
            point(31.02, 195.71),
            point(48.96, 256.00),
            point(31.02, 316.29),
            point(76.70, 359.53),
            point(91.30, 420.71),
            point(152.48, 435.31),
            point(195.72, 480.99),
            point(256.01, 463.05),
            point(316.30, 480.99),
            point(359.54, 435.31),
            point(420.72, 420.71),
            point(435.32, 359.53),
            point(481.00, 316.29),
            point(463.06, 256.00),
            point(481.00, 195.71)
        ])
        path.closeSubpath()

        addEye(to: &path, centerX: 179.10, point: point)
        addEye(to: &path, centerX: 332.90, point: point)
        return path
    }

    private func addEye(
        to path: inout Path,
        centerX: CGFloat,
        point: (CGFloat, CGFloat) -> CGPoint
    ) {
        let leftX = centerX - 37.91
        let rightX = centerX + 37.91
        path.move(to: point(centerX, 291.39))
        path.addCurve(
            to: point(leftX, 244.00),
            control1: point(centerX - 20.94, 291.39),
            control2: point(leftX, 270.17)
        )
        path.addCurve(
            to: point(centerX, 196.61),
            control1: point(leftX, 217.83),
            control2: point(centerX - 20.94, 196.61)
        )
        path.addCurve(
            to: point(rightX, 244.00),
            control1: point(centerX + 20.94, 196.61),
            control2: point(rightX, 217.83)
        )
        path.addCurve(
            to: point(centerX, 291.39),
            control1: point(rightX, 270.17),
            control2: point(centerX + 20.94, 291.39)
        )
        path.closeSubpath()
    }
}

private struct PickyHeaderSessionMetaPill: View {
    let assistantRun: PickyAssistantRunMetadata?
    let contextUsage: PickyContextUsage?
    let onCycleModel: () -> Void
    let onCycleThinkingLevel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let contextDisplay {
                PickyHeaderContextUsageBar(display: contextDisplay)
                    .frame(width: 24, height: 5)
                Text(contextDisplay.label)
                    .fontWeight(.bold)
                if modelText != nil || thinkingLevelText != nil {
                    separator
                }
            }
            if let modelText {
                Button(action: onCycleModel) {
                    Text(modelText)
                        .foregroundColor(tint.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Cycle scoped model (⌃P)")
            }
            if modelText != nil, thinkingLevelText != nil {
                separator
            }
            if let thinkingLevelText {
                Button(action: onCycleThinkingLevel) {
                    Text(thinkingLevelText)
                        .foregroundColor(tint.opacity(0.92))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Cycle thinking level (⇧Tab)")
            }
        }
        .font(PickyHUDTypography.metaMonospacedMedium)
        .foregroundColor(tint.opacity(0.88))
        .lineLimit(1)
        .help(helpText)
    }

    private var separator: some View {
        Circle()
            .fill(tint.opacity(0.55))
            .frame(width: 3, height: 3)
    }

    private var contextDisplay: PickyHeaderContextUsageDisplay? {
        contextUsage.map(PickyHeaderContextUsageDisplay.init(usage:))
    }

    private var modelText: String? {
        assistantRun?.headerModelText
    }

    private var thinkingLevelText: String? {
        assistantRun?.headerThinkingLevelText
    }

    private var tint: Color {
        contextDisplay?.color ?? DS.Colors.textTertiary
    }

    private var helpText: String {
        var parts: [String] = []
        if let contextDisplay {
            parts.append(contextDisplay.tooltip)
        }
        if let modelText {
            parts.append("Model: \(modelText)")
        }
        if let thinkingLevelText {
            parts.append("Thinking: \(thinkingLevelText)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct PickyHeaderContextUsageBar: View {
    let display: PickyHeaderContextUsageDisplay

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.surface2.opacity(0.85))
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
    }
}

private struct PickyHeaderContextUsageDisplay {
    let fraction: Double
    let label: String
    let color: Color
    let tooltip: String
    let isKnown: Bool

    init(usage: PickyContextUsage) {
        guard let percent = usage.percent else {
            self.fraction = 0
            self.label = "?%"
            self.color = DS.Colors.textTertiary
            self.tooltip = "Context usage unknown after compaction until the next model response"
            self.isKnown = false
            return
        }

        let clamped = max(0, min(100, percent))
        self.fraction = clamped / 100
        self.label = "\(Int(clamped.rounded()))%"
        switch clamped {
        case 90...:
            self.color = DS.Colors.destructive
        case 70..<90:
            self.color = DS.Colors.warning
        default:
            self.color = DS.Colors.success
        }
        if let tokens = usage.tokens {
            self.tooltip = "Context usage: \(tokens.formatted())/\(usage.contextWindow.formatted()) tokens (\(Int(clamped.rounded()))%)"
        } else {
            self.tooltip = "Context usage: \(Int(clamped.rounded()))% of \(usage.contextWindow.formatted()) tokens"
        }
        self.isKnown = true
    }
}

private extension PickyAssistantRunMetadata {
    var hasHeaderText: Bool {
        headerModelText != nil || headerThinkingLevelText != nil
    }

    var headerModelText: String? {
        guard let model else { return nil }
        let leaf = model.split(separator: "/").last.map(String.init) ?? model
        let compact = ["claude-", "openai-"].reduce(leaf) { partial, prefix in
            partial.hasPrefix(prefix) ? String(partial.dropFirst(prefix.count)) : partial
        }
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var headerThinkingLevelText: String? {
        guard let thinkingLevel else { return nil }
        let trimmed = thinkingLevel.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class PickyHUDSizeReporter {
    private let coalescingDelayNanoseconds: UInt64

    private var lastReportedHUDSize: CGSize = .zero
    private var lastReportedActiveSessionID: String?
    private var lastReportedExtensionUiRequestID: String?
    private var pendingReportTask: Task<Void, Never>?
    private var pendingReportedSize: CGSize?
    private var pendingOnSizeChange: ((CGSize) -> Void)?

    init(coalescingDelayNanoseconds: UInt64 = 16_000_000) {
        self.coalescingDelayNanoseconds = coalescingDelayNanoseconds
    }

    func handleMeasuredSize(
        _ measuredSize: CGSize,
        activeSessionID: String?,
        extensionUiRequestID: String? = nil,
        shouldHoldHeight: Bool,
        onSizeChange: @escaping (CGSize) -> Void
    ) {
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }

        let activeSessionChanged = activeSessionID != lastReportedActiveSessionID
        if activeSessionChanged {
            lastReportedActiveSessionID = activeSessionID
        }
        // A pending extension-UI request closing (e.g., AskUserQuestion answered) collapses
        // the question bubble by hundreds of points in a single layout pass. The status is
        // still `.running` so `shouldHoldHeight` would otherwise pin the panel at the prior
        // tall size, leaving a large empty band above the conversation list. Treat any
        // change to the active question id (in particular non-nil -> nil) as a one-shot
        // release of the hold so the panel can shrink to the new measured content height.
        let extensionUiRequestChanged = extensionUiRequestID != lastReportedExtensionUiRequestID
        if extensionUiRequestChanged {
            lastReportedExtensionUiRequestID = extensionUiRequestID
        }
        let releaseHold = activeSessionChanged || extensionUiRequestChanged

        let targetSize = PickyHUDExpansion.reportedHUDSize(
            measuredSize: measuredSize,
            previousReportedSize: lastReportedHUDSize,
            activeSessionChanged: releaseHold,
            shouldHoldHeight: shouldHoldHeight
        )

        guard releaseHold || !lastReportedHUDSize.isApproximatelyEqual(to: targetSize) else { return }
        let shouldGrowPanelImmediately = lastReportedHUDSize.height > 0
            && targetSize.height > lastReportedHUDSize.height + 1
        lastReportedHUDSize = targetSize

        if releaseHold || shouldGrowPanelImmediately {
            // First hover opens the conversation card while the NSPanel is still at
            // its dock-only collapsed height. If we coalesce this resize for a frame,
            // SwiftUI can draw the newly inserted ScrollView/TextEditor against the
            // stale panel bounds, exposing transient pre-scroll layout outside the
            // card. The same rule applies to in-card expansions (for example, opening
            // a collapsed turn): SwiftUI starts laying out the taller subtree in the
            // current transaction, so the transparent outer panel must grow before the
            // next frame instead of after the coalescing delay. Keep coalescing for
            // shrink/steady churn after the card is visible.
            cancelPendingReport()
            onSizeChange(targetSize)
            return
        }

        scheduleReport(targetSize, onSizeChange: onSizeChange)
    }

    func cancelPendingReport() {
        pendingReportTask?.cancel()
        pendingReportTask = nil
        pendingReportedSize = nil
        pendingOnSizeChange = nil
    }

    private func scheduleReport(_ size: CGSize, onSizeChange: @escaping (CGSize) -> Void) {
        pendingReportedSize = size
        pendingOnSizeChange = onSizeChange
        pendingReportTask?.cancel()
        pendingReportTask = Task { @MainActor [weak self] in
            guard let delay = self?.coalescingDelayNanoseconds else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            guard let reportedSize = self.pendingReportedSize, let onSizeChange = self.pendingOnSizeChange else { return }
            self.pendingReportTask = nil
            self.pendingReportedSize = nil
            self.pendingOnSizeChange = nil
            onSizeChange(reportedSize)
        }
    }
}

struct PickyHUDSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct PickyHUDCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct PickyHUDSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PickyHUDSizePreferenceKey.self, value: proxy.size)
        }
    }
}

struct PickyHUDCardSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PickyHUDCardSizePreferenceKey.self, value: proxy.size)
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

extension CGSize {
    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

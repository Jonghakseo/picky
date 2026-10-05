//
//  PickyUsageStatusItemsController.swift
//  Picky
//
//  One menu bar item per provider the user pinned in Hub > Statistics > AI
//  usage. Each shows the provider logo with the remaining session/weekly share
//  and opens that Hub tab on click. The Picky item stays to the left of them.
//

import AppKit
import Combine

@MainActor
final class PickyUsageStatusItemsController {
    private let store: PickyUsageLimitsStore
    private let openUsage: () -> Void
    /// Called after usage items were added or removed. macOS inserts a new
    /// status item to the left of existing ones, so the Picky item must be
    /// recreated afterwards to stay leftmost.
    private let didChangeItemSet: () -> Void
    private var items: [PickyUsageLimitsProviderID: NSStatusItem] = [:]
    private var visibleOrder: [PickyUsageLimitsProviderID] = []
    private var cancellable: AnyCancellable?

    init(store: PickyUsageLimitsStore, openUsage: @escaping () -> Void, didChangeItemSet: @escaping () -> Void) {
        self.store = store
        self.openUsage = openUsage
        self.didChangeItemSet = didChangeItemSet
        // @Published emits before the property changes; hop a run loop turn so
        // `update()` reads the new values.
        cancellable = store.$snapshot.map { _ in () }
            .merge(with: store.$pinnedProviders.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
    }

    func update() {
        let providers = store.menuBarProviders
        let order = providers.map(\.provider)
        if order != visibleOrder {
            items.values.forEach { NSStatusBar.system.removeStatusItem($0) }
            items = [:]
            // Created right to left so they read Claude, ChatGPT from the left.
            for id in order.reversed() {
                items[id] = makeItem()
            }
            visibleOrder = order
            didChangeItemSet()
        }
        for provider in providers {
            guard let button = items[provider.provider]?.button else { continue }
            button.image = PickyUsageStatusItemRenderer.image(for: provider)
            let label = PickyUsageStatusItemRenderer.accessibilityLabel(for: provider)
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(itemClicked)
        item.button?.imagePosition = .imageOnly
        return item
    }

    @objc private func itemClicked() {
        openUsage()
    }
}

enum PickyUsageStatusItemRenderer {
    static func accessibilityLabel(for provider: PickyUsageLimitsProvider) -> String {
        L10n.t(
            "usageLimits.menuBar.accessibility",
            provider.provider.displayName,
            PickyUsageLimitsPresentation.remainingText(provider.session),
            PickyUsageLimitsPresentation.remainingText(provider.weekly)
        )
    }

    /// Template image: logo plus the remaining share. Session and weekly stack
    /// when both exist; a plan with one window shows that value alone.
    static func image(for provider: PickyUsageLimitsProvider) -> NSImage {
        let height = max(NSStatusBar.system.thickness, 22)
        let logoSize: CGFloat = 16
        let gap: CGFloat = 4
        let lines: [String]
        let font: NSFont
        if provider.session != nil, provider.weekly != nil {
            lines = [PickyUsageLimitsPresentation.shortRemainingText(provider.session), PickyUsageLimitsPresentation.shortRemainingText(provider.weekly)]
            font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        } else {
            lines = [PickyUsageLimitsPresentation.shortRemainingText(provider.session ?? provider.weekly)]
            font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let textWidth = ceil(sizes.map(\.width).max() ?? 0)
        let lineHeight = font.ascender - font.descender
        let size = NSSize(width: logoSize + gap + textWidth, height: height)
        let logo = NSImage(named: provider.provider.logoAssetName)

        let image = NSImage(size: size, flipped: false) { _ in
            logo?.draw(in: NSRect(x: 0, y: (height - logoSize) / 2, width: logoSize, height: logoSize))
            let blockHeight = lineHeight * CGFloat(lines.count) - (lines.count > 1 ? 1 : 0)
            var y = (height + blockHeight) / 2 - lineHeight
            for line in lines {
                (line as NSString).draw(at: NSPoint(x: logoSize + gap, y: y), withAttributes: attributes)
                y -= lineHeight - 1
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

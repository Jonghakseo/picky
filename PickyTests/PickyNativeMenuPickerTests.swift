import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyNativeMenuPickerTests {
    @Test func focusOnlyUpdatesDoNotMutateNativeMenuItems() throws {
        let fixture = MenuFixture()
        let button = try fixture.button()
        let menu = try #require(button.menu)
        let items = menu.items
        var mutations = 0
        let notifications = [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification]
        let observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: menu, queue: .main) { _ in
                MainActor.assumeIsolated { mutations += 1 }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        // A work budget, not a machine-dependent timing threshold. Also exercise
        // repeated parent updates, which must not reconstruct a stable menu.
        for index in 0..<100 {
            fixture.active = index.isMultiple(of: 2)
            fixture.render()
        }
        #expect(try fixture.button() === button)
        #expect(button.menu === menu)
        #expect(zip(button.itemArray, items).allSatisfy { $0 === $1 })
        #expect(mutations == 0)
        #expect(button.itemTitles == ["First", "Second"])
        #expect(fixture.writes == 0)
        fixture.options[0] = .init(value: 1, title: "Updated")
        fixture.render()
        #expect(mutations > 0, "The observer must detect a real label mutation, not silently miss all updates")
    }

    @Test func selectionAndEnabledUpdatesKeepTheMenuAndDoNotWriteBack() throws {
        let fixture = MenuFixture()
        let button = try fixture.button()
        let items = button.itemArray
        fixture.value = 2
        fixture.enabled = false
        fixture.render()
        #expect(button.titleOfSelectedItem == "Second")
        #expect(!button.isEnabled)
        #expect(zip(button.itemArray, items).allSatisfy { $0 === $1 })
        #expect(fixture.writes == 0)
        #expect(button.accessibilityLabel() == "Choice")
        let accessible = NSAccessibility.unignoredDescendant(of: button)
        #expect(PickyHubAccessibilityObservation.legacyValue(.role, of: accessible) as? String == NSAccessibility.Role.popUpButton.rawValue)
        #expect(PickyHubAccessibilityObservation.legacyValue(.value, of: accessible) as? String == "Second")
        fixture.enabled = true
        fixture.render()
        button.selectItem(at: 0)
        #expect(button.sendAction(button.action, to: button.target))
        #expect(fixture.value == 1)
        #expect(fixture.writes == 1)
        _ = button.sendAction(button.action, to: button.target)
        #expect(fixture.writes == 1, "Re-selecting the current value must not dispatch another settings write")
    }

    @Test func translatedLabelsUpdateInPlaceAndDynamicOptionsRetainSelectionByValue() throws {
        let fixture = MenuFixture()
        let button = try fixture.button()
        let menu = button.menu
        let first = button.item(at: 0)
        fixture.title = "선택"
        fixture.options = [.init(value: 1, title: "첫 번째"), .init(value: 2, title: "두 번째")]
        fixture.render()
        #expect(button.menu === menu)
        #expect(button.item(at: 0) === first)
        #expect(button.itemTitles == ["첫 번째", "두 번째"])
        #expect(button.accessibilityLabel() == "선택")
        fixture.options = [.init(value: 2, title: "같은 이름"), .init(value: 1, title: "같은 이름")]
        fixture.render()
        #expect(button.numberOfItems == 2, "Duplicate labels must not discard distinct option values")
        #expect(button.indexOfSelectedItem == 1)
        button.selectItem(at: 0)
        _ = button.sendAction(button.action, to: button.target)
        #expect(fixture.value == 2)
        #expect(fixture.writes == 1)
    }

    @Test func unavailableSelectionAndEmptyOptionsNeverOverwriteTheStoredValue() throws {
        let fixture = MenuFixture()
        fixture.value = 99
        fixture.render()
        let button = try fixture.button()
        #expect(button.indexOfSelectedItem == -1)
        #expect(fixture.value == 99)
        fixture.options = []
        fixture.render()
        #expect(button.numberOfItems == 0)
        #expect(!button.isEnabled)
        #expect(fixture.value == 99)
        #expect(fixture.writes == 0)
        fixture.options = [.init(value: 99, title: "Saved option")]
        fixture.render()
        #expect(button.titleOfSelectedItem == "Saved option")
        #expect(button.isEnabled)
    }

    @Test func fontScaleChangesDoNotRebuildOptions() throws {
        let fixture = MenuFixture()
        let button = try fixture.button()
        let items = button.itemArray
        let initialFont = try #require(button.font)
        fixture.scale = 1.3
        fixture.render()
        #expect(try #require(button.font).pointSize > initialFont.pointSize)
        #expect(button.menu?.font == button.font)
        #expect(zip(button.itemArray, items).allSatisfy { $0 === $1 })
    }
}

@MainActor
private final class MenuFixture {
    var value = 1
    var writes = 0
    var active = false
    var enabled = true
    var scale: CGFloat = 1
    var title = "Choice"
    var options: [PickyNativeMenuOption<Int>] = [.init(value: 1, title: "First"), .init(value: 2, title: "Second")]
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        render()
    }

    func render() {
        host.rootView = AnyView(
            PickyNativeMenuPicker(
                title: title,
                selection: Binding(
                    get: { [weak self] in self?.value ?? 1 },
                    set: { [weak self] in self?.value = $0; self?.writes += 1 }
                ),
                options: options
            )
            .disabled(!enabled)
            .environment(\.controlActiveState, active ? .key : .inactive)
            .environment(\.pickyAppFontScale, scale)
        )
        host.layoutSubtreeIfNeeded()
    }

    func button() throws -> NSPopUpButton {
        func find(in view: NSView) -> NSPopUpButton? {
            (view as? NSPopUpButton) ?? view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return try #require(find(in: host))
    }
}

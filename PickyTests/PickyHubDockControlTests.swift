import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubDockControlTests {
    @Test func multiDisplayPickerDoesNotToggleAndCheckboxesPersistIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try makeSettings(root: root)
        let store = PickyHUDVisibilityStore(settingsStore: settings)
        let control = PickyHubDockControl(displayIDs: [101, 202], targetDisplayID: 101, visibilityStore: store)

        #expect(control.presentation.titleKey == "hub.dock.control")
        #expect(control.activate())
        #expect(store.isVisible(for: 101))
        #expect(store.isVisible(for: 202))

        let first = control.visibilityBinding(for: 101)
        let second = control.visibilityBinding(for: 202)
        second.wrappedValue = false
        #expect(first.wrappedValue)
        #expect(!second.wrappedValue)
        first.wrappedValue = false
        second.wrappedValue = true
        #expect(!first.wrappedValue)
        #expect(second.wrappedValue)
        #expect(control.presentation.titleKey == "hub.dock.control")

        await PickySettingsPersistenceCoordinator.shared(for: settings).flush()
        #expect(settings.load().hudDockVisibilityByDisplayID == ["101": false])
        let restored = PickyHUDVisibilityStore(settingsStore: settings)
        #expect(!restored.isVisible(for: 101))
        #expect(restored.isVisible(for: 202))
        // Reconnecting a screen reads its saved preference; rebuilding the picker does not reset it.
        let reconnected = PickyHubDockControl(displayIDs: [202, 101], targetDisplayID: 202, visibilityStore: restored)
        #expect(!reconnected.visibilityBinding(for: 101).wrappedValue)
    }

    @Test func singleDisplayRetainsShowHideActionAfterDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try makeSettings(root: root)
        let store = PickyHUDVisibilityStore(settingsStore: settings)
        let multiple = PickyHubDockControl(displayIDs: [101, 202], targetDisplayID: 101, visibilityStore: store)
        #expect(multiple.showsDisplayPicker)
        let single = PickyHubDockControl(displayIDs: [101], targetDisplayID: 101, visibilityStore: store)
        #expect(!single.showsDisplayPicker)
        #expect(single.presentation == .resolve(isDockVisible: true))
        #expect(!single.activate())
        #expect(!store.isVisible(for: 101))
        #expect(store.isVisible(for: 202))
        #expect(single.presentation == .resolve(isDockVisible: false))
        #expect(!single.activate())
        #expect(store.isVisible(for: 101))
        await PickySettingsPersistenceCoordinator.shared(for: settings).flush()
    }

    @Test func noTargetIsANoOp() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PickyHUDVisibilityStore(settingsStore: PickySettingsStore(appSupportRoot: root))
        let control = PickyHubDockControl(displayIDs: [], targetDisplayID: nil, visibilityStore: store)
        let before = store.snapshot
        #expect(!control.activate())
        #expect(store.snapshot == before)
    }

    @Test func pickerMinimumSizeDoesNotWrapDisplayNamesIntoATallPopover() throws {
        let content = PickyHubDockPickerView(
            displays: [.init(id: 101, name: "내장 Retina 디스플레이"), .init(id: 202, name: "DELL U2720Q")],
            hubDisplayID: 101,
            visibilityBinding: { .constant($0 == 101) }
        )
        .environment(\.locale, Locale(identifier: "ko"))
        for scale in [CGFloat(1), CGFloat(1.3)] {
            let scaled = content.environment(\.pickyAppFontScale, scale)
            let host = NSHostingController(rootView: scaled)
            for proposal in [CGSize(width: 280, height: 600), CGSize(width: CGFloat.infinity, height: CGFloat.infinity), .zero] {
                let size = host.sizeThatFits(in: proposal)
                #expect(size.height < 200, "Minimum-size probes must not wrap the rows into a tall popover: \(size)")
                #expect(size.height > 60, "The heading and both checkbox rows must remain visible")
                #expect(size.width >= 280, "The popover must retain a readable width even for the minimum-size probe")
            }
        }
    }

    @Test func rendersDockPickerInLightAndDarkAppearance() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/render-gallery/hub-dock")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let content = PickyHubDockPickerView(
                displays: [.init(id: 101, name: "내장 Retina 디스플레이"), .init(id: 202, name: "DELL U2720Q")],
                hubDisplayID: 101,
                visibilityBinding: { .constant($0 == 101) }
            )
            .environment(\.locale, Locale(identifier: "ko"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(PickyHubTheme.Colors.modal)
            let host = NSHostingController(rootView: content)
            let size = host.sizeThatFits(in: .zero)
            let bitmap = try #require(PickyRenderGalleryRasterizer.rasterize(
                content, logicalSize: size, scale: 2, appearance: dark ? .darkAqua : .aqua
            ))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(dark ? "dark.png" : "light.png"))
        }
    }

    private func makeSettings(root: URL) throws -> PickySettingsStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = PickySettingsStore(appSupportRoot: root)
        var seed = PickySettings.defaults(appSupportRoot: root)
        seed.defaultCwd = root.path
        seed.mainAgentCwd = root.path
        seed.worktreeParent = root.path
        try settings.save(seed)
        return settings
    }
}

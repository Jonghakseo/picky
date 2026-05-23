//
//  PickyAppFontScale.swift
//  Picky
//
//  Global app font scale (HUD/Conversation/Companion/Settings/Feedback/Report).
//  Mirrors `PickyAppearanceStore`: a single instance lives on the app delegate
//  and is injected as an environment object into every NSPanel hosting root so
//  the entire UI surface scales together when the user taps ⌘+ / ⌘- / ⌘0.
//
//  Range is intentionally narrow (0.9 ... 1.3, 10% steps) because Companion /
//  Settings forms have fixed-width controls that truncate outside that band.
//  The report viewer and terminal overlay keep their own wider scales —
//  this store only controls the global body text scale.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PickyAppFontScaleStore: ObservableObject {
    @Published private(set) var scale: Double

    private let settingsStore: PickySettingsStore

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        self.scale = PickyFontScales.clampedApp(settingsStore.load().fontScales.app)
        Self.staticScale = self.scale
    }

    /// CGFloat convenience for static accessors (`PickyHUDTypography`, NSFont sites).
    var cgValue: CGFloat { CGFloat(scale) }

    func increase() { setScale(scale + PickyFontScales.appStep) }
    func decrease() { setScale(scale - PickyFontScales.appStep) }
    func reset() { setScale(1.0) }

    /// Set an explicit scale. Used by settings UI sliders.
    func setScale(_ newValue: Double) {
        let clamped = PickyFontScales.clampedApp(newValue)
        guard clamped != scale else { return }
        // Update the static accessor BEFORE publishing the change so any
        // SwiftUI observer that re-evaluates its body in response to the
        // @Published mutation reads the new value out of
        // `PickyHUDTypography.Size.*` / `staticCGScale` on the same pass.
        Self.staticScale = clamped
        scale = clamped
        persist(clamped)
        NotificationCenter.default.post(name: .pickyAppFontScaleDidChange, object: nil)
    }

    private func persist(_ value: Double) {
        var current = settingsStore.load()
        current.fontScales.app = value
        do {
            try settingsStore.save(current)
        } catch {
            print("⚠️ PickyAppFontScaleStore: failed to persist app font scale: \(error.localizedDescription)")
        }
    }

    // MARK: - Static accessor

    /// Last-known scale, exposed for static contexts that can't take an
    /// `@EnvironmentObject` (NSFont attributed strings, `PickyHUDTypography.Size.*`).
    /// Updated whenever any `PickyAppFontScaleStore` instance mutates its scale.
    /// SwiftUI reactivity is still routed through `@EnvironmentObject` so this
    /// is only the *value* — views must observe a store to be re-rendered.
    ///
    /// Reads happen during SwiftUI body evaluation (main thread) and from
    /// NSFont attributed-string builds (also main thread); writes only happen
    /// from MainActor-isolated `setScale(_:)`. `nonisolated(unsafe)` keeps the
    /// accessor usable from non-isolated `PickyHUDTypography.Size.*` while
    /// preserving the existing main-thread-only access pattern.
    nonisolated(unsafe) private(set) static var staticScale: Double = 1.0

    nonisolated static var staticCGScale: CGFloat { CGFloat(staticScale) }
}

extension Notification.Name {
    /// Posted on the main actor whenever the global app font scale changes.
    /// Subscribers include NSView-based text surfaces that have to rebuild
    /// their `NSAttributedString` buffers (markdown bubbles, inline text view).
    static let pickyAppFontScaleDidChange = Notification.Name("PickyAppFontScaleDidChange")
}

// MARK: - SwiftUI environment + modifiers

private struct PickyAppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier applied to `pickyFont(...)` modifier sizes. Default 1.0 keeps
    /// previews and detached views (no environment object injected) at 100%.
    var pickyAppFontScale: CGFloat {
        get { self[PickyAppFontScaleKey.self] }
        set { self[PickyAppFontScaleKey.self] = newValue }
    }
}

/// Applies `.font(.system(size: base * scale, weight:, design:))` where `scale`
/// is read from the environment. Used by the bulk migration of inline
/// `.font(.system(size: N, ...))` call sites — see PR-1 / PR-2.
private struct PickyScaledFontModifier: ViewModifier {
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    @Environment(\.pickyAppFontScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * scale, weight: weight, design: design))
    }
}

extension View {
    /// Replacement for `.font(.system(size: N, weight: W, design: D))` that scales
    /// with the global app font scale environment value.
    func pickyFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(PickyScaledFontModifier(baseSize: size, weight: weight, design: design))
    }
}

/// Propagates the live scale from a `PickyAppFontScaleStore` down the SwiftUI
/// tree as both an `@EnvironmentObject` (for stores that want to observe it
/// directly) and as an `EnvironmentValue` (so the `.pickyFont(...)` modifier
/// and `PickyHUDTypography.Size.*` token reads pick up the right multiplier).
struct PickyAppFontScaleRoot<Content: View>: View {
    @ObservedObject var store: PickyAppFontScaleStore
    let content: () -> Content

    init(store: PickyAppFontScaleStore, @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.content = content
    }

    var body: some View {
        content()
            .environmentObject(store)
            .environment(\.pickyAppFontScale, store.cgValue)
    }
}

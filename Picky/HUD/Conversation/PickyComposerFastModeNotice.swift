import Combine
import Foundation

/// Remembers explicit cost acknowledgement across Pickles and app launches.
@MainActor
final class PickyComposerFastModeNotice: ObservableObject {
    @Published var isPresented = false

    private static let acknowledgementKey = "picky.fastMode.costAcknowledged"
    private let defaults: UserDefaults
    private var pendingSessionID: String?

    init(defaults: UserDefaults = PickyRuntimeEnvironment.userDefaults) {
        self.defaults = defaults
    }

    func requestToggle(
        control: PickyComposerFastModeControlState,
        sessionID: String,
        onToggle: () -> Void
    ) {
        guard !control.isUpdating else { return }
        if control.isEnabled || defaults.bool(forKey: Self.acknowledgementKey) {
            dismiss()
            onToggle()
        } else {
            pendingSessionID = sessionID
            isPresented = true
        }
    }

    func confirm(
        control: PickyComposerFastModeControlState?,
        sessionID: String,
        onToggle: () -> Void
    ) {
        guard isPresented, pendingSessionID == sessionID,
              let control, !control.isEnabled, !control.isUpdating else {
            dismiss()
            return
        }
        defaults.set(true, forKey: Self.acknowledgementKey)
        dismiss()
        onToggle()
    }

    func dismiss() {
        isPresented = false
        pendingSessionID = nil
    }
}

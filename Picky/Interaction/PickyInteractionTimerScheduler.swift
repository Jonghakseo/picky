//
//  PickyInteractionTimerScheduler.swift
//  Picky
//
//  MainActor timer adapter used to execute reducer scheduling effects.
//

import Foundation

@MainActor
protocol PickyInteractionTimerScheduling: AnyObject {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void)
}

@MainActor
final class PickyTaskInteractionTimerScheduler: PickyInteractionTimerScheduling {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            operation()
        }
    }
}

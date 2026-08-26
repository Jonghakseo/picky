//
//  PickyHUDDockGroupListSubscriptionOrchestrator.swift
//  Picky
//

import Combine
import CoreGraphics
import Foundation

/// Owns the live dock-list subscriptions. Using `CombineLatest` preserves the
/// values emitted by `@Published` rather than rereading backing storage during
/// its `willSet` notification.
@MainActor
final class PickyHUDDockGroupListSubscriptionOrchestrator {
    typealias Sync = (PickyHUDDockSnapshot, CGFloat) -> Void

    private var cancellables = Set<AnyCancellable>()

    init(
        snapshotPublisher: AnyPublisher<PickyHUDDockSnapshot, Never>,
        fontScalePublisher: AnyPublisher<CGFloat, Never>,
        sync: @escaping Sync
    ) {
        snapshotPublisher
            .combineLatest(fontScalePublisher)
            .sink(receiveValue: sync)
            .store(in: &cancellables)
    }
}

//
//  PickyHUDDockGroupListOverlayLifecycle.swift
//  Picky
//
//  One owner for dock-list observation and child-panel hosting. Keeping both
//  operations here prevents a future overlay edit from retaining a subscriber
//  without the corresponding production content host, or vice versa.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class PickyHUDDockGroupListOverlayLifecycle {
    typealias Sync = (PickyHUDDockSnapshot, CGFloat) -> Void

    private let subscription: PickyHUDDockGroupListSubscriptionOrchestrator
    private var hostingByDisplayID: [CGDirectDisplayID: PickyHUDDockGroupListHostingLifecycle] = [:]

    init(
        snapshotPublisher: AnyPublisher<PickyHUDDockSnapshot, Never>,
        fontScalePublisher: AnyPublisher<CGFloat, Never>,
        sync: @escaping Sync
    ) {
        subscription = PickyHUDDockGroupListSubscriptionOrchestrator(
            snapshotPublisher: snapshotPublisher,
            fontScalePublisher: fontScalePublisher,
            sync: sync
        )
    }

    @discardableResult
    func synchronize(
        displayID: CGDirectDisplayID,
        host: any PickyHUDDockGroupListContentHost,
        groupID: String,
        makeHosting: () -> NSView
    ) -> PickyHUDDockGroupListHostingLifecycle.SyncResult {
        let lifecycle: PickyHUDDockGroupListHostingLifecycle
        if let existing = hostingByDisplayID[displayID] {
            lifecycle = existing
        } else {
            lifecycle = PickyHUDDockGroupListHostingLifecycle(host: host)
            hostingByDisplayID[displayID] = lifecycle
        }
        return lifecycle.synchronize(groupID: groupID, makeHosting: makeHosting)
    }

    func tearDown(displayID: CGDirectDisplayID) {
        hostingByDisplayID.removeValue(forKey: displayID)?.tearDown()
    }

    func tearDownAll() {
        for lifecycle in hostingByDisplayID.values {
            lifecycle.tearDown()
        }
        hostingByDisplayID = [:]
    }

    var hostedDisplayCount: Int { hostingByDisplayID.count }
}

//
//  PickyHUDDockGroupListHostingLifecycle.swift
//  Picky
//

import AppKit
import Foundation

@MainActor
protocol PickyHUDDockGroupListContentHost: AnyObject {
    func setDockGroupListContentView(_ contentView: NSView?)
}

/// Keeps exactly one assigned hosting view while a child panel remains on the
/// same group. Assignment belongs here, so lifecycle tests exercise the same
/// production operation that changes `NSPanel.contentView`.
@MainActor
final class PickyHUDDockGroupListHostingLifecycle {
    enum SyncResult {
        case created(NSView)
        case retained(NSView)
    }

    private let host: any PickyHUDDockGroupListContentHost
    private(set) var groupID: String?
    private(set) var hosting: NSView?
    private(set) var creationCount = 0

    init(host: any PickyHUDDockGroupListContentHost) {
        self.host = host
    }

    func synchronize(groupID: String, makeHosting: () -> NSView) -> SyncResult {
        if self.groupID == groupID, let hosting {
            return .retained(hosting)
        }
        let hosting = makeHosting()
        self.groupID = groupID
        self.hosting = hosting
        creationCount += 1
        host.setDockGroupListContentView(hosting)
        return .created(hosting)
    }

    func tearDown() {
        groupID = nil
        hosting = nil
        host.setDockGroupListContentView(nil)
    }
}

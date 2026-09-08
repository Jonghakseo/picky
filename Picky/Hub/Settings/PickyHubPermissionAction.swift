//
//  PickyHubPermissionAction.swift
//  Picky
//
//  Keeps each Hub permission row attached to the system owner that can
//  actually satisfy it. Screen content uses the app-owned capture request;
//  macOS privacy grants still open their individual System Settings panes.
//

import Foundation

enum PickyHubPermissionTarget {
    case screenRecording
    case microphone
    case accessibility
    case browserContent
}

enum PickyHubPermissionAction: Equatable {
    case openSystemSettings(URL)
    case requestScreenContent

    static func resolve(
        target: PickyHubPermissionTarget,
        isGranted: Bool
    ) -> PickyHubPermissionAction {
        switch target {
        case .browserContent where !isGranted:
            .requestScreenContent
        case .screenRecording:
            .openSystemSettings(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        case .microphone:
            .openSystemSettings(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
        case .accessibility:
            .openSystemSettings(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        case .browserContent:
            .openSystemSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }

    func perform(
        openSystemSettings: (URL) -> Void,
        requestScreenContent: () -> Void
    ) {
        switch self {
        case .openSystemSettings(let url):
            openSystemSettings(url)
        case .requestScreenContent:
            requestScreenContent()
        }
    }
}

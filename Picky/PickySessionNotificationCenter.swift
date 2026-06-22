//
//  PickySessionNotificationCenter.swift
//  Picky
//
//  Notification delivery implementations extracted from
//  PickySessionViewModel.swift to keep that file under the size limit.
//  Behavior is unchanged; both conform to PickyNotificationDelivering
//  (declared in PickySessionViewModel.swift).
//

import Foundation
import UserNotifications

final class PickyNoopNotificationCenter: PickyNotificationDelivering {
    private(set) var delivered: [(title: String, body: String, identifier: String)] = []

    func deliver(title: String, body: String, identifier: String) {
        delivered.append((title, body, identifier))
    }
}

final class PickySystemNotificationCenter: PickyNotificationDelivering {
    func deliver(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        let request = makeRequest(title: title, body: body, identifier: identifier)
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.add(request, to: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        print("⚠️ Picky notification authorization failed: \(error.localizedDescription)")
                    }
                    guard granted else {
                        print("⚠️ Picky notification skipped: authorization denied")
                        return
                    }
                    Self.add(request, to: center)
                }
            case .denied:
                print("⚠️ Picky notification skipped: authorization denied")
            @unknown default:
                print("⚠️ Picky notification skipped: unsupported authorization status")
            }
        }
    }

    private func makeRequest(title: String, body: String, identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private static func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) {
        center.add(request) { error in
            if let error {
                print("⚠️ Picky notification delivery failed: \(error.localizedDescription)")
            }
        }
    }
}

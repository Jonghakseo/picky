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

enum PickyNotificationPresentationPolicy {
    static let foregroundOptions: UNNotificationPresentationOptions = [.banner, .sound]
}

enum PickyTransientNotificationCenter {
    static let deliveredLifetime: TimeInterval = 8

    typealias AddRequest = (
        _ request: UNNotificationRequest,
        _ completion: @escaping (Error?) -> Void
    ) -> Void
    typealias Schedule = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> Void

    static func add(
        _ request: UNNotificationRequest,
        to center: UNUserNotificationCenter = .current()
    ) {
        add(
            request,
            clearDelivered: { center.removeAllDeliveredNotifications() },
            addRequest: { request, completion in
                center.add(request, withCompletionHandler: completion)
            },
            removeDelivered: { identifiers in
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            },
            schedule: scheduleAfterDelay,
            onFailure: { error in
                print("⚠️ Picky notification delivery failed: \(error.localizedDescription)")
            }
        )
    }

    static func add(
        _ request: UNNotificationRequest,
        clearDelivered: () -> Void,
        addRequest: @escaping AddRequest,
        removeDelivered: @escaping ([String]) -> Void,
        schedule: @escaping Schedule,
        onFailure: @escaping (Error) -> Void = { _ in }
    ) {
        clearDelivered()
        addRequest(request) { error in
            if let error {
                onFailure(error)
                return
            }
            schedule(deliveredLifetime) {
                removeDelivered([request.identifier])
            }
        }
    }

    private static func scheduleAfterDelay(
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
}

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
        PickyTransientNotificationCenter.add(request, to: center)
    }
}

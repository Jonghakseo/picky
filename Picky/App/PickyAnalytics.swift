//
//  PickyAnalytics.swift
//  Picky
//
//  Local no-op instrumentation surface. Picky v1 is local-first and performs
//  no network upload, contact collection, purchase flow, or gated feature calls.
//

import Foundation

enum PickyAnalytics {
    static func configure() {}
    static func trackAppOpened() { log("app_opened") }
    static func trackAllPermissionsGranted() { log("all_permissions_granted") }
    static func trackPermissionGranted(permission: String) { log("permission_granted: \(permission)") }
    static func trackPushToTalkStarted() { log("push_to_talk_started") }
    static func trackPushToTalkReleased() { log("push_to_talk_released") }
    static func trackUserMessageSent(transcript: String) { log("user_message_sent: \(transcript.count) chars") }
    static func trackAgentSubmissionAccepted(sessionID: String) { log("agent_submission_accepted: \(sessionID)") }
    static func trackResponseError(error: String) { log("response_error: \(error)") }

    private static func log(_ message: String) {
        #if DEBUG
        print("📍 Picky local event — \(message)")
        #endif
    }
}

//
//  PickyOnboardingOverrides.swift
//  Picky
//

import Foundation

/// Demo-time overrides the onboarding flow installs on `CompanionManager`.
/// Presence alone suppresses real shortcut handling and keeps the cursor
/// overlay visible; the fields carry the per-beat guide text and the
/// interceptor that swallows submissions before they reach the daemon.
struct PickyOnboardingOverrides {
    /// Rendered by `BlueCursorView` as a guide bubble pinned to the cursor.
    var bubbleText: String?
    /// Returning a non-nil receipt fakes a successful submit without any Pi call.
    var submissionInterceptor: (@MainActor (PickyAgentSubmission) async -> PickyAgentSubmissionReceipt?)?
}

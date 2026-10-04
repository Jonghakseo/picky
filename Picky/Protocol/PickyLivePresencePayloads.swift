import Foundation

// Payloads of live-only presence events (`PickyEvent.sessionReplyWritingUpdated`,
// `.sessionToolCallPreparingUpdated`, `.sessionAutoRetryUpdated`). They are never persisted.

struct PickySessionReplyWritingUpdatedPayload: Decodable, Equatable {
    let sessionId: String
    let writing: Bool
}

struct PickySessionToolCallPreparingUpdatedPayload: Decodable, Equatable {
    let sessionId: String
    let preparing: Bool
}

/// Why a Pickle's model request is being retried: the attempt and the
/// provider's status code and message for the failed attempt.
struct PickyAutoRetryStatus: Decodable, Equatable, Hashable {
    let attempt: Int
    let maxAttempts: Int
    let errorCode: String?
    let errorMessage: String
}

struct PickySessionAutoRetryUpdatedPayload: Decodable, Equatable {
    let sessionId: String
    let retry: PickyAutoRetryStatus?
}

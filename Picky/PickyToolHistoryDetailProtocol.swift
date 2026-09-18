import Foundation

enum PickyToolHistoryDetailPart: String, Codable, Equatable, Sendable {
    case arguments, result
}

enum PickyToolHistoryDetailStatus: String, Codable, Equatable, Sendable {
    case ready, pending, unavailable, sourceChanged, unsupported
}

struct PickyToolHistoryDetailResult: Decodable, Equatable, Sendable {
    let sessionId: String
    let requestId: String
    let toolCallId: String
    let expectedSessionFile: String
    let part: PickyToolHistoryDetailPart
    let status: PickyToolHistoryDetailStatus
    var text: String? = nil
    var nextCursor: String? = nil
    var reason: String? = nil
    var attachmentsOmitted: Bool? = nil
}

extension PickyCommandEnvelope {
    init(toolHistorySessionID: String, toolCallId: String, expectedSessionFile: String,
         part: PickyToolHistoryDetailPart, cursor: String? = nil) {
        self.init(type: .getToolHistoryDetail, sessionId: toolHistorySessionID)
        self.toolCallId = toolCallId
        self.expectedSessionFile = expectedSessionFile
        self.part = part
        self.cursor = cursor
    }
}

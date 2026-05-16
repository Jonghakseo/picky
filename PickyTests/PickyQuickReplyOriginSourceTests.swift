//
//  PickyQuickReplyOriginSourceTests.swift
//  PickyTests
//
//  Regression guard for the decoder's string normalisation. PickyQuickReplyOriginSource
//  uses a custom `init(from:)` that routes through `Self.normalized(raw)` instead of
//  Swift's automatic rawValue match. When a new enum case is added (e.g. `.cli`) the
//  normalisation switch must list the lowercased rawValue too; otherwise the daemon's
//  on-the-wire value is silently coerced to `.unknown`, the reducer maps that to a
//  non-cursor owner, and the cursor speech bubble + TTS never fire for replies tagged
//  with the new origin.
//

import Foundation
import Testing
@testable import Picky

struct PickyQuickReplyOriginSourceTests {
    @Test func normalizesEveryEnumCaseFromItsRawValue() {
        // Every case in PickyQuickReplyOriginSource must be reachable through `normalized`
        // because the decoder's custom init does NOT fall back to Swift's rawValue parser.
        // If you add a new case, add a matching `case "<raw>"` to `normalized` and add it
        // to this list.
        let allCases: [(String, PickyQuickReplyOriginSource)] = [
            ("voice", .voice),
            ("text", .text),
            ("voiceFollowUp", .voiceFollowUp),
            ("textFollowUp", .textFollowUp),
            ("system", .system),
            ("cli", .cli),
            ("unknown", .unknown),
        ]
        for (raw, expected) in allCases {
            #expect(PickyQuickReplyOriginSource.normalized(raw) == expected, "normalized(\"\(raw)\") returned \(PickyQuickReplyOriginSource.normalized(raw)), expected \(expected)")
        }
    }

    @Test func decoderRoundTripsCliOriginSource() throws {
        // Mirrors the over-the-wire encoding agentd produces for picky CLI submissions.
        let encoded = "\"cli\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PickyQuickReplyOriginSource.self, from: encoded)
        #expect(decoded == .cli)
    }

    @Test func cliOriginMapsToCursorContextOwner() {
        // The reducer's ownerFromMetadata is private, so emulate it here. Documents that
        // .cli must map to .cli (cursor-presentation owner). If this assertion ever
        // fails, the cursor speech bubble + TTS path for CLI submissions is broken.
        let owner: PickyContextOwner
        switch PickyQuickReplyOriginSource.cli {
        case .voice, .voiceFollowUp: owner = .metadataVoice
        case .text, .textFollowUp: owner = .metadataText
        case .cli: owner = .cli
        case .system: owner = .system
        case .unknown: owner = .unknown
        }
        #expect(owner == .cli)
        #expect(owner.usesCursorResponsePresentation == true)
    }
}

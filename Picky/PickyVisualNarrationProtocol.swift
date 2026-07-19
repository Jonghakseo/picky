//
//  PickyVisualNarrationProtocol.swift
//  Picky
//
//  Annotation overlay and progressive visual narration wire models.
//

import Foundation

enum PickyAnnotationOverlayMode: String, Codable, Equatable {
    case replace, append, clear
}

enum PickyAnnotationOverlayShape: String, Codable, Equatable {
    case rect, line, path
}

enum PickyAnnotationPathCommandType: String, Codable, Equatable {
    case move, line, cubic
}

struct PickyAnnotationPathCommand: Codable, Equatable {
    let type: PickyAnnotationPathCommandType
    let x: Double
    let y: Double
    let c1x: Double?
    let c1y: Double?
    let c2x: Double?
    let c2y: Double?

    init(
        type: PickyAnnotationPathCommandType,
        x: Double,
        y: Double,
        c1x: Double? = nil,
        c1y: Double? = nil,
        c2x: Double? = nil,
        c2y: Double? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }
}

struct PickyAnnotationOverlayAnnotation: Codable, Equatable, Identifiable {
    let id: String
    let shape: PickyAnnotationOverlayShape
    let x: Double?
    let y: Double?
    let w: Double?
    let h: Double?
    let x1: Double?
    let y1: Double?
    let x2: Double?
    let y2: Double?
    let commands: [PickyAnnotationPathCommand]?
    let spotlight: Bool?
    let label: String?
    let clamped: Bool?

    init(
        id: String,
        shape: PickyAnnotationOverlayShape,
        x: Double? = nil,
        y: Double? = nil,
        w: Double? = nil,
        h: Double? = nil,
        x1: Double? = nil,
        y1: Double? = nil,
        x2: Double? = nil,
        y2: Double? = nil,
        commands: [PickyAnnotationPathCommand]? = nil,
        spotlight: Bool? = nil,
        label: String? = nil,
        clamped: Bool? = nil
    ) {
        self.id = id
        self.shape = shape
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.commands = commands
        self.spotlight = spotlight
        self.label = label
        self.clamped = clamped
    }
}

struct PickyAnnotationOverlayRequest: Codable, Equatable, Identifiable {
    let id: String
    let mode: PickyAnnotationOverlayMode
    let annotations: [PickyAnnotationOverlayAnnotation]
    let contextId: String?
    let contextGeneration: Int?
    let screenId: String?
    let screenBounds: PickyCGRect?
    let screenshotSize: PickyPointerScreenshotSize?

    init(
        id: String,
        mode: PickyAnnotationOverlayMode,
        annotations: [PickyAnnotationOverlayAnnotation],
        contextId: String? = nil,
        contextGeneration: Int? = nil,
        screenId: String? = nil,
        screenBounds: PickyCGRect? = nil,
        screenshotSize: PickyPointerScreenshotSize? = nil
    ) {
        self.id = id
        self.mode = mode
        self.annotations = annotations
        self.contextId = contextId
        self.contextGeneration = contextGeneration
        self.screenId = screenId
        self.screenBounds = screenBounds
        self.screenshotSize = screenshotSize
    }
}

struct PickyVisualNarrationSegmentIdentity: Codable, Equatable, Hashable {
    let contextId: String
    let contextGeneration: Int
    let turnToken: String
    let segmentId: String
    let ordinal: Int
}

enum PickyPreparedVisualNarrationVisual: Codable, Equatable {
    case point(PickyPointerOverlayRequest)
    case annotations(PickyAnnotationOverlayRequest)

    private enum CodingKeys: String, CodingKey { case kind, request }
    private enum Kind: String, Codable { case point, annotations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .point:
            self = .point(try container.decode(PickyPointerOverlayRequest.self, forKey: .request))
        case .annotations:
            self = .annotations(try container.decode(PickyAnnotationOverlayRequest.self, forKey: .request))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point(let request):
            try container.encode(Kind.point, forKey: .kind)
            try container.encode(request, forKey: .request)
        case .annotations(let request):
            try container.encode(Kind.annotations, forKey: .kind)
            try container.encode(request, forKey: .request)
        }
    }
}

struct PickyVisualNarrationSegmentPreparedEvent: Decodable, Equatable {
    let identity: PickyVisualNarrationSegmentIdentity
    let visual: PickyPreparedVisualNarrationVisual
}

struct PickyVisualNarrationSegmentSentenceEvent: Decodable, Equatable {
    let identity: PickyVisualNarrationSegmentIdentity
    let index: Int
    let text: String
    let originSource: PickyQuickReplyOriginSource?
    let replyKind: PickyQuickReplyKind?
    let sessionId: String?
}

struct PickyVisualNarrationSegmentCommittedEvent: Decodable, Equatable {
    let identity: PickyVisualNarrationSegmentIdentity
    let text: String?
    let sentenceCount: Int
    let originSource: PickyQuickReplyOriginSource?
    let replyKind: PickyQuickReplyKind?
    let sessionId: String?
}

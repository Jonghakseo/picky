//
//  PickyAnnotationPathGeometry.swift
//  Picky
//
//  Shared resolved geometry for agent-authored SVG-subset annotation paths.
//

import CoreGraphics
import Foundation

enum PickyAgentAnnotationPathCommand: Equatable, Codable {
    case move(CGPoint)
    case line(CGPoint)
    case cubic(to: CGPoint, control1: CGPoint, control2: CGPoint)

    var destination: CGPoint {
        switch self {
        case .move(let point), .line(let point), .cubic(to: let point, control1: _, control2: _):
            point
        }
    }
}

enum PickyAnnotationPathGeometry {
    static let samplesPerCubic = 16

    /// Includes control points, so the returned rectangle conservatively contains
    /// every cubic Bézier segment because each segment lies in its control hull.
    static func bounds(for commands: [PickyAgentAnnotationPathCommand]) -> CGRect? {
        let points = commands.flatMap { command -> [CGPoint] in
            switch command {
            case .move(let point), .line(let point):
                [point]
            case .cubic(to: let destination, control1: let control1, control2: let control2):
                [control1, control2, destination]
            }
        }
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { bounds, point in
            bounds.union(CGRect(origin: point, size: .zero))
        }
    }

    static func sampledPoints(
        for commands: [PickyAgentAnnotationPathCommand],
        cubicSteps: Int = samplesPerCubic
    ) -> [CGPoint] {
        guard cubicSteps > 0 else { return [] }
        var result: [CGPoint] = []
        var current: CGPoint?
        for command in commands {
            switch command {
            case .move(let point):
                current = point
                result.append(point)
            case .line(let point):
                guard current != nil else { continue }
                result.append(point)
                current = point
            case .cubic(to: let destination, control1: let control1, control2: let control2):
                guard let start = current else { continue }
                for step in 1...cubicSteps {
                    result.append(cubicPoint(
                        start: start,
                        control1: control1,
                        control2: control2,
                        end: destination,
                        progress: CGFloat(step) / CGFloat(cubicSteps)
                    ))
                }
                current = destination
            }
        }
        return result
    }

    static func arcLengthMidpoint(for commands: [PickyAgentAnnotationPathCommand]) -> CGPoint? {
        let points = sampledPoints(for: commands)
        guard let first = points.first else { return nil }
        let lengths = zip(points, points.dropFirst()).map { distance(from: $0.0, to: $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return first }
        let target = total / 2
        var traversed: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            if traversed + length >= target, length > 0 {
                let progress = (target - traversed) / length
                return interpolate(points[index], points[index + 1], progress: progress)
            }
            traversed += length
        }
        return points.last
    }

    private static func cubicPoint(
        start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        end: CGPoint,
        progress: CGFloat
    ) -> CGPoint {
        let inverse = 1 - progress
        let startWeight = inverse * inverse * inverse
        let control1Weight = 3 * inverse * inverse * progress
        let control2Weight = 3 * inverse * progress * progress
        let endWeight = progress * progress * progress
        return CGPoint(
            x: start.x * startWeight + control1.x * control1Weight + control2.x * control2Weight + end.x * endWeight,
            y: start.y * startWeight + control1.y * control1Weight + control2.y * control2Weight + end.y * endWeight
        )
    }

    private static func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}

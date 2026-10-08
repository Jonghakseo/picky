//
//  PickyFeedbackStageLog.swift
//  Picky
//
//  Timing breadcrumbs for one feedback submission. The previous "stuck on
//  sending" report could not be attributed to a step because nothing recorded
//  how long diagnostics collection, zipping, or each Slack request took. These
//  lines land in the unified log, so the *next* report carries the evidence.
//
//  Only scalars are emitted: job id, stage name, duration, byte count, and a
//  short outcome code. Message bodies, tokens, filenames, and paths never are.
//

import Foundation

enum PickyFeedbackStageLog {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(String)
        case skipped(String)

        var code: String {
            switch self {
            case .succeeded: return "ok"
            case .failed(let reason): return "fail:\(Self.sanitized(reason))"
            case .skipped(let reason): return "skip:\(Self.sanitized(reason))"
            }
        }

        /// Call sites pass short literals such as `transport` or `http-503`.
        /// Anything else is cut at the first character that does not belong in
        /// an identifier, so a stray error string cannot leak a path, filename,
        /// or token into the log.
        private static func sanitized(_ reason: String) -> String {
            let code = reason
                .lowercased()
                .prefix { $0.isLetter || $0.isNumber || $0 == "-" }
                .prefix(32)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return code.isEmpty ? "unknown" : code
        }
    }

    static func record(
        correlationID: String?,
        stage: String,
        startedAt: Date,
        byteCount: Int? = nil,
        outcome: Outcome,
        now: Date = Date()
    ) {
        let line = renderLine(
            correlationID: correlationID,
            stage: stage,
            elapsedMs: Int(max(0, now.timeIntervalSince(startedAt)) * 1_000),
            byteCount: byteCount,
            outcome: outcome
        )
        PickyLog.notice(.feedback, prefix: "📮 Picky feedback", message: line)
    }

    /// Pure renderer so the emitted contract can be asserted without reading
    /// back the unified log.
    static func renderLine(
        correlationID: String?,
        stage: String,
        elapsedMs: Int,
        byteCount: Int?,
        outcome: Outcome
    ) -> String {
        var fields = [
            "stage=\(stage)",
            "job=\(correlationID ?? "none")",
            "elapsedMs=\(elapsedMs)"
        ]
        if let byteCount {
            fields.append("bytes=\(byteCount)")
        }
        fields.append("result=\(outcome.code)")
        return fields.joined(separator: " ")
    }
}

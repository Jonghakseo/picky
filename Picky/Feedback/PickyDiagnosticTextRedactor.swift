//
//  PickyDiagnosticTextRedactor.swift
//  Picky
//
//  Best-effort redaction for diagnostic text files. This is applied to stderr
//  tails and OSLog text before they are zipped. It is intentionally broad: if a
//  key name looks token/secret-shaped, or a known token format appears, we mask
//  the value. User chat/tool stdout is never attached separately.
//

import Foundation

enum PickyDiagnosticTextRedactor {
    private static let sensitiveAssignmentPatterns: [NSRegularExpression] = [
        // JSON/IPS values with quoted keys, including a JSON string embedded in
        // another log message (\"apiKey\":\"…\"). Redacting the complete pair
        // avoids depending on the crash report's JSON escaping details.
        try! NSRegularExpression(pattern: #"(?i)(?:\\?")(api[_-]?key|apikey|token|target_token|notifytoken|secret|password|authorization)(?:\\?")\s*:\s*(?:\\?")(?:\\.|[^"\\])*(?:\\?")"#),
        // key=value or key: value, including OSLog system fields like target_token / NotifyToken.
        try! NSRegularExpression(pattern: #"(?i)\b(api[_-]?key|apikey|token|target_token|notifytoken|secret|password|authorization)\s*[:=]\s*"?[^\s,"'}]+"?"#),
        // Authorization: Bearer ...
        try! NSRegularExpression(pattern: #"(?i)Authorization:\s*Bearer\s+[^\s,"'}]+"#),
        // Slack bot tokens and webhooks.
        try! NSRegularExpression(pattern: #"xoxb-[A-Za-z0-9-]+"#),
        try! NSRegularExpression(pattern: #"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+"#),
        // Common OpenAI-style API keys.
        try! NSRegularExpression(pattern: #"sk-[A-Za-z0-9_-]{20,}"#),
        // JWT-like values.
        try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        // macOS user home paths. Once the daemon launcher and session UI log
        // sites started flowing through `os.Logger`, error messages and
        // `logDir=` / `cwd=` style fields began carrying `/Users/<name>/...`
        // into the diagnostics bundle. The username is mildly identifying on
        // its own and almost never useful to a triager, so mask it while
        // keeping the rest of the path intact for context.
        try! NSRegularExpression(pattern: #"/Users/[^/\s"',}]+"#),
        // Same idea for legacy single-user macOS paths.
        try! NSRegularExpression(pattern: #"/private/var/folders/[^/\s"',}]+/[^/\s"',}]+/[^/\s"',}]+"#)
    ]
    private static let userHomePathReplacement = "/Users/<redacted-user>"
    private static let tempPathReplacement = "/private/var/folders/<redacted>/<redacted>/<redacted>"

    static func redact(_ text: String) -> String {
        var output = text
        // Token / secret patterns first — they are the highest-stakes leak
        // and the templates do not depend on which match preceded them.
        for (index, regex) in sensitiveAssignmentPatterns.enumerated() {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let template: String
            switch index {
            case sensitiveAssignmentPatterns.count - 2: template = userHomePathReplacement
            case sensitiveAssignmentPatterns.count - 1: template = tempPathReplacement
            default: template = "<redacted>"
            }
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return output
    }

    static func redact(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(redact(text).utf8)
    }

    /// Bounds valid UTF-8 without splitting a Unicode scalar. Keeping the
    /// newest content is used for logs, while crash reports retain their
    /// leading exception/header context.
    static func truncateUTF8(_ text: String, maxBytes: Int, keepingNewest: Bool) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.lengthOfBytes(using: .utf8) > maxBytes else { return text }
        let scalars = Array(text.unicodeScalars)
        if keepingNewest {
            var selected: [Unicode.Scalar] = []
            var usedBytes = 0
            for scalar in scalars.reversed() {
                let scalarBytes = String(scalar).lengthOfBytes(using: .utf8)
                guard usedBytes + scalarBytes <= maxBytes else { break }
                selected.append(scalar)
                usedBytes += scalarBytes
            }
            return String(String.UnicodeScalarView(selected.reversed()))
        }

        var selected: [Unicode.Scalar] = []
        var usedBytes = 0
        for scalar in scalars {
            let scalarBytes = String(scalar).lengthOfBytes(using: .utf8)
            guard usedBytes + scalarBytes <= maxBytes else { break }
            selected.append(scalar)
            usedBytes += scalarBytes
        }
        return String(String.UnicodeScalarView(selected))
    }
}

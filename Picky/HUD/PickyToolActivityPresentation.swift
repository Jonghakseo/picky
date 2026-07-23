//
//  PickyToolActivityPresentation.swift
//  Picky
//
//  Shared semantic display rules for tool activity in the cursor overlay and
//  conversation card.
//

import Foundation

enum PickyToolActivityPresentation {
    /// Returns the invoked skill name when a `read` call loads a registered
    /// skill manifest. A generic `SKILL.md` read outside a `skills/<name>`
    /// directory remains an ordinary read operation.
    static func skillName(forToolNamed toolName: String, argsPreview: String?) -> String? {
        guard toolName.caseInsensitiveCompare("read") == .orderedSame,
              let path = PickyToolHistoryRenderer.recoverStringValue(from: argsPreview, key: "path")
        else { return nil }

        let components = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 3,
              components[components.count - 1].caseInsensitiveCompare("SKILL.md") == .orderedSame,
              components[components.count - 3].caseInsensitiveCompare("skills") == .orderedSame
        else { return nil }

        let skillName = components[components.count - 2]
        guard skillName.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return skillName
    }
}

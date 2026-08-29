import Foundation

enum PickyShortcutRole: CaseIterable, Hashable {
    case pushToTalk
    case quickInput
    case focusPickle
}

enum PickyShortcutConflictPolicy {
    static func conflictingRole(
        for proposed: PickyShortcutSpec,
        role: PickyShortcutRole,
        shortcuts: [PickyShortcutRole: PickyShortcutSpec]
    ) -> PickyShortcutRole? {
        PickyShortcutRole.allCases.first { otherRole in
            guard otherRole != role, let other = shortcuts[otherRole] else { return false }
            return proposed.conflicts(with: other) || other.conflicts(with: proposed)
        }
    }
}

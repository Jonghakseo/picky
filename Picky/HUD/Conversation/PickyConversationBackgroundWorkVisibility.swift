import Foundation

/// The task footer owns background execution UI. Keep the underlying journal intact
/// for Pi, reconnect, and reports; suppress only the duplicate conversation surfaces.
enum PickyConversationBackgroundWorkVisibility {
    static func isVisible(_ message: PickySessionMessage) -> Bool {
        if message.kind == .subagentInvocation { return false }
        guard message.kind == .system else { return true }
        if let type = message.customType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
            return type != "bash-async-completion" && type != "subagent-tool"
        }
        guard message.notifyType != nil, let text = message.text else { return true }
        // ctx.ui.notify has no extension identity. Match only the bundled subagent
        // tool's lifecycle grammar, never a generic mention of a tool/extension.
        let notification = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !subagentLifecycleNotifications.contains {
            $0.firstMatch(in: notification, range: NSRange(notification.startIndex..., in: notification)) != nil
        }
    }

    private static let subagentLifecycleNotifications: [NSRegularExpression] = [
        #"\A(?:Started|Resumed) subagent #[0-9]+: [^\r\n]+\z"#,
        #"\Asubagent tool run #[0-9]+(?: \([^\r\n]+\))? (?:completed|failed|aborted)(?:: [\s\S]*)?\z"#,
        #"\Asubagent batch [^\s]+ (?:completed|aborted|finished with errors)\z"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}

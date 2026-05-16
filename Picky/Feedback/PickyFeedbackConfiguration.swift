//
//  PickyFeedbackConfiguration.swift
//  Picky
//
//  Build-time configuration for the in-app feedback channel. Picky posts
//  feedback directly to Slack using a Bot User OAuth token (xoxb) so it can
//  attach a diagnostics zip alongside the message via Slack's Web API
//  (Incoming Webhooks cannot attach files).
//
//  Required Bot Token Scopes: chat:write, files:write.
//  The bot must be invited to the destination channel for file uploads.
//
//  The bot token and destination channel ID are injected at package time from
//  `PICKY_SLACK_BOT_TOKEN` and `PICKY_SLACK_CHANNEL_ID` by
//  `scripts/package-signed-app.sh`, which writes `PickyFeedbackSecrets.json`
//  into the app bundle. Local Xcode IDE builds without that resource simply
//  leave feedback disabled. Rotate the token via Slack's OAuth & Permissions
//  page and update the GitHub secret.
//

import Foundation

enum PickyFeedbackConfiguration {
    /// Destination channel ID. Loaded from `PickyFeedbackSecrets.json` inside
    /// the app bundle, populated at package time from the
    /// `PICKY_SLACK_CHANNEL_ID` environment variable.
    static var channelID: String {
        Self.loadedSecrets.slackChannelID
    }

    /// Bot User OAuth Token (xoxb-…). Loaded from `PickyFeedbackSecrets.json`
    /// inside the app bundle, populated at package time from the
    /// `PICKY_SLACK_BOT_TOKEN` environment variable.
    static var botToken: String {
        Self.loadedSecrets.slackBotToken
    }

    static var isConfigured: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let loadedSecrets: (slackBotToken: String, slackChannelID: String) = {
        guard let path = Bundle.main.path(forResource: "PickyFeedbackSecrets", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ("", "")
        }
        let token = (json["slackBotToken"] as? String) ?? ""
        let channelID = (json["slackChannelID"] as? String) ?? ""
        return (
            token.trimmingCharacters(in: .whitespacesAndNewlines),
            channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }()
}

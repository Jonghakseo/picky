//
//  PickyFastModeTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyFastModeTests {
    /// The app must send exactly the command shape agentd's schema accepts
    /// (`protocol.test.ts` checks the same fixtures against the zod schema).
    @Test(arguments: [
        ("set-session-fast-mode.request.json", PickyCommandEnvelope(id: "cmd-session-fast-001", type: .setSessionFastMode, sessionId: "session-001", enabled: true)),
        ("set-main-agent-fast-mode.request.json", PickyCommandEnvelope(id: "cmd-main-fast-001", type: .setMainAgentFastMode, enabled: false)),
    ])
    func encodesFastModeCommandsAsTheDaemonExpects(fixture: String, command: PickyCommandEnvelope) throws {
        let url = try #require(try fixtureURLs(in: "contracts/protocol").first { $0.lastPathComponent == fixture })
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? NSDictionary)
        #expect(encoded == expected)
    }

    @Test func offersTheComposerToggleOnlyWhereTheModelSupportsFastMode() {
        #expect(PickyComposerFastModeControlState(enabled: true, supported: false, isUpdating: false) == nil)
        #expect(PickyComposerFastModeControlState(enabled: false, supported: true, isUpdating: false)?.isEnabled == false)
        #expect(PickyComposerFastModeControlState(enabled: true, supported: true, isUpdating: true)?.isUpdating == true)
    }

    @Test func disablesTheMainAgentSettingOnlyForAModelKnownToLackFastMode() throws {
        let options = try JSONDecoder().decode([PickyMainAgentModelOption].self, from: Data("""
        [
          {"provider": "openai-codex", "modelId": "gpt-5.5", "displayName": "openai-codex/gpt-5.5", "pattern": "openai-codex/gpt-5.5", "fastModeSupported": true},
          {"provider": "azure-openai-responses", "modelId": "gpt-6-sol", "displayName": "azure-openai-responses/gpt-6-sol", "pattern": "azure-openai-responses/gpt-6-sol", "fastModeSupported": false},
          {"provider": "anthropic", "modelId": "claude-opus-5", "displayName": "anthropic/claude-opus-5", "pattern": "anthropic/claude-opus-5"}
        ]
        """.utf8))
        #expect(PickyMainAgentFastModeAvailability.isKnownUnsupported(modelPattern: "azure-openai-responses/gpt-6-sol", options: options))
        #expect(!PickyMainAgentFastModeAvailability.isKnownUnsupported(modelPattern: "openai-codex/gpt-5.5", options: options))
        // Automatic selection, an unlisted pattern, and an older daemon without the flag stay enabled.
        #expect(!PickyMainAgentFastModeAvailability.isKnownUnsupported(modelPattern: "", options: options))
        #expect(!PickyMainAgentFastModeAvailability.isKnownUnsupported(modelPattern: "custom/model", options: options))
        #expect(!PickyMainAgentFastModeAvailability.isKnownUnsupported(modelPattern: "anthropic/claude-opus-5", options: options))
    }

    @MainActor
    @Test func requiresExplicitCostAcknowledgementBeforeFirstActivationAndRemembersIt() throws {
        let suite = "PickyFastModeNoticeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let off = try #require(PickyComposerFastModeControlState(enabled: false, supported: true, isUpdating: false))
        let notice = PickyComposerFastModeNotice(defaults: defaults)
        var toggles = 0

        notice.requestToggle(control: off, sessionID: "a") { toggles += 1 }
        #expect(notice.isPresented)
        #expect(toggles == 0)
        notice.dismiss()
        notice.confirm(control: off, sessionID: "a") { toggles += 1 }
        #expect(toggles == 0)

        // Cancellation must not suppress the next notice, even after reopening the card.
        let reopened = PickyComposerFastModeNotice(defaults: defaults)
        reopened.requestToggle(control: off, sessionID: "a") { toggles += 1 }
        #expect(reopened.isPresented)
        reopened.confirm(control: off, sessionID: "a") { toggles += 1 }
        #expect(!reopened.isPresented)
        #expect(toggles == 1)
        reopened.confirm(control: off, sessionID: "a") { toggles += 1 }
        #expect(toggles == 1)

        // A different Pickle and a fresh controller reuse the persisted acknowledgement.
        let relaunched = PickyComposerFastModeNotice(defaults: defaults)
        relaunched.requestToggle(control: off, sessionID: "b") { toggles += 1 }
        #expect(!relaunched.isPresented)
        #expect(toggles == 2)
    }

    @MainActor
    @Test func turningFastModeOffDoesNotRequireCostAcknowledgement() throws {
        let suite = "PickyFastModeNoticeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let on = try #require(PickyComposerFastModeControlState(enabled: true, supported: true, isUpdating: false))
        let off = try #require(PickyComposerFastModeControlState(enabled: false, supported: true, isUpdating: false))
        let notice = PickyComposerFastModeNotice(defaults: defaults)
        var toggles = 0
        notice.requestToggle(control: on, sessionID: "a") { toggles += 1 }
        #expect(!notice.isPresented)
        #expect(toggles == 1)
        notice.requestToggle(control: off, sessionID: "a") { toggles += 1 }
        #expect(notice.isPresented)
        #expect(toggles == 1)
    }

    @MainActor
    @Test func staleOrUnavailableConfirmationCannotToggleOrRememberAcknowledgement() throws {
        let suite = "PickyFastModeNoticeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let off = try #require(PickyComposerFastModeControlState(enabled: false, supported: true, isUpdating: false))
        let updating = try #require(PickyComposerFastModeControlState(enabled: false, supported: true, isUpdating: true))
        let on = try #require(PickyComposerFastModeControlState(enabled: true, supported: true, isUpdating: false))
        let notice = PickyComposerFastModeNotice(defaults: defaults)
        var toggles = 0
        notice.requestToggle(control: updating, sessionID: "a") { toggles += 1 }
        #expect(!notice.isPresented)
        for (control, sessionID) in [(Optional(off), "b"), (nil, "a"), (Optional(updating), "a"), (Optional(on), "a")] {
            notice.requestToggle(control: off, sessionID: "a") { toggles += 1 }
            #expect(notice.isPresented)
            notice.confirm(control: control, sessionID: sessionID) { toggles += 1 }
            #expect(!notice.isPresented)
            #expect(toggles == 0)
        }
        notice.requestToggle(control: off, sessionID: "a") { toggles += 1 }
        #expect(notice.isPresented)
        #expect(toggles == 0)
    }

    @Test func readsPersistedFastModeAndDefaultsOlderSettingsToOff() throws {
        let session = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyAgentSession.self, from: Data("""
        {"id": "s", "title": "t", "status": "running", "createdAt": "2026-08-24T00:00:00.000Z", "updatedAt": "2026-08-24T00:00:00.000Z",
         "logs": [], "tools": [], "artifacts": [], "changedFiles": [], "messages": [], "fastMode": true, "fastModeSupported": false}
        """.utf8))
        #expect(session.fastMode == true)
        #expect(session.fastModeSupported == false)
        #expect(try JSONDecoder().decode(PickySettings.self, from: Data("{}".utf8)).mainAgentFastMode == false)
    }
}

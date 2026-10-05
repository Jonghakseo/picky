import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyUsageLimitsStoreTests {
    @Test func pollingChecksImmediatelyThenWaitsFiveMinutesOrRetriesSoonerAfterAFailure() async throws {
        for (ok, expectedDelay) in [(true, PickyUsageLimitsStore.pollInterval), (false, PickyUsageLimitsStore.retryInterval)] {
            let client = FakePickyAgentClient()
            client.beforeSend = { command in
                await MainActor.run { client.emit(Self.reply(commandID: command.id, ok: ok)) }
            }
            let delays = DelayRecorder()
            let store = PickyUsageLimitsStore(client: client, defaults: Self.defaults(), sleep: { delay in
                await delays.record(delay)
                throw CancellationError()
            })
            store.start()
            try await waitUntil(timeoutMs: 2_000) { await delays.values.count == 1 }

            #expect(await delays.values == [expectedDelay])
            #expect(client.sentCommands.map(\.type) == [.getUsageLimits])
            #expect(client.sentCommands.first?.force == false)
            #expect((store.snapshot != nil) == ok)
            store.stop()
        }
    }

    @Test func manualRefreshForcesACheckAndKeepsTheLastSnapshotWhenItFails() async throws {
        let client = FakePickyAgentClient()
        let replyOK = Flag(true)
        client.beforeSend = { command in
            await MainActor.run { client.emit(Self.reply(commandID: command.id, ok: replyOK.value)) }
        }
        let store = PickyUsageLimitsStore(client: client, defaults: Self.defaults())
        store.refresh()
        try await waitUntil(timeoutMs: 2_000) { store.snapshot != nil }
        #expect(client.sentCommands.last?.force == true)
        #expect(store.provider(.anthropic)?.session?.remainingPercent == 93)

        replyOK.value = false
        #expect(await store.load(force: true) == false)
        #expect(store.provider(.anthropic)?.plan == "Max 20x")
        #expect(store.lastErrorMessage == "Usage limits unavailable")
        #expect(!store.isRefreshing)
    }

    @Test func menuBarPinsPersistAndOnlyShowSubscribedProvidersInDisplayOrder() async throws {
        let defaults = Self.defaults()
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            await MainActor.run { client.emit(Self.reply(commandID: command.id, providers: ["openai-codex", "anthropic"])) }
        }
        let store = PickyUsageLimitsStore(client: client, defaults: defaults)
        store.setPinned(true, for: .openaiCodex)
        store.setPinned(true, for: .anthropic)
        #expect(await store.load(force: false))
        #expect(store.menuBarProviders.map(\.provider) == [.anthropic, .openaiCodex])

        store.setPinned(false, for: .anthropic)
        let reopened = PickyUsageLimitsStore(client: client, defaults: defaults)
        #expect(reopened.pinnedProviders == [.openaiCodex])

        // A pinned provider without a subscription has nothing to show.
        client.beforeSend = { command in
            await MainActor.run { client.emit(Self.reply(commandID: command.id, providers: ["anthropic"])) }
        }
        #expect(await reopened.load(force: true))
        #expect(reopened.menuBarProviders.isEmpty)
    }

    @Test func decodesTheProtocolFixtureIncludingAStaleProvider() throws {
        let url = try #require(try fixtureURLs(in: "contracts/protocol").first { $0.lastPathComponent == "usage-limits-result.event.json" })
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(contentsOf: url))
        guard case .usageLimitsResult(let result) = envelope.event, let snapshot = result.snapshot else {
            Issue.record("Expected usageLimitsResult with a snapshot")
            return
        }
        let codex = try #require(snapshot.provider(.openaiCodex))
        #expect(codex.isStale)
        #expect(codex.session == nil)
        #expect(codex.weekly?.remainingPercent == 80)
        #expect(snapshot.provider(.anthropic)?.resets?.available == 1)
    }

    @Test func presentationUsesRemainingShareAndModelProvider() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PickyUsageLimitTone(window: .init(usedPercent: 69, resetsAt: nil)) == .normal)
        #expect(PickyUsageLimitTone(window: .init(usedPercent: 70, resetsAt: nil)) == .warning)
        #expect(PickyUsageLimitTone(window: .init(usedPercent: 90, resetsAt: nil)) == .danger)
        #expect(PickyUsageLimitTone(window: nil) == .unknown)

        #expect(PickyUsageResetDeadlineTone(expiresAt: now.addingTimeInterval(47 * 3600), now: now) == .within48Hours)
        #expect(PickyUsageResetDeadlineTone(expiresAt: now.addingTimeInterval(6 * 24 * 3600), now: now) == .withinWeek)
        #expect(PickyUsageResetDeadlineTone(expiresAt: now.addingTimeInterval(8 * 24 * 3600), now: now) == .later)

        #expect(PickyUsageLimitsProviderID.forModel("claude-opus-4-5") == .anthropic)
        #expect(PickyUsageLimitsProviderID.forModel("gpt-5.1-codex") == .openaiCodex)
        #expect(PickyUsageLimitsProviderID.forModel("openai-codex/gpt-5.1") == .openaiCodex)
        #expect(PickyUsageLimitsProviderID.forModel("amazon-bedrock/claude-opus-4-5") == nil)
        #expect(PickyUsageLimitsProviderID.forModel("gemini-2.5-pro") == nil)
    }

    @Test func evenPaceMarksWhatShouldRemainAndFlagsFastUsage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Two of five session hours left: an even pace leaves 40%.
        let session = PickyUsageLimitWindow(usedPercent: 70, resetsAt: now.addingTimeInterval(2 * 3600))
        let pace = try #require(PickyUsageLimitPace(window: session, kind: .session, now: now))
        #expect(abs(pace.expectedRemainingFraction - 0.4) < 0.0001)
        #expect(pace.isAhead)
        // Within the tolerance is not flagged.
        let close = PickyUsageLimitWindow(usedPercent: 63, resetsAt: now.addingTimeInterval(2 * 3600))
        #expect(PickyUsageLimitPace(window: close, kind: .session, now: now)?.isAhead == false)
        // Half the week left with 80% remaining is behind pace.
        let weekly = PickyUsageLimitWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(3.5 * 24 * 3600))
        #expect(PickyUsageLimitPace(window: weekly, kind: .weekly, now: now)?.isAhead == false)
        // No reset time, a past reset, or a reset beyond the window length has no pace.
        #expect(PickyUsageLimitPace(window: .init(usedPercent: 10, resetsAt: nil), kind: .weekly, now: now) == nil)
        #expect(PickyUsageLimitPace(window: .init(usedPercent: 10, resetsAt: now.addingTimeInterval(-60)), kind: .weekly, now: now) == nil)
        #expect(PickyUsageLimitPace(window: .init(usedPercent: 10, resetsAt: now.addingTimeInterval(6 * 3600)), kind: .session, now: now) == nil)
    }

    @Test func formatsResetCountdownsInKoreanAndEnglish() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyUsageLimitsPresentation.durationText(until: now.addingTimeInterval(27 * 60), now: now) == "27분")
            #expect(PickyUsageLimitsPresentation.durationText(until: now.addingTimeInterval(28 * 3600), now: now) == "1일 4시간")
            #expect(PickyUsageLimitsPresentation.resetText(.init(usedPercent: 5, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)), now: now) == "2시간 14분 후 초기화")
            #expect(PickyUsageLimitsPresentation.remainingText(.init(usedPercent: 5, resetsAt: nil)) == "95% 남음")
        }
        LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            #expect(PickyUsageLimitsPresentation.resetText(.init(usedPercent: 5, resetsAt: now.addingTimeInterval(27 * 60)), now: now) == "Resets in 27m")
            #expect(PickyUsageLimitsPresentation.resetsText(.init(available: 2, nextExpiresAt: nil)) == "2 available")
        }
    }

    // MARK: - Helpers

    private func waitUntil(timeoutMs: Int, _ condition: @escaping @MainActor () async -> Bool) async throws {
        try await withPickyTestTimeout("usage limits condition", timeout: .milliseconds(timeoutMs)) {
            while !(await condition()) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private static func defaults() -> UserDefaults {
        let suite = "PickyUsageLimitsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func reply(commandID: String, ok: Bool = true, providers: [String] = ["anthropic"]) -> PickyClientEvent {
        let entries = providers.map { provider in
            provider == "anthropic"
                ? #"{"provider":"anthropic","plan":"Max 20x","checkedAt":"2026-10-05T15:00:00.000Z","errorMessage":null,"session":{"usedPercent":7,"resetsAt":"2026-10-05T17:40:00.000Z"},"weekly":{"usedPercent":3,"resetsAt":null},"resets":{"available":1,"nextExpiresAt":null}}"#
                : #"{"provider":"openai-codex","plan":"Plus","checkedAt":"2026-10-05T15:00:00.000Z","errorMessage":null,"session":null,"weekly":{"usedPercent":20,"resetsAt":null},"resets":null}"#
        }
        let body = ok
            ? #""ok":true,"errorMessage":null,"snapshot":{"checkedAt":"2026-10-05T15:00:00.000Z","providers":[\#(entries.joined(separator: ","))]}"#
            : #""ok":false,"errorMessage":"Usage limits unavailable""#
        let json = #"{"id":"event-\#(UUID().uuidString)","protocolVersion":"\#(pickyAgentProtocolVersion)","timestamp":"2026-10-05T15:00:00.000Z","type":"usageLimitsResult","commandId":"\#(commandID)",\#(body)}"#
        let envelope = try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(json.utf8))
        return .protocolEvent(envelope)
    }
}

@MainActor
private final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ delay: TimeInterval) { values.append(delay) }
}

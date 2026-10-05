//
//  PickyRemoteProtocolTests.swift
//  PickyTests
//
//  Wire-level contract between the hub in Picky.app and the gateway. The
//  example messages in `contracts/remote/hub/` are the shared source of truth,
//  so these tests fail the moment either side drifts.
//

import Foundation
import Speech
import Testing
@testable import Picky

struct PickyRemoteProtocolTests {
    @Test func everyGatewayExampleDecodes() throws {
        let urls = try fixtureURLs(in: "contracts/remote/hub/gateway-to-hub")
        #expect(urls.count >= 13)
        for url in urls {
            let decoded = try PickyRemoteProtocolCodec.decodeGatewayMessage(Data(contentsOf: url))
            // A silent default would let a contract change slip through, so
            // assert the example actually produced the case its name promises.
            switch (url.lastPathComponent, decoded) {
            case ("hello.json", .hello(let version, _, _)):
                #expect(version == PickyRemoteHubProtocol.version)
            case ("devices.json", .devices(let devices)):
                #expect(devices.count == 2)
                #expect(devices.first?.lastSeenAt != nil)
                #expect(devices.last?.lastSeenAt == nil)
            case ("pairing.json", .pairing(let code, _, let url)):
                #expect(code == "K7QM-4XTR")
                #expect(url?.hasSuffix("#pair=K7QM-4XTR") == true)
            case ("pairing-no-url.json", .pairing(_, _, let url)):
                #expect(url == nil)
            case ("pairing-ended.json", .pairingEnded(let reason, let name)):
                #expect(reason == .paired)
                #expect(name != nil)
            case ("pairing-ended-expired.json", .pairingEnded(let reason, _)):
                #expect(reason == .expired)
            case (let name, .request(_, _, let request)) where name.hasPrefix("request-"):
                #expect(Self.requestName(request) == name)
            default:
                Issue.record("\(url.lastPathComponent) decoded into an unexpected case: \(decoded)")
            }
        }
    }

    @Test func everyHubExampleRoundTripsToTheSameJSON() throws {
        let urls = try fixtureURLs(in: "contracts/remote/hub/hub-to-gateway")
        #expect(urls.count >= 13)
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        for url in urls {
            let original = try Data(contentsOf: url)
            let message = try decoder.decode(PickyHubToGatewayMessage.self, from: original)
            let encoded = try PickyRemoteProtocolCodec.encodeHubMessage(message)
            #expect(
                try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
                    == JSONSerialization.jsonObject(with: original) as? NSDictionary,
                "\(url.lastPathComponent) did not round-trip"
            )
        }
    }

    @Test func unknownMessageTypesAreRejected() {
        let gateway = Data(#"{"type":"gateway.somethingNew"}"#.utf8)
        #expect(throws: DecodingError.self) { try PickyRemoteProtocolCodec.decodeGatewayMessage(gateway) }
    }

    /// `available: true` carries no reason on the wire, so a stale reason must
    /// not leak back out when the hub re-encodes its own config.
    @Test func dictationAvailabilityDropsTheReasonWhenAvailable() throws {
        let availability = PickyRemoteDictationAvailability(available: true, reason: .macPermission)
        let encoded = try PickyRemoteProtocolCodec.encodeHubMessage(.config(publicUrl: nil, dictation: availability))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let dictation = try #require(object["dictation"] as? [String: Any])
        #expect(dictation["available"] as? Bool == true)
        #expect(dictation["reason"] == nil)
        #expect(object["publicUrl"] == nil)
    }

    private static func requestName(_ request: PickyRemoteHubRequest) -> String {
        switch request {
        case .pickleCreate: "request-pickle-create.json"
        case .mainSend: "request-main-send.json"
        case .mainAbort: "request-main-abort.json"
        case .mainAnswer: "request-main-answer.json"
        case .sessionMarkRead: "request-mark-read.json"
        case .sessionArchive: "request-archive.json"
        case .dictationTranscribe: "request-dictation.json"
        }
    }
}

struct PickyRemoteAccessSettingsTests {
    @Test func settingsFileWithoutRemoteAccessKeepsTheOffDefaults() throws {
        let settings = try JSONDecoder().decode(PickySettings.self, from: Data(#"{}"#.utf8))
        #expect(settings.remoteAccess == .defaults)
        #expect(settings.remoteAccess.enabled == false)
        #expect(settings.remoteAccess.entrance == .tailscale)
        #expect(settings.remoteAccess.port == 17640)
        #expect(settings.remoteAccess.keepAwake == false)
    }

    @Test func unknownEntranceFallsBackInsteadOfFailingTheWholeFile() throws {
        let json = Data(#"{"remoteAccess":{"enabled":true,"entrance":"carrierPigeon","port":70000}}"#.utf8)
        let settings = try JSONDecoder().decode(PickySettings.self, from: json)
        #expect(settings.remoteAccess.enabled)
        #expect(settings.remoteAccess.entrance == .tailscale)
        // An out-of-range port would make the gateway fail to bind.
        #expect(settings.remoteAccess.port == 17640)
    }

    @Test(arguments: [
        ("mac.tailnet-1234.ts.net", "https://mac.tailnet-1234.ts.net"),
        ("https://picky.example.com/", "https://picky.example.com"),
        ("https://picky.example.com:8443/app", "https://picky.example.com:8443/app"),
        ("http://picky.example.com", nil),
        ("   ", nil)
    ])
    func publicURLNormalizationAcceptsWhatPeoplePaste(raw: String, expected: String?) {
        #expect(PickyRemoteAccessSettings.normalizedPublicURL(raw) == expected)
    }

    @Test func entranceDecidesWhereThePhoneConnects() {
        var settings = PickyRemoteAccessSettings(enabled: true, entrance: .tailscale)
        #expect(settings.publicURL(tailscaleHostname: "mac.ts.net") == "https://mac.ts.net")
        #expect(settings.publicURL(tailscaleHostname: nil) == nil)
        settings.entrance = .cloudflare
        settings.cloudflareURL = "https://picky.example.com/"
        #expect(settings.publicURL(tailscaleHostname: "mac.ts.net") == "https://picky.example.com")
        settings.entrance = .localOnly
        #expect(settings.publicURL(tailscaleHostname: "mac.ts.net") == nil)
    }
}

struct PickyRemoteOverlayBuilderTests {
    @Test func archivedSessionsNeverAppearTwiceAndUnreadNeverPointsAtNothing() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(id: "g1", name: "  ", color: .teal, memberSessionIDs: ["s1", "s1", "gone"]))
        ])
        let overlay = PickyRemoteOverlayBuilder.build(
            activeSessionIDs: ["s1", "s2", "s1"],
            archivedSessionIDs: ["s2", "s3"],
            unreadSessionIDs: ["s1", "s3", "ghost"],
            dockLayout: layout,
            pinnedFolders: ["/a", "/a"],
            recentFolders: ["/b"]
        )

        #expect(overlay.activeSessionIds == ["s1"])
        #expect(overlay.archivedSessionIds == ["s2", "s3"])
        #expect(overlay.unreadSessionIds == ["s1"])
        #expect(overlay.folders == PickyRemoteOverlayFolders(pinned: ["/a"], recent: ["/b"]))
        let group = try? #require(overlay.groups.first)
        #expect(group?.memberIds == ["s1"])
        #expect(group?.name == "Untitled")
    }
}

struct PickyRemotePairingTests {
    @Test func qrPayloadPrefersTheGatewayURLAndOtherwiseBuildsOne() {
        #expect(PickyRemotePairingSession.qrPayload(
            publicURL: "https://mac.ts.net",
            code: "K7QM-4XTR",
            gatewayURL: "https://mac.ts.net/#pair=K7QM4XTR"
        ) == "https://mac.ts.net/#pair=K7QM4XTR")
        #expect(PickyRemotePairingSession.qrPayload(
            publicURL: "https://mac.ts.net/",
            code: "k7qm-4xtr",
            gatewayURL: nil
        ) == "https://mac.ts.net/#pair=K7QM4XTR")
        #expect(PickyRemotePairingSession.qrPayload(publicURL: nil, code: "K7QM4XTR", gatewayURL: nil) == nil)
    }

    @Test func codeIsShownInTheShapeThePhoneAccepts() {
        #expect(PickyRemotePairingSession.formatted(code: "k7qm4xtr") == "K7QM-4XTR")
        #expect(PickyRemotePairingSession.formatted(code: "K7QM-4XTR") == "K7QM-4XTR")
        // Anything that is not eight characters is shown as-is rather than
        // silently mangled into a wrong-looking code.
        #expect(PickyRemotePairingSession.formatted(code: "ABC") == "ABC")
    }

    @Test func countdownNeverGoesNegative() {
        let session = PickyRemotePairingSession(code: "K7QM4XTR", expiresAt: Date(timeIntervalSince1970: 100), url: nil)
        #expect(session.secondsRemaining(now: Date(timeIntervalSince1970: 70)) == 30)
        #expect(session.secondsRemaining(now: Date(timeIntervalSince1970: 400)) == 0)
    }
}

struct PickyRemoteTailscaleTests {
    @Test func magicDNSNameLosesTheTrailingDot() {
        let json = Data(#"{"Self":{"DNSName":"mac.tailnet-1234.ts.net."}}"#.utf8)
        #expect(PickyTailscaleParser.magicDNSName(fromStatusJSON: json) == "mac.tailnet-1234.ts.net")
        #expect(PickyTailscaleParser.magicDNSName(fromStatusJSON: Data(#"{}"#.utf8)) == nil)
    }

    @Test func serveStatusReportsWhetherTheLoopbackPortIsPublished() {
        let json = Data(#"""
        {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:17640"}}}}}
        """#.utf8)
        let state = PickyTailscaleParser.serveState(fromServeStatusJSON: json)
        #expect(state.isServing)
        #expect(state.port == 17640)
        #expect(PickyTailscaleParser.serveState(fromServeStatusJSON: Data(#"{}"#.utf8)) == (false, nil))
    }

    /// The CLI's own advice (usually a link to enable HTTPS certificates) is
    /// the only thing that lets the user fix this, so it must survive.
    @Test func failureKeepsTheLinkTheCLIPrinted() {
        let message = PickyTailscaleParser.readableFailure(
            stdout: "",
            stderr: """
            Error: HTTPS is not enabled for this tailnet.

            Enable it at https://login.tailscale.com/admin/dns
            """
        )
        #expect(message.contains("https://login.tailscale.com/admin/dns"))
        #expect(!message.contains("\n\n"))
        #expect(!PickyTailscaleParser.readableFailure(stdout: "", stderr: "  ").isEmpty)
    }
}

struct PickyRemoteDictationReadinessTests {
    @Test(arguments: [
        (true, true, SFSpeechRecognizerAuthorizationStatus.authorized, PickyRemoteDictationReadiness.ready),
        (true, false, SFSpeechRecognizerAuthorizationStatus.notDetermined, PickyRemoteDictationReadiness.ready),
        (true, true, SFSpeechRecognizerAuthorizationStatus.notDetermined, PickyRemoteDictationReadiness.needsPermission),
        (true, true, SFSpeechRecognizerAuthorizationStatus.denied, PickyRemoteDictationReadiness.needsPermission),
        (false, false, SFSpeechRecognizerAuthorizationStatus.authorized, PickyRemoteDictationReadiness.serviceNotConfigured)
    ])
    func readinessFollowsTheServiceAndItsPermission(
        isConfigured: Bool,
        requiresPermission: Bool,
        status: SFSpeechRecognizerAuthorizationStatus,
        expected: PickyRemoteDictationReadiness
    ) {
        #expect(PickyRemoteDictationReadiness.evaluate(
            isConfigured: isConfigured,
            requiresSpeechRecognitionPermission: requiresPermission,
            speechAuthorizationStatus: status
        ) == expected)
    }

    /// `notDetermined` must read as "needs permission", never as "ask now":
    /// prompting would raise a dialog on a Mac nobody is sitting at.
    @Test func readinessMapsOntoTheWireAndErrorCodes() {
        #expect(PickyRemoteDictationReadiness.ready.availability == .availableNow)
        #expect(PickyRemoteDictationReadiness.ready.errorCode == nil)
        #expect(PickyRemoteDictationReadiness.needsPermission.availability == .unavailable(.macPermission))
        #expect(PickyRemoteDictationReadiness.needsPermission.errorCode == PickyRemoteHubErrorCode.macPermission)
        #expect(PickyRemoteDictationReadiness.serviceNotConfigured.availability == .unavailable(.macService))
        #expect(PickyRemoteDictationReadiness.unavailable.errorCode == PickyRemoteHubErrorCode.macUnavailable)
    }
}

struct PickyRemoteContextOwnerTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func remoteOwnerNeitherSpeaksNorPaintsTheCursor() {
        #expect(PickyContextOwner.remote.isVoiceOwned == false)
        #expect(PickyContextOwner.remote.usesCursorResponsePresentation == false)
    }

    /// The reply to a phone turn belongs on the phone. Registering the owner is
    /// the only thing standing between a remote turn and a desktop bubble.
    @Test func remoteTurnLeavesTheDesktopUntouchedWhenItsReplyArrives() throws {
        let context = PickyRemoteMainAgentAdapter.remoteContext(transcript: "ship it")
        let registered = reduce(PickyInteractionState(), .remoteContextCaptured(context: context))
        #expect(registered.state.contextOwnership[context.id] == .remote)
        #expect(registered.state.output == .idle)
        #expect(registered.effects.isEmpty)

        let replied = reduce(
            registered.state,
            .quickReply(contextID: context.id, text: "done", originSource: .text, replyKind: .main, sessionID: nil, inputID: nil)
        )
        #expect(replied.state.output == .idle)
        #expect(replied.state.lastDisplayMessage == nil)
        #expect(replied.effects.isEmpty)
    }

    /// Same reply shape with no remote registration still shows on the Mac, so
    /// the test above is measuring the owner and not an unrelated no-op.
    @Test func anOrdinaryTextTurnStillShowsItsReply() {
        let replied = reduce(
            PickyInteractionState(),
            .quickReply(contextID: "ctx-text", text: "done", originSource: .text, replyKind: .main, sessionID: nil, inputID: nil)
        )
        #expect(replied.state.lastDisplayMessage?.text == "done")
    }

    @Test func remoteEventSurvivesTheJournalRoundTrip() throws {
        let event = PickyInteractionEvent.remoteContextCaptured(
            context: PickyRemoteMainAgentAdapter.remoteContext(transcript: "ship it")
        )
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(PickyInteractionEvent.self, from: data) == event)
    }

    private func reduce(_ state: PickyInteractionState, _ event: PickyInteractionEvent) -> PickyInteractionTransition {
        PickyInteractionReducer.reduce(
            state: state,
            envelope: PickyInteractionEnvelope(
                id: UUID(),
                occurredAt: baseDate,
                event: event,
                correlation: PickyInteractionCorrelation(source: .system)
            )
        )
    }
}

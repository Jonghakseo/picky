//
//  PickyHubRemoteAccessPresentationTests.swift
//  PickyTests
//

import Foundation
import Speech
import Testing
@testable import Picky

@MainActor
struct PickyHubRemoteAccessPresentationTests {
    private func status(
        enabled: Bool,
        gateway: PickyRemoteGatewayState,
        entranceURL: String?
    ) -> PickyHubRemoteAccessStatus {
        PickyHubRemoteAccessStatus.resolve(
            isEnabled: enabled,
            gatewayState: gateway,
            entranceURL: entranceURL
        )
    }

    @Test func readsAsOffWhateverTheGatewayIsDoingWhenTheSettingIsOff() {
        #expect(status(enabled: false, gateway: .running(port: 17640), entranceURL: "https://mac.ts.net") == .off)
        #expect(status(enabled: false, gateway: .failed("boom"), entranceURL: nil) == .off)
    }

    @Test func treatsTheGapBeforeTheFirstLaunchAsStarting() {
        // Saving the toggle and the launcher's first transition are separate
        // turns; a momentary `stopped` must not read as "off" under a live switch.
        #expect(status(enabled: true, gateway: .stopped, entranceURL: nil) == .starting)
        #expect(status(enabled: true, gateway: .starting, entranceURL: nil) == .starting)
    }

    @Test func separatesRunningWithAnAddressFromRunningWithoutOne() {
        #expect(
            status(enabled: true, gateway: .running(port: 17640), entranceURL: "https://mac.ts.net")
                == .running(address: "https://mac.ts.net")
        )
        #expect(status(enabled: true, gateway: .running(port: 17640), entranceURL: nil) == .runningWithoutAddress)
        #expect(status(enabled: true, gateway: .running(port: 17640), entranceURL: "") == .runningWithoutAddress)
    }

    @Test func keepsTheGatewayReasonAndOffersARestartOnlyOnFailure() {
        let failed = status(enabled: true, gateway: .failed("gateway exited with 9"), entranceURL: nil)
        #expect(failed.message == "gateway exited with 9")
        #expect(failed.retryTitle != nil)
        #expect(status(enabled: true, gateway: .running(port: 1), entranceURL: "https://a.b").retryTitle == nil)
        #expect(status(enabled: false, gateway: .stopped, entranceURL: nil).retryTitle == nil)
    }

    @Test func allowsLoopbackPairingWithoutAPublicAddress() {
        #expect(
            PickyHubRemotePairingAvailability.resolve(isRunning: true, isHubConnected: true, entrance: .localOnly, publicURL: nil)
                == .available
        )
        #expect(
            PickyHubRemotePairingAvailability.resolve(isRunning: true, isHubConnected: true, entrance: .tailscale, publicURL: nil)
                == .needsEntrance
        )
        #expect(
            PickyHubRemotePairingAvailability.resolve(isRunning: false, isHubConnected: false, entrance: .localOnly, publicURL: nil)
                == .needsRemoteAccessOn
        )
    }

    /// `hub.pairing.start` is dropped while the socket is down, so the sheet
    /// would sit on "waiting for a code" that nobody asked for.
    @Test func pairingIsUnavailableWhileTheHubSocketIsDown() {
        let availability = PickyHubRemotePairingAvailability.resolve(
            isRunning: true,
            isHubConnected: false,
            entrance: .cloudflare,
            publicURL: "https://picky.example.com"
        )
        #expect(availability == .needsConnection)
        #expect(availability.isAvailable == false)
        #expect(availability.detailKey == "settings.remote.pair.disabledDisconnected")
    }

    @Test func asksForSpeechPermissionOnlyWhileTheAnswerIsStillOpen() {
        #expect(
            PickyHubRemoteSpeechPermission.resolve(readiness: .needsPermission, authorization: .notDetermined)
                == .askOnThisMac
        )
        #expect(
            PickyHubRemoteSpeechPermission.resolve(readiness: .needsPermission, authorization: .denied)
                == .blocked
        )
        // A configured provider or a service problem is not this row's business.
        #expect(PickyHubRemoteSpeechPermission.resolve(readiness: .ready, authorization: .notDetermined) == .hidden)
        #expect(
            PickyHubRemoteSpeechPermission.resolve(readiness: .serviceNotConfigured, authorization: .notDetermined)
                == .hidden
        )
    }

    @Test func prefersTheGatewayPairingURLOverAnythingDerived() {
        let session = PickyRemotePairingSession(
            code: "ABCD1234",
            expiresAt: Date().addingTimeInterval(300),
            url: "https://mac.ts.net/#pair=ABCD1234"
        )
        #expect(
            PickyHubRemotePairingPayload.resolve(
                session: session,
                entrance: .tailscale,
                publicURL: "https://other.ts.net",
                localURL: "http://127.0.0.1:17640"
            ) == "https://mac.ts.net/#pair=ABCD1234"
        )
    }

    @Test func fallsBackToALoopbackPayloadOnlyForTheLocalEntrance() {
        let session = PickyRemotePairingSession(code: "abcd-1234", expiresAt: Date(), url: nil)
        #expect(
            PickyHubRemotePairingPayload.resolve(
                session: session,
                entrance: .localOnly,
                publicURL: nil,
                localURL: "http://127.0.0.1:17640"
            ) == "http://127.0.0.1:17640/#pair=ABCD1234"
        )
        // A tailnet that has not reported a name yet must not hand the phone a
        // loopback address it cannot open.
        #expect(
            PickyHubRemotePairingPayload.resolve(
                session: session,
                entrance: .tailscale,
                publicURL: nil,
                localURL: "http://127.0.0.1:17640"
            ) == nil
        )
    }

    @Test func pointsTheWrittenStepsAtTheEntranceTheUserChose() {
        #expect(
            PickyHubRemotePairingPayload.address(
                entrance: .localOnly,
                publicURL: "https://mac.ts.net",
                localURL: "http://127.0.0.1:17640"
            ) == "http://127.0.0.1:17640"
        )
        #expect(
            PickyHubRemotePairingPayload.address(
                entrance: .cloudflare,
                publicURL: "https://picky.example.com",
                localURL: "http://127.0.0.1:17640"
            ) == "https://picky.example.com"
        )
    }
}

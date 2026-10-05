//
//  PickyRemoteAccessController.swift
//  Picky
//
//  Owns remote access as a whole: the gateway process, the hub socket, what
//  the settings page renders, and the actions it offers. Everything here is
//  inert until the user turns remote access on.
//

import Combine
import Foundation

/// The gateway process as the controller uses it, so tests can run the whole
/// lifecycle without spawning Node.
@MainActor
protocol PickyRemoteGatewayControlling: AnyObject {
    var state: PickyRemoteGatewayState { get }
    var onStateChange: ((PickyRemoteGatewayState) -> Void)? { get set }
    func start(port: Int, hubToken: String, appSupportRoot: URL)
    func stop()
    func stopAndWaitForExit()
}

extension PickyRemoteGatewayLauncher: PickyRemoteGatewayControlling {}

/// Remembers the last temporary address across launches, so a new one after a
/// restart can be called out even though the old phones are still listed.
struct PickyQuickTunnelAddressMemory {
    var load: () -> String?
    var save: (String) -> Void

    static let userDefaultsKey = "PickyRemoteQuickTunnelLastURL"

    static let userDefaults = PickyQuickTunnelAddressMemory(
        load: { UserDefaults.standard.string(forKey: userDefaultsKey) },
        save: { UserDefaults.standard.set($0, forKey: userDefaultsKey) }
    )
}

@MainActor
final class PickyRemoteAccessController: ObservableObject {
    /// What the "폰 연결" sheet shows. `ended` stays until the user dismisses
    /// it so a code that expired while the sheet was covered is still explained.
    enum PairingPhase: Equatable {
        case idle
        case waiting(PickyRemotePairingSession)
        case ended(reason: PickyRemotePairingEndReason, deviceName: String?)
    }

    /// `hub.overlay` is a full snapshot, so coalescing bursts costs nothing but
    /// saves the phone a redraw per dock mutation.
    private static let overlayThrottle: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(300)

    @Published private(set) var settings: PickyRemoteAccessSettings
    @Published private(set) var gatewayState: PickyRemoteGatewayState = .stopped
    @Published private(set) var isHubConnected = false
    @Published private(set) var devices: [PickyRemoteDevice] = []
    @Published private(set) var pairing: PairingPhase = .idle
    @Published private(set) var tailscaleStatus: PickyTailscaleStatus?
    @Published private(set) var isTailscaleInstalled: Bool
    @Published private(set) var isTailscaleBusy = false
    @Published private(set) var tailscaleError: String?
    @Published private(set) var dictation: PickyRemoteDictationReadiness = .unavailable
    @Published private(set) var quickTunnelState: PickyQuickTunnelState = .stopped
    /// The temporary address differs from the one phones last paired through.
    /// Cleared by the next successful pairing or when the user dismisses it.
    @Published private(set) var quickTunnelAddressChanged = false

    let macName: String

    private let gateway: any PickyRemoteGatewayControlling
    private let transport: any PickyRemoteHubTransport
    private let overlaySource: (any PickyRemoteOverlaySource)?
    private let topologySource: (any PickyRemoteDaemonTopologySource)?
    private let requestHandler: PickyRemoteHubRequestHandler
    private let dictationReadiness: () -> PickyRemoteDictationReadiness
    private let tailscale: PickyTailscaleService
    private let quickTunnel: any PickyQuickTunnelControlling
    private let quickTunnelAddressMemory: PickyQuickTunnelAddressMemory
    private let appSupportRoot: URL
    private let appVersion: String
    private let tokenFactory: () -> String

    private var hubToken: String?
    private var lastSentOverlay: PickyRemoteOverlaySnapshot?
    private var lastSentTopology: PickyRemoteDaemonTopology?
    private var cancellables: Set<AnyCancellable> = []
    private var keepAwakeToken: NSObjectProtocol?

    init(
        settings: PickyRemoteAccessSettings,
        gateway: any PickyRemoteGatewayControlling,
        transport: any PickyRemoteHubTransport,
        overlaySource: (any PickyRemoteOverlaySource)?,
        topologySource: (any PickyRemoteDaemonTopologySource)?,
        requestHandler: PickyRemoteHubRequestHandler,
        dictationReadiness: @escaping () -> PickyRemoteDictationReadiness,
        tailscale: PickyTailscaleService = PickyTailscaleService(),
        quickTunnel: (any PickyQuickTunnelControlling)? = nil,
        quickTunnelAddressMemory: PickyQuickTunnelAddressMemory = .userDefaults,
        appSupportRoot: URL = PickyAppSupport.defaultRoot(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        macName: String = ProcessInfo.processInfo.hostName,
        tokenFactory: @escaping () -> String = PickyRemoteGatewayCommandResolver.randomHubToken
    ) {
        self.settings = settings
        self.gateway = gateway
        self.transport = transport
        self.overlaySource = overlaySource
        self.topologySource = topologySource
        self.requestHandler = requestHandler
        self.dictationReadiness = dictationReadiness
        self.tailscale = tailscale
        self.quickTunnel = quickTunnel ?? PickyCloudflareQuickTunnel(appSupportRoot: appSupportRoot)
        self.quickTunnelAddressMemory = quickTunnelAddressMemory
        self.appSupportRoot = appSupportRoot
        self.appVersion = appVersion
        self.macName = macName
        self.tokenFactory = tokenFactory
        self.isTailscaleInstalled = tailscale.isInstalled
        wire()
    }

    // MARK: - Derived state for the settings page

    /// The https origin the phone opens. `nil` while the entrance is not usable
    /// yet, which is what disables pairing.
    var publicURL: String? {
        settings.publicURL(tailscaleHostname: tailscaleStatus?.magicDNSName, quickTunnelURL: quickTunnelState.url)
    }

    /// The entrance is still producing its address, so "no address" is a wait,
    /// not a setup problem.
    var isEntranceAddressPending: Bool {
        settings.usesQuickTunnel && (quickTunnelState == .starting || quickTunnelState == .stopped)
    }

    /// Only worth saying while some phone still holds the old address.
    var showsQuickTunnelAddressChange: Bool {
        settings.usesQuickTunnel && quickTunnelAddressChanged && !devices.isEmpty
    }

    /// Address to open on this Mac when the entrance is loopback only.
    var localURL: String { "http://127.0.0.1:\(settings.port)" }

    /// What the settings page shows and the QR encodes.
    var entranceURL: String? { settings.entrance == .localOnly ? localURL : publicURL }

    var onlineDeviceCount: Int { devices.filter(\.online).count }

    var isRunning: Bool {
        if case .running = gatewayState { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Called once at app start and again on every settings save. Restarting is
    /// limited to the two inputs the gateway process cannot change while it
    /// runs; everything else is pushed over the live socket.
    func apply(settings updated: PickyRemoteAccessSettings) {
        let previous = settings
        settings = updated
        defer { reconcileQuickTunnel() }
        if updated.enabled != previous.enabled || updated.port != previous.port {
            guard updated.enabled else {
                stopGateway()
                return
            }
            // A new port means a new gateway. Dropping the socket first keeps
            // the hub from holding a connection to the process being replaced.
            if previous.enabled { stopGateway() }
            startGateway()
            return
        }
        guard updated.enabled else { return }
        updateKeepAwake()
        refreshDictation()
        sendConfig()
    }

    /// Settings offers this after a failure. The launcher's own backoff grows to
    /// 30 seconds and a command-resolution failure never retries at all, so the
    /// user needs a way to try again now.
    func restartGateway() {
        guard settings.enabled else { return }
        stopGateway()
        startGateway()
    }

    func stopForAppTermination() {
        releaseKeepAwake()
        transport.disconnect()
        quickTunnel.stopAndWaitForExit()
        gateway.stopAndWaitForExit()
    }

    /// "Check again" after installing `cloudflared`, or "try again" after a
    /// failure the backoff has not retried yet.
    func restartQuickTunnel() {
        guard settings.usesQuickTunnel else { return }
        quickTunnel.stop()
        quickTunnel.start(port: settings.port)
    }

    func dismissQuickTunnelAddressChange() {
        quickTunnelAddressChanged = false
    }

    /// The tunnel follows the settings, not the gateway: it can wait in front
    /// of a gateway that is still starting, and a gateway restart must not
    /// cost the phone its address.
    private func reconcileQuickTunnel() {
        if settings.usesQuickTunnel {
            quickTunnel.start(port: settings.port)
        } else if quickTunnel.state != .stopped {
            quickTunnel.stop()
        }
    }

    private func handleQuickTunnelState(_ state: PickyQuickTunnelState) {
        quickTunnelState = state
        if let url = state.url {
            let previous = quickTunnelAddressMemory.load()
            if let previous, previous != url { quickTunnelAddressChanged = true }
            quickTunnelAddressMemory.save(url)
        }
        sendConfig()
    }

    private func startGateway() {
        let token = tokenFactory()
        hubToken = token
        gateway.start(port: settings.port, hubToken: token, appSupportRoot: appSupportRoot)
        updateKeepAwake()
        Task { await refreshTailscaleStatus() }
    }

    private func stopGateway() {
        transport.disconnect()
        gateway.stop()
        hubToken = nil
        devices = []
        pairing = .idle
        lastSentOverlay = nil
        lastSentTopology = nil
        releaseKeepAwake()
    }

    private func wire() {
        gateway.onStateChange = { [weak self] state in
            guard let self else { return }
            gatewayState = state
            updateKeepAwake()
            if case .running(let port) = state, let token = hubToken {
                transport.connect(url: URL(string: "ws://127.0.0.1:\(port)/hub")!, token: token)
            }
        }
        transport.onConnectedChange = { [weak self] connected in
            guard let self else { return }
            isHubConnected = connected
            if connected { sendHandshake() }
        }
        transport.onMessage = { [weak self] message in
            self?.handle(message)
        }
        quickTunnel.onStateChange = { [weak self] state in
            self?.handleQuickTunnelState(state)
        }
        overlaySource?.remoteOverlayPublisher
            .throttle(for: Self.overlayThrottle, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] snapshot in
                self?.sendOverlay(snapshot)
            }
            .store(in: &cancellables)
        topologySource?.remoteDaemonTopologyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] topology in
                self?.sendDaemons(topology)
            }
            .store(in: &cancellables)
        if settings.enabled { startGateway() }
        reconcileQuickTunnel()
    }

    // MARK: - Hub messages out

    private func sendHandshake() {
        transport.send(.hello(
            protocolVersion: PickyRemoteHubProtocol.version,
            appVersion: appVersion,
            macName: macName
        ))
        lastSentTopology = nil
        lastSentOverlay = nil
        if let topology = topologySource?.currentRemoteDaemonTopology() { sendDaemons(topology) }
        if let overlay = overlaySource?.currentRemoteOverlay() { sendOverlay(overlay) }
        // Read rather than refresh: the config below carries the result, and
        // `refreshDictation` would send a second one.
        dictation = dictationReadiness()
        sendConfig()
    }

    private func sendOverlay(_ snapshot: PickyRemoteOverlaySnapshot) {
        guard isHubConnected, snapshot != lastSentOverlay else { return }
        lastSentOverlay = snapshot
        transport.send(.overlay(snapshot))
    }

    private func sendDaemons(_ topology: PickyRemoteDaemonTopology) {
        guard isHubConnected, topology != lastSentTopology else { return }
        lastSentTopology = topology
        transport.send(topology.hubMessage)
    }

    private func sendConfig() {
        guard isHubConnected else { return }
        transport.send(.config(publicUrl: publicURL, dictation: dictation.availability))
    }

    /// Re-read because the speech service or its permission can change while
    /// remote access runs, and the phone hides its mic button from this flag.
    func refreshDictation() {
        let readiness = dictationReadiness()
        guard readiness != dictation else { return }
        dictation = readiness
        sendConfig()
    }

    // MARK: - Hub messages in

    private func handle(_ message: PickyGatewayToHubMessage) {
        switch message {
        case .hello(let protocolVersion, _, _):
            // A mismatch means the bundled gateway and the app shipped out of
            // step. Say so instead of failing one request at a time later.
            if protocolVersion != PickyRemoteHubProtocol.version {
                gatewayState = .failed(L10n.t("settings.remote.error.protocolMismatch"))
            }
        case .pairing(let code, let expiresAt, let url):
            pairing = .waiting(PickyRemotePairingSession(code: code, expiresAt: expiresAt, url: url))
        case .pairingEnded(let reason, let deviceName):
            pairing = .ended(reason: reason, deviceName: deviceName)
            if reason == .paired { quickTunnelAddressChanged = false }
        case .devices(let devices):
            self.devices = devices
        case .request(let requestId, _, let request):
            Task { [weak self] in
                guard let self else { return }
                let response = await requestHandler.handle(requestId: requestId, request: request)
                transport.send(.response(response))
            }
        }
    }

    // MARK: - Actions the settings page calls

    func startPairing() {
        pairing = .idle
        transport.send(.pairingStart)
    }

    func cancelPairing() {
        transport.send(.pairingCancel)
        pairing = .idle
    }

    func dismissPairingResult() {
        if case .ended = pairing { pairing = .idle }
    }

    func revokeDevice(id: String) {
        transport.send(.devicesRevoke(deviceId: id))
    }

    func renameDevice(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transport.send(.devicesRename(deviceId: id, name: trimmed))
    }

    // MARK: - Tailscale

    func refreshTailscaleStatus() async {
        isTailscaleInstalled = tailscale.isInstalled
        guard isTailscaleInstalled else {
            tailscaleStatus = nil
            return
        }
        do {
            tailscaleStatus = try await tailscale.status()
            tailscaleError = nil
        } catch {
            tailscaleStatus = nil
            tailscaleError = error.localizedDescription
        }
        sendConfig()
    }

    /// Runs `tailscale serve` only from a button press, never implicitly.
    func setTailscaleServe(enabled: Bool) async {
        guard !isTailscaleBusy else { return }
        isTailscaleBusy = true
        defer { isTailscaleBusy = false }
        do {
            if enabled {
                try await tailscale.startServe(port: settings.port)
            } else {
                try await tailscale.stopServe()
            }
            tailscaleError = nil
        } catch {
            tailscaleError = error.localizedDescription
        }
        await refreshTailscaleStatus()
    }

    // MARK: - Keep awake

    /// Idle sleep only. Closing the lid still sleeps the Mac, and the settings
    /// copy says so.
    private func updateKeepAwake() {
        guard settings.enabled, settings.keepAwake, gatewayState.isActive else {
            releaseKeepAwake()
            return
        }
        guard keepAwakeToken == nil else { return }
        keepAwakeToken = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Picky remote access"
        )
    }

    private func releaseKeepAwake() {
        guard let keepAwakeToken else { return }
        ProcessInfo.processInfo.endActivity(keepAwakeToken)
        self.keepAwakeToken = nil
    }
}

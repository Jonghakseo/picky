//
//  PickyHUDDockExternalDragCoordinator.swift
//  Picky
//
//  MainActor bridge between frozen Dock-drag policy and AppKit event monitors.
//  Overlay Manager wiring and real preview panels are intentionally deferred.
//

import AppKit

@MainActor
protocol PickyHUDDockExternalDragPreviewDriving: AnyObject {
    func begin()
    func update(destination: PickyDockContainer?)
    func finish(committed: Bool)
}

struct PickyHUDDockExternalDragPromotion {
    let token: UUID
    let sessionID: String
    let sourceGroupID: String
    let frozenLayout: PickyDockLayout
    let fingerprint: PickyHUDDockLayoutFingerprint
    let geometry: PickyHUDDockExternalDragGeometrySnapshot

    var isConsistent: Bool {
        fingerprint.dockSide == geometry.dockSide
            && fingerprint.geometryRevision == geometry.geometryRevision
            && frozenLayout.group(withID: sourceGroupID)?.memberSessionIDs.contains(sessionID) == true
    }
}

@MainActor
final class PickyHUDDockExternalDragCoordinator {
    typealias EventMonitorInstaller = (
        _ mask: NSEvent.EventTypeMask,
        _ handler: @escaping (NSEvent) -> Void
    ) -> Any?
    typealias EventMonitorRemover = (_ monitor: Any) -> Void
    typealias MouseLocationProvider = () -> CGPoint
    typealias FingerprintProvider = () -> PickyHUDDockLayoutFingerprint
    typealias Commit = (_ sessionID: String, _ destination: PickyDockContainer) -> Void

    private let installLocalMonitor: EventMonitorInstaller
    private let installGlobalMonitor: EventMonitorInstaller
    private let removeMonitor: EventMonitorRemover
    private let mouseLocation: MouseLocationProvider
    private let currentFingerprint: FingerprintProvider
    private let preview: any PickyHUDDockExternalDragPreviewDriving
    private let commit: Commit

    private var state = PickyHUDDockExternalDragState()
    private var promotion: PickyHUDDockExternalDragPromotion?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(
        installLocalMonitor: @escaping EventMonitorInstaller = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                handler(event)
                return event
            }
        },
        installGlobalMonitor: @escaping EventMonitorInstaller = { mask, handler in
            NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        },
        removeMonitor: @escaping EventMonitorRemover = { NSEvent.removeMonitor($0) },
        mouseLocation: @escaping MouseLocationProvider = { NSEvent.mouseLocation },
        currentFingerprint: @escaping FingerprintProvider,
        preview: any PickyHUDDockExternalDragPreviewDriving,
        commit: @escaping Commit
    ) {
        self.installLocalMonitor = installLocalMonitor
        self.installGlobalMonitor = installGlobalMonitor
        self.removeMonitor = removeMonitor
        self.mouseLocation = mouseLocation
        self.currentFingerprint = currentFingerprint
        self.preview = preview
        self.commit = commit
    }

    /// Starts a single physical drag. List-panel promotion will call this only
    /// after synchronously revoking its own terminal event lease in Work Unit 8.
    @discardableResult
    func start(_ promotion: PickyHUDDockExternalDragPromotion) -> Bool {
        guard promotion.isConsistent, state.begin(token: promotion.token) else { return false }
        self.promotion = promotion
        preview.begin()

        localMonitor = installLocalMonitor([.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        globalMonitor = installGlobalMonitor([.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
        return true
    }

    /// Refreshes visible feedback from the frozen geometry. It does not read
    /// mutable rail projection, because that reflow is the consequence of this
    /// destination rather than an input to it.
    func update() {
        guard let promotion, state.acceptsUpdate(for: promotion.token) else { return }
        preview.update(destination: destination(for: promotion, at: mouseLocation()))
    }

    /// Explicitly callable by the existing local Escape owner. No global key
    /// monitor is installed, so this cannot cause an accessibility prompt.
    func cancelForEscape() {
        cancel(.escape)
    }

    func cancelForTeardown() {
        cancel(.teardown)
    }

    private func handle(_ event: NSEvent) {
        guard let promotion, state.acceptsUpdate(for: promotion.token) else { return }
        switch event.type {
        case .leftMouseDragged:
            update()
        case .leftMouseUp:
            finish(promotion)
        case .keyDown where event.keyCode == 53:
            cancel(.escape)
        default:
            break
        }
    }

    private func finish(_ promotion: PickyHUDDockExternalDragPromotion) {
        guard state.acceptsUpdate(for: promotion.token) else { return }
        let finalDestination: PickyDockContainer?
        let terminal: PickyHUDDockExternalDragTerminal
        if currentFingerprint() != promotion.fingerprint {
            finalDestination = nil
            terminal = .cancel(.staleLayout)
        } else {
            finalDestination = destination(for: promotion, at: mouseLocation())
            terminal = finalDestination.map(PickyHUDDockExternalDragTerminal.commit) ?? .cancel(.invalidDrop)
        }
        preview.update(destination: finalDestination)
        complete(token: promotion.token, terminal: terminal)
    }

    private func cancel(_ reason: PickyHUDDockExternalDragCancellation) {
        guard let promotion else { return }
        complete(token: promotion.token, terminal: .cancel(reason))
    }

    private func complete(token: UUID, terminal: PickyHUDDockExternalDragTerminal) {
        guard let sessionID = promotion?.sessionID,
              let claimed = state.claimTerminal(token: token, outcome: terminal)
        else { return }

        // Clear the coordinator's active payload and monitors before external
        // effects. Retained local/global callbacks therefore observe no owner.
        promotion = nil
        removeEventMonitors()
        switch claimed {
        case .commit(let destination):
            preview.finish(committed: true)
            state.finishTerminal()
            commit(sessionID, destination)
        case .cancel:
            preview.finish(committed: false)
            state.finishTerminal()
        }
    }

    private func destination(
        for promotion: PickyHUDDockExternalDragPromotion,
        at screenPoint: CGPoint
    ) -> PickyDockContainer? {
        PickyHUDDockExternalDragDestinationResolver.resolve(
            draggedSessionID: promotion.sessionID,
            sourceGroupID: promotion.sourceGroupID,
            screenPoint: screenPoint,
            geometry: promotion.geometry,
            layout: promotion.frozenLayout
        )
    }

    private func removeEventMonitors() {
        if let localMonitor { removeMonitor(localMonitor) }
        if let globalMonitor { removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    deinit {
        // `deinit` is nonisolated even for MainActor classes. Stored monitor
        // tokens and their remover are safe to release directly here.
        if let localMonitor { removeMonitor(localMonitor) }
        if let globalMonitor { removeMonitor(globalMonitor) }
    }
}

//
//  PickyHUDDockExternalDragCoordinator.swift
//  Picky
//
//  MainActor bridge between frozen Dock-drag policy and AppKit event monitors.
//  Overlay Manager wiring and real preview panels are intentionally deferred.
//

import AppKit

struct PickyHUDDockExternalDragPromotion {
    let token: UUID
    let sessionID: String
    let sourceGroupID: String
    /// Captured at the list-panel boundary so the detached preview never reads
    /// a live row model or geometry after ownership transfers.
    let previewPresentation: PickyHUDDockExternalDragPreviewPresentation
    let frozenLayout: PickyDockLayout
    let fingerprint: PickyHUDDockLayoutFingerprint
    let geometry: PickyHUDDockExternalDragGeometrySnapshot

    var isConsistent: Bool {
        previewPresentation.token == token
            && previewPresentation.sourceGroupID == sourceGroupID
            && previewPresentation.session.id == sessionID
            && fingerprint == geometry.layoutFingerprint
            && PickyHUDDockLayoutFingerprint(
                layout: frozenLayout,
                activeSessionIDs: fingerprint.activeSessionIDs,
                dockSide: fingerprint.dockSide,
                geometryRevision: fingerprint.geometryRevision
            ) == fingerprint
            && fingerprint.dockSide == geometry.dockSide
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

        localMonitor = installLocalMonitor([.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event, token: promotion.token)
        }
        globalMonitor = installGlobalMonitor([.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event, token: promotion.token)
        }

        guard localMonitor != nil, globalMonitor != nil else {
            removeEventMonitors()
            self.promotion = nil
            state.abandon(token: promotion.token)
            return false
        }

        preview.begin(promotion.previewPresentation)
        update()
        return true
    }

    /// Refreshes visible feedback from the frozen geometry. It does not read
    /// mutable rail projection, because that reflow is the consequence of this
    /// destination rather than an input to it.
    func update() {
        guard let promotion, state.acceptsUpdate(for: promotion.token) else { return }
        let pointer = mouseLocation()
        preview.update(pointerScreenPoint: pointer, destination: destination(for: promotion, at: pointer))
    }

    /// Explicitly callable by the existing local Escape owner. No global key
    /// monitor is installed, so this cannot cause an accessibility prompt.
    @discardableResult
    func cancelForEscape() -> Bool {
        cancel(.escape)
    }

    @discardableResult
    func cancelForTeardown() -> Bool {
        cancel(.teardown)
    }

    /// Snapshot/placement observers call this synchronously. A completed
    /// commit clears state before persistence, so its own reconciliation is inert.
    @discardableResult
    func cancelIfCurrentFingerprintIsStale() -> Bool {
        guard let promotion, currentFingerprint() != promotion.fingerprint else { return false }
        return cancel(.staleLayout)
    }

    private func handle(_ event: NSEvent, token: UUID) {
        guard let promotion,
              promotion.token == token,
              state.acceptsUpdate(for: token)
        else { return }
        switch event.type {
        case .leftMouseDragged:
            update()
        case .leftMouseUp:
            finish(promotion)
        default:
            break
        }
    }

    /// Completes a list-owned release that crossed the boundary between drag
    /// callbacks. The list transfers ownership before calling this, and stale
    /// local/global mouse-up copies cannot claim another terminal effect.
    @discardableResult
    func finishFromPhysicalMouseUp() -> Bool {
        guard let promotion else { return false }
        return finish(promotion)
    }

    @discardableResult
    private func finish(_ promotion: PickyHUDDockExternalDragPromotion) -> Bool {
        guard state.acceptsUpdate(for: promotion.token) else { return false }
        // A terminal pointer sample is shared by hit-testing and the final
        // preview frame. Sampling twice can commit one physical location while
        // showing feedback for another when AppKit advances between reads.
        let finalPointer = mouseLocation()
        let finalDestination: PickyDockContainer?
        let terminal: PickyHUDDockExternalDragTerminal
        if currentFingerprint() != promotion.fingerprint {
            finalDestination = nil
            terminal = .cancel(.staleLayout)
        } else {
            finalDestination = destination(for: promotion, at: finalPointer)
            terminal = finalDestination.map(PickyHUDDockExternalDragTerminal.commit) ?? .cancel(.invalidDrop)
        }
        preview.update(pointerScreenPoint: finalPointer, destination: finalDestination)
        return complete(token: promotion.token, terminal: terminal)
    }

    @discardableResult
    private func cancel(_ reason: PickyHUDDockExternalDragCancellation) -> Bool {
        guard let promotion else { return false }
        return complete(token: promotion.token, terminal: .cancel(reason))
    }

    @discardableResult
    private func complete(token: UUID, terminal: PickyHUDDockExternalDragTerminal) -> Bool {
        guard let sessionID = promotion?.sessionID,
              let claimed = state.claimTerminal(token: token, outcome: terminal)
        else { return false }

        // Clear the coordinator's active payload and monitors before external
        // effects. Retained local/global callbacks therefore observe no owner.
        promotion = nil
        removeEventMonitors()
        preview.finish(terminal: claimed)
        switch claimed {
        case .commit(let destination):
            state.finishTerminal()
            commit(sessionID, destination)
        case .cancel:
            state.finishTerminal()
        }
        return true
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

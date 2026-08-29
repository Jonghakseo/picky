//
//  PickyHUDOverlayManager+DockGroupList.swift
//  Picky
//
//  Dock group child-panel lifecycle and ownership.
//

import AppKit
import SwiftUI

@MainActor
extension PickyHUDOverlayManager {
    func handleDockGroupListGeometryChange(
        displayID: CGDirectDisplayID,
        badgeFrames: [String: CGRect],
        interactionFrames: [String: CGRect],
        railFrame: CGRect,
        isCommandShortcutHintVisible _: Bool,
        openedSessionID: String?
    ) {
        let geometry = DockGroupListGeometry(
            badgeFrames: badgeFrames,
            interactionFrames: interactionFrames,
            railFrame: railFrame,
            openedSessionID: openedSessionID
        )
        dockGroupListGeometryByDisplayID[displayID] = geometry
        guard var entry = dockGroupListChildrenByDisplayID[displayID] else { return }
        let previousOpenedSessionID = entry.openedSessionID
        let needsContentSync = entry.badgeFrames != geometry.badgeFrames
            || entry.interactionFrames != geometry.interactionFrames
            || entry.railFrame != geometry.railFrame
            || previousOpenedSessionID != geometry.openedSessionID
        entry.badgeFrames = geometry.badgeFrames
        entry.interactionFrames = geometry.interactionFrames
        entry.railFrame = geometry.railFrame
        entry.openedSessionID = geometry.openedSessionID
        dockGroupListChildrenByDisplayID[displayID] = entry
        if let openGroupID = entry.openGroupID,
           let group = PickyHUDDockGroupListSnapshotPolicy.group(
               groupID: openGroupID,
               in: viewModel.dockState.snapshot
           ),
           PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
               openGroupID: openGroupID,
               previousOpenedSessionID: previousOpenedSessionID,
               openedSessionID: geometry.openedSessionID,
               memberSessionIDs: group.memberSessionIDs
           ) == nil {
            hideDockGroupListChild(displayID: displayID)
            return
        }
        if let pendingGroupID = PickyHUDDockGroupListOpenPolicy.pendingGroupIDReadyToOpen(
            entry.pendingGroupID,
            anchoredGroupIDs: Set(entry.badgeFrames.keys),
            hasRailFrame: entry.railFrame != .zero
        ) {
            showDockGroupListChild(displayID: displayID, groupID: pendingGroupID)
        } else if entry.openGroupID != nil, needsContentSync {
            syncDockGroupListChild(displayID: displayID)
        }
    }

    func toggleDockGroupListChild(displayID: CGDirectDisplayID, groupID: String) {
        let entry = dockGroupListChildrenByDisplayID[displayID]
        let openGroupID = entry?.openGroupID ?? entry?.pendingGroupID
        let nextGroupID = PickyHUDDockGroupListOpenPolicy.toggled(
            openGroupID: openGroupID,
            tappedGroupID: groupID
        )
        guard let nextGroupID else {
            hideDockGroupListChild(displayID: displayID)
            return
        }
        showDockGroupListChild(displayID: displayID, groupID: nextGroupID)
    }

    private func showDockGroupListChild(
        displayID: CGDirectDisplayID,
        groupID: String,
        snapshot: PickyHUDDockSnapshot? = nil,
        fontScale: CGFloat? = nil
    ) {
        let snapshot = snapshot ?? viewModel.dockState.snapshot
        let fontScale = fontScale ?? fontScaleStore.cgValue
        guard visibilityStore.isVisible(for: displayID),
              let group = PickyHUDDockGroupListSnapshotPolicy.group(groupID: groupID, in: snapshot),
              let screen = screen(for: displayID),
              let hudEntry = panelsByDisplayID[displayID]
        else { return }
        let rowIDs = dockGroupListRowIDs(group: group, snapshot: snapshot)
        var didOpen = false
        dockGroupListChildEffectExecutor.open(
            groupID: groupID,
            visibleRowIDs: rowIDs,
            effects: .init(
                tearDown: { [weak self] in
                    self?.hideDockGroupListChild(displayID: displayID)
                },
                updateModel: { [weak self] in
                    guard let self else { return }
                    var entry = self.dockGroupListChildrenByDisplayID[displayID]
                        ?? DockGroupListChildEntry(panel: self.makeDockGroupListChildPanel())
                    if let geometry = self.dockGroupListGeometryByDisplayID[displayID] {
                        entry.badgeFrames = geometry.badgeFrames
                        entry.interactionFrames = geometry.interactionFrames
                        entry.railFrame = geometry.railFrame
                        entry.openedSessionID = geometry.openedSessionID
                    }
                    if let openGroupID = entry.openGroupID, openGroupID != groupID {
                        entry.panel.orderOut(nil)
                        entry.model = nil
                        self.dockGroupListOverlayLifecycle?.tearDown(displayID: displayID)
                    }
                    entry.pendingGroupID = PickyHUDDockGroupListOpenPolicy.pendingGroupID(afterRequestFor: groupID)
                    entry.openGroupID = nil
                    self.dockGroupListChildrenByDisplayID[displayID] = entry
                    guard entry.badgeFrames[groupID] != nil, entry.railFrame != .zero else {
                        pickySessionLog(
                            "dock group list open deferred group=\(groupID) display=\(displayID) "
                                + "reason=missing-anchor-geometry"
                        )
                        return
                    }

                    entry.pendingGroupID = nil
                    entry.openGroupID = groupID
                    let content = self.makeDockGroupListPanelContent(
                        group: group,
                        snapshot: snapshot,
                        openedSessionID: entry.openedSessionID,
                        metrics: PickyHUDDockMetrics(preset: self.currentDockSizePreset)
                    )
                    let model = entry.model ?? PickyHUDDockGroupListPanelModel(content: content)
                    model.update(content: content)
                    entry.model = model
                    self.dockGroupListFocusStore.open(
                        displayID: displayID,
                        groupID: groupID,
                        rowIDs: rowIDs
                    )
                    self.dockGroupListChildrenByDisplayID[displayID] = entry
                    didOpen = true
                },
                synchronizeHost: { [weak self] in
                    guard let self,
                          didOpen,
                          let entry = self.dockGroupListChildrenByDisplayID[displayID],
                          let model = entry.model
                    else { return }
                    _ = self.dockGroupListOverlayLifecycle?.synchronize(
                        displayID: displayID,
                        host: entry.panel,
                        groupID: groupID,
                        makeHosting: {
                            self.makeDockGroupListChildHostingView(
                                displayID: displayID,
                                model: model,
                                entry: entry
                            )
                        }
                    )
                },
                position: { [weak self] in
                    guard let self,
                          didOpen,
                          let entry = self.dockGroupListChildrenByDisplayID[displayID],
                          let folderFrame = entry.badgeFrames[groupID]
                    else { return }
                    self.positionDockGroupListChild(
                        displayID: displayID,
                        screen: screen,
                        hudPanelFrame: hudEntry.panel.frame,
                        folderFrame: folderFrame,
                        snapshot: snapshot,
                        fontScale: fontScale
                    )
                },
                present: { [weak self] in
                    guard let self,
                          didOpen,
                          let panel = self.dockGroupListChildrenByDisplayID[displayID]?.panel
                    else { return }
                    panel.alphaValue = 0
                    panel.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        panel.animator().alphaValue = 1
                    }
                    self.installDockGroupListMouseMonitors(displayID: displayID)
                }
            )
        )
    }

    func syncDockGroupListChild(
        displayID: CGDirectDisplayID,
        snapshot: PickyHUDDockSnapshot? = nil,
        fontScale: CGFloat? = nil
    ) {
        let snapshot = snapshot ?? viewModel.dockState.snapshot
        let fontScale = fontScale ?? fontScaleStore.cgValue
        guard var entry = dockGroupListChildrenByDisplayID[displayID] else { return }
        let existingGroupIDs = Set(snapshot.dockLayout.groups.map(\.id))
        let activeSessionIDs = Set(snapshot.activeSessions.map(\.id))
        let visibleMemberGroupIDs = Set(snapshot.dockLayout.groups.compactMap { group in
            group.memberSessionIDs.contains { activeSessionIDs.contains($0) } ? group.id : nil
        })
        if dockGroupListChildEffectExecutor.reconcilePending(
            pendingGroupID: entry.pendingGroupID,
            existingGroupIDs: existingGroupIDs,
            visibleMemberGroupIDs: visibleMemberGroupIDs,
            effects: .init(
                tearDown: { [weak self] in
                    self?.hideDockGroupListChild(displayID: displayID)
                },
                updatePendingGroupID: { [weak self] pendingGroupID in
                    guard let self,
                          var entry = self.dockGroupListChildrenByDisplayID[displayID]
                    else { return }
                    entry.pendingGroupID = pendingGroupID
                    self.dockGroupListChildrenByDisplayID[displayID] = entry
                },
                open: { [weak self] pendingGroupID in
                    self?.showDockGroupListChild(
                        displayID: displayID,
                        groupID: pendingGroupID,
                        snapshot: snapshot,
                        fontScale: fontScale
                    )
                }
            )
        ) {
            return
        }
        guard let groupID = entry.openGroupID else { return }
        guard let group = PickyHUDDockGroupListSnapshotPolicy.group(groupID: groupID, in: snapshot),
              let folderFrame = entry.badgeFrames[groupID],
              entry.railFrame != .zero,
              let screen = screen(for: displayID),
              let hudEntry = panelsByDisplayID[displayID],
              let model = entry.model
        else {
            let nextGroupID = PickyHUDDockGroupListOpenPolicy.afterGroupRemoved(
                openGroupID: groupID,
                removedGroupID: groupID
            )
            if nextGroupID == nil { hideDockGroupListChild(displayID: displayID) }
            return
        }
        let rowIDs = dockGroupListRowIDs(group: group, snapshot: snapshot)
        dockGroupListChildEffectExecutor.synchronize(
            groupID: groupID,
            visibleRowIDs: rowIDs,
            effects: .init(
                tearDown: { [weak self] in
                    self?.hideDockGroupListChild(displayID: displayID)
                },
                updateModel: { [weak self] in
                    guard let self else { return }
                    model.update(content: self.makeDockGroupListPanelContent(
                        group: group,
                        snapshot: snapshot,
                        openedSessionID: entry.openedSessionID,
                        metrics: PickyHUDDockMetrics(preset: self.currentDockSizePreset)
                    ))
                },
                updateFocus: { [weak self] in
                    self?.dockGroupListFocusStore.updateRows(
                        displayID: displayID,
                        rowIDs: rowIDs
                    )
                },
                position: { [weak self] in
                    self?.positionDockGroupListChild(
                        displayID: displayID,
                        screen: screen,
                        hudPanelFrame: hudEntry.panel.frame,
                        folderFrame: folderFrame,
                        snapshot: snapshot,
                        fontScale: fontScale
                    )
                }
            )
        )
    }

    /// Visible rows only: archived members stay in the group but never render,
    /// so they must not be reachable by number or arrow keys either.
    private func dockGroupListRowIDs(group: PickyDockGroup, snapshot: PickyHUDDockSnapshot) -> [String] {
        let activeIDs = Set(snapshot.activeSessions.map(\.id))
        return group.memberSessionIDs.filter { activeIDs.contains($0) }
    }

    private func makeDockGroupListPanelContent(
        group: PickyDockGroup,
        snapshot: PickyHUDDockSnapshot,
        openedSessionID: String?,
        metrics: PickyHUDDockMetrics
    ) -> PickyHUDDockGroupListPanelContent {
        let sessionsByID = Dictionary(snapshot.activeSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = PickyHUDDockGroupListRowProjection.rows(
            memberSessionIDs: group.memberSessionIDs,
            activeSessionsByID: sessionsByID,
            updatedAt: { [weak self] sessionID in self?.viewModel.sessionCard(sessionID: sessionID)?.updatedAt },
            makeRow: { session, updatedAt in
                PickyHUDDockGroupListRowModel(session: session, updatedAt: updatedAt)
            }
        )
        return PickyHUDDockGroupListPanelContent(
            group: group,
            rows: rows,
            unreadSessionIDs: snapshot.unreadSessionIDs,
            openedSessionID: openedSessionID,
            metrics: metrics,
            moveTargetGroups: snapshot.dockLayout.groups.filter { $0.id != group.id },
            screenContextTargetSessionID: snapshot.screenContextTargetSessionID,
            screenContextTargetSticky: snapshot.screenContextTargetSticky
        )
    }

    private func makeDockGroupListChildPanel() -> PickyHUDDockGroupListPanel {
        let panel = PickyHUDDockGroupListPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: 19)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func makeDockGroupListChildHostingView(
        displayID: CGDirectDisplayID,
        model: PickyHUDDockGroupListPanelModel,
        entry: DockGroupListChildEntry
    ) -> NSView {
        let root = PickyAppFontScaleRoot(store: self.fontScaleStore) { [self] in
            PickyHUDDockGroupListPanelRoot(
                model: model,
                displayID: displayID,
                focusStore: dockGroupListFocusStore,
                onSelectSession: { [weak self] sessionID in
                    self?.selectDockGroupListRow(displayID: displayID, sessionID: sessionID)
                },
                onCreatePickle: { [weak self] in
                    self?.requestDockGroupListPickleCreation(
                        displayID: displayID,
                        groupID: model.content.group.id
                    )
                },
                onToggleScreenContextTarget: { [weak self] sessionID in
                    self?.viewModel.toggleScreenContextTarget(sessionID: sessionID)
                },
                onToggleStickyScreenContextTarget: { [weak self] sessionID in
                    self?.viewModel.toggleStickyScreenContextTarget(sessionID: sessionID)
                },
                onCompactSession: { [weak self] sessionID in
                    Task { await self?.viewModel.requestCompaction(sessionID: sessionID) }
                },
                onArchiveSession: { [weak self] sessionID in
                    self?.archiveDockGroupListSession(displayID: displayID, sessionID: sessionID)
                },
                onStopSession: { [weak self] sessionID in
                    Task { try? await self?.viewModel.abortRestoringQueuedInputs(sessionID: sessionID) }
                },
                onMoveSessionToGroup: { [weak self] sessionID, groupID in
                    guard let self,
                          let target = self.viewModel.dockState.snapshot.dockLayout.group(withID: groupID)
                    else { return }
                    self.viewModel.moveSessionInDock(
                        sessionID: sessionID,
                        to: .group(id: groupID, memberIndex: target.memberSessionIDs.count)
                    )
                },
                onUngroupSession: { [weak self] sessionID in
                    self?.ungroupDockGroupListSession(sessionID: sessionID)
                },
                onReorderSession: { [weak self] sessionID, visibleIndex in
                    self?.reorderDockGroupListSession(
                        groupID: model.content.group.id,
                        sessionID: sessionID,
                        visibleIndex: visibleIndex
                    )
                },
                onBeginGroupNameEditing: { [weak self, weak panel = entry.panel] in
                    self?.beginDockGroupListNameEditing(displayID: displayID, childPanel: panel)
                },
                onEndGroupNameEditing: { [weak self, weak panel = entry.panel] in
                    self?.restoreHUDKeyAfterDockGroupListNameEditing(displayID: displayID, childPanel: panel)
                },
                onRenameGroup: { [weak self] groupID, name in
                    self?.viewModel.renameDockGroup(id: groupID, to: name)
                },
                onSetGroupColor: { [weak self] groupID, color in
                    self?.viewModel.setDockGroupColor(id: groupID, color: color)
                },
                convertScreenPointToPanel: { [weak panel = entry.panel] screenPoint in
                    guard let panel else { return .zero }
                    return PickyHUDDockGroupListScreenLayout.panelLocalPoint(
                        screenPoint: screenPoint,
                        panelFrame: panel.frame
                    )
                },
                panelScreenFrame: { [weak panel = entry.panel] in panel?.frame ?? .zero },
                onPromoteRowDrag: { [weak self, weak panel = entry.panel] request in
                    self?.promoteDockGroupListRowDrag(
                        displayID: displayID,
                        request: request,
                        sourcePanel: panel
                    ) ?? false
                },
                onFinishPromotedRowDrag: { [weak self] token in
                    self?.finishExternalDockDragFromPhysicalMouseUp(displayID: displayID, token: token) ?? false
                },
                externalDragPresentationStore: self.externalDockDragPresentationStore(for: displayID)
            )
            .environmentObject(self.appearanceStore)
            .modifier(PickyPreferredColorSchemeModifier(store: self.appearanceStore))
        }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { root })
        let panelSize = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: max(1, model.content.rows.count),
            metrics: model.content.metrics,
            fontScale: fontScaleStore.cgValue
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        return hostingView
    }

    private func beginDockGroupListNameEditing(
        displayID: CGDirectDisplayID,
        childPanel: PickyHUDDockGroupListPanel?
    ) {
        guard let panel = childPanel,
              dockGroupListChildrenByDisplayID[displayID]?.panel === panel,
              panel.isVisible
        else { return }
        // The nonactivating panel becomes key only for this native text input;
        // delayed SwiftUI focus follows after this synchronous handoff.
        panel.makeKey()
    }

    private func restoreHUDKeyAfterDockGroupListNameEditing(
        displayID: CGDirectDisplayID,
        childPanel: PickyHUDDockGroupListPanel?
    ) {
        // Let TextField submit/blur finish its native control action before the
        // parent resumes its local keyboard monitor. A different key window
        // (including another app) is always user intent and remains untouched.
        DispatchQueue.main.async { [weak self, weak childPanel] in
            guard let self,
                  let childPanel,
                  let hudPanel = self.panelsByDisplayID[displayID]?.panel,
                  PickyHUDDockGroupListPanelKeyPolicy.shouldRestoreOwningHUDKey(
                      isEditing: false,
                      isChildPanelKeyWindow: NSApp.keyWindow === childPanel
                  )
            else { return }
            hudPanel.makeKey()
        }
    }

    private func positionDockGroupListChild(
        displayID: CGDirectDisplayID,
        screen: NSScreen,
        hudPanelFrame: CGRect,
        folderFrame: CGRect,
        snapshot: PickyHUDDockSnapshot? = nil,
        fontScale: CGFloat? = nil
    ) {
        let snapshot = snapshot ?? viewModel.dockState.snapshot
        let fontScale = fontScale ?? fontScaleStore.cgValue
        guard let entry = dockGroupListChildrenByDisplayID[displayID],
              let groupID = entry.openGroupID,
              let group = PickyHUDDockGroupListSnapshotPolicy.group(groupID: groupID, in: snapshot)
        else { return }
        let memberCount = max(1, group.memberSessionIDs.filter { sessionID in
            snapshot.activeSessions.contains(where: { $0.id == sessionID })
        }.count)
        let metrics = PickyHUDDockMetrics(preset: currentDockSizePreset)
        let panelSize = PickyHUDDockGroupListPolicy.panelSize(
            memberCount: memberCount,
            metrics: metrics,
            fontScale: fontScale
        )
        let side = position(for: displayID).side
        let anchoredOrigin = PickyHUDDockGroupListPolicy.anchoredOrigin(
            folderFrame: folderFrame,
            railFrame: entry.railFrame,
            panelSize: panelSize,
            dockSide: side,
            panelGap: PickyHUDDockLayout.panelGap
        )
        let origin = PickyHUDDockGroupListPolicy.clampedOrigin(
            anchoredOrigin,
            panelSize: panelSize,
            bounds: PickyHUDDockGroupListScreenLayout.hudRootBounds(
                visibleFrame: screen.visibleFrame,
                hudPanelFrame: hudPanelFrame
            ),
            dockSide: side,
            margin: PickyHUDDockLayout.screenMargin
        )
        let frame = PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudPanelFrame,
            swiftUIOrigin: origin,
            panelSize: panelSize
        )
        if entry.panel.frame.integral != frame.integral {
            entry.panel.setFrame(frame, display: true)
        }
    }

    func selectDockGroupListRow(displayID: CGDirectDisplayID, sessionID: String) {
        let result = PickyHUDDockGroupListInteractionPolicy.selectionResult(
            sessionID: sessionID,
            openGroupID: dockGroupListChildrenByDisplayID[displayID]?.openGroupID
        )
        viewModel.requestOpenSession(sessionID: result.openedSessionID, targetDisplayID: displayID)
        hideDockGroupListChild(displayID: displayID)
    }

    private func archiveDockGroupListSession(displayID: CGDirectDisplayID, sessionID: String) {
        let snapshot = viewModel.dockState.snapshot
        let title = snapshot.activeSessions.first(where: { $0.id == sessionID })?.title
            ?? viewModel.sessionCard(sessionID: sessionID)?.title
            ?? L10n.t("group.list.fallbackTitle")
        viewModel.archive(sessionID: sessionID)
        showArchiveUndoToast(displayID: displayID, sessionID: sessionID, title: title)
    }

    /// A drop position among the rendered rows is not a stored member index:
    /// archived members stay in `memberSessionIDs` without rendering, so the
    /// visible index has to be translated before the move is emitted.
    private func reorderDockGroupListSession(groupID: String, sessionID: String, visibleIndex: Int) {
        let snapshot = viewModel.dockState.snapshot
        guard let group = snapshot.dockLayout.group(withID: groupID) else { return }
        let memberIndex = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: visibleIndex,
            memberSessionIDs: group.memberSessionIDs,
            activeSessionIDs: Set(snapshot.activeSessions.map(\.id))
        )
        viewModel.moveSessionInDock(
            sessionID: sessionID,
            to: .group(id: groupID, memberIndex: memberIndex)
        )
    }

    private func ungroupDockGroupListSession(sessionID: String) {
        let layout = viewModel.dockState.snapshot.dockLayout
        guard let source = layout.container(forSessionID: sessionID),
              case .group(let groupID, _) = source,
              let groupIndex = layout.entries.firstIndex(where: { entry in
                  if case .group(let group) = entry { return group.id == groupID }
                  return false
              })
        else { return }
        viewModel.moveSessionInDock(sessionID: sessionID, to: .topLevel(index: groupIndex + 1))
    }

    private func requestDockGroupListPickleCreation(displayID: CGDirectDisplayID, groupID: String) {
        guard let entry = panelsByDisplayID[displayID] else { return }
        hideDockGroupListChild(displayID: displayID)
        entry.placement.dockGroupListCreateRequestGroupID = groupID
    }

    private func installDockGroupListMouseMonitors(displayID: CGDirectDisplayID) {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard var entry = dockGroupListChildrenByDisplayID[displayID], entry.localMouseDownMonitor == nil else { return }
        entry.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.dismissDockGroupListForOutsideMouseDown(displayID: displayID, event: event) }
            return event
        }
        entry.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.dismissDockGroupListForOutsideMouseDown(displayID: displayID, event: event) }
        }
        dockGroupListChildrenByDisplayID[displayID] = entry
    }

    private func dismissDockGroupListForOutsideMouseDown(displayID: CGDirectDisplayID, event: NSEvent) {
        guard let entry = dockGroupListChildrenByDisplayID[displayID], entry.openGroupID != nil else { return }
        let screenPoint: CGPoint
        if let window = event.window {
            screenPoint = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        let owningInteractionFrame = panelsByDisplayID[displayID].flatMap { hudEntry in
            PickyHUDDockGroupListOutsideDismissFramePolicy.owningInteractionScreenFrame(
                openGroupID: entry.openGroupID,
                interactionFrames: entry.interactionFrames,
                hudPanelFrame: hudEntry.panel.frame
            )
        }
        guard PickyHUDDockGroupListPolicy.shouldDismissForMouseDown(
            at: screenPoint,
            panelFrame: entry.panel.frame,
            owningInteractionFrame: owningInteractionFrame
        ) else { return }
        hideDockGroupListChild(displayID: displayID)
    }

    /// Closes the child list only. A promoted drag owns its own event monitors,
    /// frozen screen geometry, and preview panel precisely so it can outlive the
    /// panel it started from, so this must not end one. Use
    /// `tearDownDockSurface` when the rail the drag drops onto is going away.
    func hideDockGroupListChild(displayID: CGDirectDisplayID) {
        dockGroupListFocusStore.close(displayID: displayID)
        guard let entry = dockGroupListChildrenByDisplayID.removeValue(forKey: displayID) else { return }
        if let localMouseDownMonitor = entry.localMouseDownMonitor { NSEvent.removeMonitor(localMouseDownMonitor) }
        if let globalMouseDownMonitor = entry.globalMouseDownMonitor { NSEvent.removeMonitor(globalMouseDownMonitor) }
        entry.panel.orderOut(nil)
        dockGroupListOverlayLifecycle?.tearDown(displayID: displayID)
    }

    /// The display's HUD surface itself is disappearing or being remeasured, so
    /// the frozen rail geometry a promoted drag resolves against is no longer
    /// reachable. The child is hidden before the terminal policy samples source
    /// usability, so this fades rather than returning to stale geometry.
    func tearDownDockSurface(displayID: CGDirectDisplayID) {
        hideDockGroupListChild(displayID: displayID)
        _ = externalDockDragsByDisplayID[displayID]?.coordinator?.cancelForTeardown()
    }

    func syncDockGroupListChildrenWithSnapshot(
        snapshot: PickyHUDDockSnapshot? = nil,
        fontScale: CGFloat? = nil
    ) {
        let snapshot = snapshot ?? viewModel.dockState.snapshot
        let fontScale = fontScale ?? fontScaleStore.cgValue
        for displayID in dockGroupListChildrenByDisplayID.keys {
            syncDockGroupListChild(displayID: displayID, snapshot: snapshot, fontScale: fontScale)
        }
    }

    func externalDockDragPresentationStore(
        for displayID: CGDirectDisplayID
    ) -> PickyHUDDockExternalDragRailPresentationStore {
        if let entry = externalDockDragsByDisplayID[displayID] { return entry.presentationStore }
        let store = PickyHUDDockExternalDragRailPresentationStore()
        externalDockDragsByDisplayID[displayID] = .init(presentationStore: store, coordinator: nil)
        return store
    }

    func cancelExternalDockDragForEscape(displayID: CGDirectDisplayID) -> Bool {
        externalDockDragsByDisplayID[displayID]?.coordinator?.cancelForEscape() ?? false
    }

    func finishExternalDockDragFromPhysicalMouseUp(displayID: CGDirectDisplayID, token: UUID) -> Bool {
        guard externalDockDragsByDisplayID[displayID]?.presentationStore.presentation?.token == token else { return false }
        return externalDockDragsByDisplayID[displayID]?.coordinator?.finishFromPhysicalMouseUp() ?? false
    }

    func cancelStaleExternalDockDrags(
        snapshot: PickyHUDDockSnapshot,
        fontScale: CGFloat
    ) {
        for (displayID, entry) in externalDockDragsByDisplayID {
            guard let geometry = externalDockGeometryByDisplayID[displayID]?.input else {
                _ = entry.coordinator?.cancelForTeardown()
                continue
            }
            let emittedFingerprint = PickyHUDDockLayoutFingerprint(
                layout: snapshot.dockLayout,
                activeSessionIDs: Set(snapshot.activeSessions.map(\.id)),
                dockSide: position(for: displayID).side,
                geometryRevision: geometry.geometryRevision,
                fontScale: fontScale,
                dockSizePreset: currentDockSizePreset
            )
            _ = entry.coordinator?.cancelIfFingerprintIsStale(emittedFingerprint)
        }
    }

    func promoteDockGroupListRowDrag(
        displayID: CGDirectDisplayID,
        request: PickyHUDDockGroupListPromotionRequest,
        sourcePanel: PickyHUDDockGroupListPanel?
    ) -> Bool {
        let snapshot = viewModel.dockState.snapshot
        guard let child = dockGroupListChildrenByDisplayID[displayID],
              child.panel === sourcePanel,
              child.panel.isVisible,
              child.openGroupID == request.sourceGroupID,
              child.model?.liveMembership.rowIDs == request.referenceRowIDs,
              request.referenceRowIDs.contains(request.session.id),
              let geometryEntry = externalDockGeometryByDisplayID[displayID],
              let geometry = externalDockGeometrySnapshot(displayID: displayID, draggedSessionID: request.session.id),
              geometryEntry.input.layout == snapshot.dockLayout,
              geometryEntry.input.activeSessionIDs == Set(snapshot.activeSessions.map(\.id)),
              geometryEntry.input.dockSide == position(for: displayID).side,
              geometry.layoutFingerprint == PickyHUDDockLayoutFingerprint(
                  layout: snapshot.dockLayout,
                  activeSessionIDs: Set(snapshot.activeSessions.map(\.id)),
                  dockSide: position(for: displayID).side,
                  geometryRevision: geometryEntry.input.geometryRevision,
                  fontScale: fontScaleStore.cgValue,
                  dockSizePreset: currentDockSizePreset
              ),
              snapshot.dockLayout.group(withID: request.sourceGroupID)?.memberSessionIDs.contains(request.session.id) == true,
              PickyHUDDockExternalDragPreviewPresentationPolicy.sourceFrameIsUsable(
                  request.sourceRowScreenFrame
              )
        else { return false }

        let fingerprint = geometry.layoutFingerprint
        let store = externalDockDragPresentationStore(for: displayID)
        let coordinator: PickyHUDDockExternalDragCoordinator
        if let existing = externalDockDragsByDisplayID[displayID]?.coordinator {
            coordinator = existing
        } else {
            let preview = PickyHUDDockExternalDragPreviewDriver(
                presentationStore: store,
                sourceIsUsable: { [weak self] presentation in
                    self?.isExternalDragSourceUsable(
                        displayID: displayID,
                        sessionID: presentation.session.id,
                        sourceGroupID: presentation.sourceGroupID
                    ) ?? false
                }
            )
            coordinator = PickyHUDDockExternalDragCoordinator(
                currentFingerprint: { [weak self] in
                    guard let self else { return fingerprint }
                    let live = self.viewModel.dockState.snapshot
                    let geometryRevision = self.externalDockGeometryByDisplayID[displayID]?.input.geometryRevision
                        ?? (fingerprint.geometryRevision &+ 1)
                    return PickyHUDDockLayoutFingerprint(
                        layout: live.dockLayout,
                        activeSessionIDs: Set(live.activeSessions.map(\.id)),
                        dockSide: self.position(for: displayID).side,
                        geometryRevision: geometryRevision,
                        fontScale: self.fontScaleStore.cgValue,
                        dockSizePreset: self.currentDockSizePreset
                    )
                },
                preview: preview,
                commit: { [weak self] sessionID, destination in
                    self?.viewModel.moveSessionInDock(sessionID: sessionID, to: destination)
                }
            )
            externalDockDragsByDisplayID[displayID] = .init(
                presentationStore: store,
                coordinator: coordinator
            )
        }
        let promotion = PickyHUDDockExternalDragPromotion(
            token: request.token,
            sessionID: request.session.id,
            sourceGroupID: request.sourceGroupID,
            previewPresentation: .init(
                token: request.token,
                sourceGroupID: request.sourceGroupID,
                session: request.session,
                sourceFrame: request.sourceRowScreenFrame,
                pointerScreenPoint: request.pointerScreenPoint,
                dockSide: fingerprint.dockSide,
                metrics: PickyHUDDockMetrics(preset: currentDockSizePreset)
            ),
            frozenLayout: snapshot.dockLayout,
            fingerprint: fingerprint,
            geometry: geometry
        )
        return coordinator.start(promotion)
    }

    private func isExternalDragSourceUsable(
        displayID: CGDirectDisplayID,
        sessionID: String,
        sourceGroupID: String
    ) -> Bool {
        guard let child = dockGroupListChildrenByDisplayID[displayID],
              child.panel.isVisible,
              child.openGroupID == sourceGroupID,
              child.model?.liveMembership.rowIDs.contains(sessionID) == true,
              viewModel.dockState.snapshot.dockLayout.group(withID: sourceGroupID)?.memberSessionIDs.contains(sessionID) == true
        else { return false }
        return true
    }

}

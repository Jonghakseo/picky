//
//  PickyHubQuickStartPage.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubQuickStartPage: View {
    let dependencies: PickyHubDependencies
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @ObservedObject private var launcher: PickyHubQuickStartLauncher
    @State private var folderPanel: NSOpenPanel?

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _launcher = ObservedObject(wrappedValue: dependencies.quickStartLauncher)
    }

    var body: some View {
        PickyHubPageScroll {
            PickyHubPageHeader(title: PickyHubPage.quickStart.titleKey, subtitle: "hub.page.quickStart.subtitle")

            switch launcher.phase {
            case .started(let workflowID, let sessionID):
                if let workflow = PickyHubQuickStartWorkflow.workflow(id: workflowID) {
                    PickyHubQuickStartSuccessView(
                        workflow: workflow,
                        sessionID: sessionID,
                        onOpen: { launcher.openSessionInHUD(sessionID: sessionID) },
                        onAcknowledge: { launcher.acknowledge() }
                    )
                }
            case .idle, .starting, .failed:
                selectionContent
            }
        }
    }

    @ViewBuilder
    private var selectionContent: some View {
        if let record = launcher.resumableRecord,
           let workflow = PickyHubQuickStartWorkflow.workflow(id: record.workflowID) {
            PickyHubQuickStartResumeCard(workflow: workflow, record: record, action: launcher.resume)
                .padding(.bottom, 30)
        }

        PickyHubSubsectionTitle(title: "hub.quickStart.chooseWorkflow")
        LazyVGrid(columns: columns, spacing: PickyHubTheme.Layout.quickGap) {
            ForEach(PickyHubQuickStartWorkflow.all) { workflow in
                PickyHubQuickStartWorkflowCard(
                    workflow: workflow,
                    isBusy: isStarting(workflow),
                    isEnabled: !launcher.phase.isBusy,
                    onStart: { start(workflow, cwd: nil) },
                    onChooseFolder: { chooseFolder(for: workflow) }
                )
            }
        }

        if case .starting(let workflowID) = launcher.phase,
           let workflow = PickyHubQuickStartWorkflow.workflow(id: workflowID) {
            PickyHubInlineStatus(
                tone: .neutral,
                message: L10n.t("hub.quickStart.starting", workflow.title)
            )
            .padding(.top, 12)
        }

        if case .failed(_, let message) = launcher.phase {
            PickyHubInlineStatus(
                tone: .error,
                message: message,
                actionTitle: launcher.retryWillOpenExistingSession ? "hub.quickStart.recover" : "hub.quickStart.retry",
                action: { retry() }
            )
            .padding(.top, 12)
        }

        Text("hub.quickStart.footer")
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 28)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: PickyHubTheme.Layout.cardMinWidth), spacing: PickyHubTheme.Layout.quickGap),
            count: PickyHubGridPolicy.columnCount(for: contentWidth, maximum: 2, minimumCardWidth: PickyHubTheme.Layout.cardMinWidth, spacing: PickyHubTheme.Layout.quickGap)
        )
    }

    private func isStarting(_ workflow: PickyHubQuickStartWorkflow) -> Bool {
        if case .starting(let workflowID) = launcher.phase {
            return workflow.id == workflowID
        }
        return false
    }

    private func start(_ workflow: PickyHubQuickStartWorkflow, cwd: String?) {
        Task { @MainActor in
            await launcher.start(workflow, cwd: cwd)
        }
    }

    private func retry() {
        Task { @MainActor in
            await launcher.retry()
        }
    }

    private func chooseFolder(for workflow: PickyHubQuickStartWorkflow) {
        guard !launcher.phase.isBusy, folderPanel == nil else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.t("hub.quickStart.folderPanel.title")
        panel.message = L10n.t("hub.quickStart.folderPanel.message")
        panel.prompt = L10n.t("hub.quickStart.folderPanel.prompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        folderPanel = panel

        panel.begin { response in
            let url = panel.url
            Task { @MainActor in
                self.folderPanel = nil
                guard response == .OK, let url else { return }
                self.start(workflow, cwd: url.path)
            }
        }
    }
}

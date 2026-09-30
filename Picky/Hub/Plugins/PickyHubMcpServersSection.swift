//
//  PickyHubMcpServersSection.swift
//  Picky
//
//  MCP servers on the Hub Plugins page. Servers come from Pi's global
//  `mcp.json`; each one can serve the main Picky agent and every Pickle, or
//  main Picky only.
//

import AppKit
import SwiftUI

struct PickyHubMcpServersSection: View {
    @ObservedObject var model: PickyHubMcpServersViewModel
    @EnvironmentObject private var modalHost: PickyHubModalHost

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            intro

            ForEach(model.configErrors, id: \.self) { error in
                PickyHubInlineStatus(tone: .error, message: L10n.t("hub.mcp.configError", error))
            }

            if let loadError = model.loadError {
                PickyHubInlineStatus(tone: .error, message: L10n.t("hub.mcp.loadError", loadError), actionTitle: "hub.plugins.feedback.retry") {
                    Task { await model.refresh() }
                }
            }

            if model.isLoading, !model.hasLoaded {
                PickyHubLoadingRow(message: "hub.mcp.loading")
            } else if model.hasLoaded, model.servers.isEmpty, model.loadError == nil {
                PickyHubEmptyState(
                    systemImage: "server.rack",
                    title: "hub.mcp.empty.title",
                    message: "hub.mcp.empty.message",
                    actionTitle: "hub.mcp.add",
                    actionSystemImage: "plus",
                    action: presentAddDialog
                )
            } else {
                ForEach(model.servers) { server in
                    PickyHubMcpServerRow(
                        server: server,
                        isBusy: model.busyNames.contains(server.name),
                        isSigningIn: model.signingInName == server.name,
                        onScope: { scope in Task { await model.setScope(scope, for: server) } },
                        onEnabled: { enabled in Task { await model.setEnabled(enabled, for: server) } },
                        onSignIn: { Task { await model.signIn(server) } },
                        onSignOut: { Task { await model.signOut(server) } },
                        onShowTools: { presentTools(for: server) },
                        onRemove: { presentRemovalConfirmation(for: server) }
                    )
                }
            }

            if let feedback = model.feedback {
                PickyHubInlineStatus(tone: feedback.isError ? .error : .success, message: feedback.message)
            }
        }
        .task {
            if !model.hasLoaded { await model.refresh() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text("hub.mcp.intro")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
            if let path = model.configPath {
                Text(path)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular, design: .monospaced)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .pickyHubSelectableText()
            }
            HStack(spacing: PickyHubTheme.Spacing.related) {
                PickyHubButton(title: "hub.mcp.add", role: .primary, systemImage: "plus", action: presentAddDialog)
                PickyHubButton(title: "hub.stats.refresh", role: .secondary, systemImage: "arrow.clockwise", isBusy: model.isLoading) {
                    Task { await model.refresh() }
                }
                if let path = model.configPath, FileManager.default.fileExists(atPath: path) {
                    PickyHubButton(title: "hub.mcp.openConfig", role: .secondary) {
                        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }
            }
            .padding(.top, PickyHubTheme.Spacing.related)
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }

    private func presentAddDialog() {
        modalHost.present(width: 560, accessibilityLabel: L10n.t("hub.mcp.add.title")) {
            PickyHubMcpAddServerDialog(model: model, onClose: { modalHost.dismiss() })
        }
    }

    private func presentTools(for server: PickyMcpServer) {
        modalHost.present(width: 480, accessibilityLabel: L10n.t("hub.mcp.tools.title", server.name)) {
            PickyHubMcpToolsDialog(server: server, onClose: { modalHost.dismiss() })
        }
    }

    private func presentRemovalConfirmation(for server: PickyMcpServer) {
        modalHost.present(width: 390, accessibilityLabel: L10n.t("hub.mcp.remove.confirm.title")) {
            PickyHubConfirmDialog(
                title: L10n.t("hub.mcp.remove.confirm.title"),
                message: L10n.t("hub.mcp.remove.confirm.message", server.name),
                confirmTitle: "hub.plugins.card.remove",
                onCancel: { modalHost.dismiss() },
                onConfirm: {
                    modalHost.dismiss()
                    Task { await model.remove(server) }
                }
            )
        }
    }
}

extension PickyMcpScope {
    var title: String {
        switch self {
        case .all: L10n.t("hub.mcp.scope.all")
        case .main: L10n.t("hub.mcp.scope.main")
        }
    }

    static var menuOptions: [PickyNativeMenuOption<PickyMcpScope>] {
        allCases.map { PickyNativeMenuOption(value: $0, title: $0.title) }
    }
}

private struct PickyHubMcpServerRow: View {
    let server: PickyMcpServer
    let isBusy: Bool
    let isSigningIn: Bool
    let onScope: (PickyMcpScope) -> Void
    let onEnabled: (Bool) -> Void
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onShowTools: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
                Text(server.name)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .pickyHubSelectableText()
                PickyHubMcpStateLabel(state: server.state, toolCount: server.tools.count)
                Spacer(minLength: PickyHubTheme.Spacing.related)
                Toggle("hub.mcp.enabled", isOn: Binding(get: { server.enabled }, set: onEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(PickyHubTheme.Colors.action)
                    .disabled(isBusy)
                    .help(Text("hub.mcp.enabled.help"))
                    .accessibilityLabel(Text(L10n.t("hub.mcp.enabled.accessibility", server.name)))
            }

            Text(server.transport)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular, design: .monospaced)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .pickyHubSelectableText()

            if isSigningIn {
                PickyHubInlineStatus(tone: .neutral, message: L10n.t("hub.mcp.signingIn"))
            } else if server.state == .needsAuth {
                PickyHubInlineStatus(tone: .warning, message: L10n.t("hub.mcp.needsAuth"))
            } else if let error = server.error, server.state != .connected {
                PickyHubInlineStatus(tone: .error, message: error)
                    .lineLimit(4)
            }

            ViewThatFits(in: .horizontal) {
                controls(isVertical: false)
                controls(isVertical: true)
            }
            .padding(.top, PickyHubTheme.Spacing.related)
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(server.name))
    }

    private func controls(isVertical: Bool) -> some View {
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PickyHubTheme.Spacing.related))
            : AnyLayout(HStackLayout(spacing: PickyHubTheme.Spacing.related))
        return layout {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                Text("hub.mcp.scope.label")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                PickyHubMenuPicker(
                    title: L10n.t("hub.mcp.scope.label"),
                    selection: Binding(get: { server.pickyScope }, set: onScope),
                    options: PickyMcpScope.menuOptions
                )
                .fixedSize()
                .disabled(isBusy)
            }
            if !isVertical { Spacer(minLength: 0) }
            if server.usesOAuth, server.state == .needsAuth {
                PickyHubButton(title: "settings.oauth.signIn", role: .primary, isBusy: isSigningIn, isEnabled: !isBusy, action: onSignIn)
            }
            if !server.tools.isEmpty {
                PickyHubButton(title: "hub.mcp.tools.view", role: .secondary, action: onShowTools)
            }
            if server.usesOAuth, server.state == .connected {
                PickyHubButton(title: "hub.mcp.signOut", role: .secondary, isEnabled: !isBusy, action: onSignOut)
            }
            PickyHubButton(title: "hub.plugins.card.remove", role: .danger, isEnabled: !isBusy, action: onRemove)
                .accessibilityLabel(Text(L10n.t("hub.mcp.remove.accessibility", server.name)))
        }
    }
}

/// Connection state with an icon, so the state never relies on color alone.
private struct PickyHubMcpStateLabel: View {
    let state: PickyMcpServer.State
    let toolCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(label)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch state {
        case .connected: L10n.t("hub.mcp.state.connected", Int64(toolCount))
        case .connecting: L10n.t("hub.mcp.state.connecting")
        case .needsAuth: L10n.t("hub.mcp.state.needsAuth")
        case .failed: L10n.t("hub.mcp.state.failed")
        case .disconnected, .closed: L10n.t("hub.mcp.state.disconnected")
        case .disabled: L10n.t("hub.mcp.state.disabled")
        }
    }

    private var icon: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .needsAuth: "person.badge.key"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected, .closed: "bolt.horizontal.circle"
        case .disabled: "pause.circle"
        }
    }

    private var color: Color {
        switch state {
        case .connected: PickyHubTheme.Colors.success
        case .needsAuth: PickyHubTheme.Colors.warning
        case .failed: DS.Colors.destructiveText
        case .connecting, .disconnected, .closed, .disabled: PickyHubTheme.Colors.textTertiary
        }
    }
}

private struct PickyHubMcpAddServerDialog: View {
    @ObservedObject var model: PickyHubMcpServersViewModel
    let onClose: () -> Void
    @State private var name = ""
    @State private var json = ""
    @State private var scope: PickyMcpScope = .all
    @State private var error: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            PickyHubModalHeader(title: L10n.t("hub.mcp.add.title"), onClose: onClose)

            field(title: "hub.mcp.add.name", hint: "hub.mcp.add.name.hint") {
                TextField("", text: $name, prompt: Text(verbatim: "sentry"))
                    .textFieldStyle(.roundedBorder)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular, design: .monospaced)
                    .accessibilityLabel(Text("hub.mcp.add.name"))
            }

            field(title: "hub.mcp.add.config", hint: "hub.mcp.add.config.hint") {
                TextEditor(text: $json)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular, design: .monospaced)
                    .scrollContentBackground(.hidden)
                    .padding(PickyHubTheme.Spacing.related)
                    .frame(minHeight: 150, maxHeight: 240)
                    .pickyHubCard(radius: PickyHubTheme.Radius.control, fill: PickyHubTheme.Colors.canvas)
                    .accessibilityLabel(Text("hub.mcp.add.config"))
            }

            HStack(spacing: PickyHubTheme.Spacing.related) {
                Text("hub.mcp.scope.label")
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                PickyHubMenuPicker(title: L10n.t("hub.mcp.scope.label"), selection: $scope, options: PickyMcpScope.menuOptions)
                    .fixedSize()
            }

            if let error {
                PickyHubInlineStatus(tone: .error, message: error)
            }

            HStack(spacing: PickyHubTheme.Spacing.related) {
                Spacer(minLength: 0)
                PickyHubButton(title: "common.cancel", role: .secondary, isEnabled: !isAdding, action: onClose)
                PickyHubButton(title: "hub.mcp.add.confirm", role: .primary, isBusy: isAdding, action: submit)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
    }

    private func field<Content: View>(title: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            content()
            Text(hint)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        switch PickyMcpServerDraft.parse(name: name, json: json) {
        case .failure(let parseError):
            error = message(for: parseError)
        case .success(let drafts):
            error = nil
            isAdding = true
            Task {
                let failure = await model.add(drafts, scope: scope)
                isAdding = false
                if let failure {
                    error = failure
                } else {
                    onClose()
                }
            }
        }
    }

    private func message(for error: PickyMcpServerDraft.ParseError) -> String {
        switch error {
        case .empty: L10n.t("hub.mcp.add.error.empty")
        case .invalidJSON: L10n.t("hub.mcp.add.error.json")
        case .missingName: L10n.t("hub.mcp.add.error.name")
        case .noServerConfig: L10n.t("hub.mcp.add.error.noServer")
        }
    }
}

private struct PickyHubMcpToolsDialog: View {
    let server: PickyMcpServer
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            PickyHubModalHeader(meta: server.transport, title: L10n.t("hub.mcp.tools.title", server.name), onClose: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                    ForEach(server.tools, id: \.self) { tool in
                        Text(tool)
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular, design: .monospaced)
                            .foregroundColor(PickyHubTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .pickyHubSelectableText()
            }
            .frame(maxHeight: 320)
        }
        .padding(PickyHubTheme.Spacing.cardInset)
    }
}

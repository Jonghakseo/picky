//
//  PickyHubQuickStartViews.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubQuickStartWorkflowCard: View {
    let workflow: PickyHubQuickStartWorkflow
    var isBusy = false
    var isEnabled = true
    let onStart: () -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: workflow.systemImage)
                .pickyFont(size: 18, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.action)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                        .fill(PickyHubTheme.Colors.actionTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous)
                        .stroke(PickyHubTheme.Colors.border, lineWidth: 1)
                )
                .accessibilityHidden(true)

            Text(workflow.titleKey)
                .pickyFont(size: 16, weight: .bold)
                .tracking(-0.4)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .padding(.top, 16)

            Text(workflow.descriptionKey)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack(spacing: 12) {
                PickyHubPillButton(title: "hub.quickStart.start", systemImage: "play.fill", isBusy: isBusy, action: onStart)
                    .disabled(!isEnabled)
                PickyHubTextLink(title: "hub.quickStart.chooseFolder", action: onChooseFolder)
                    .disabled(!isEnabled)
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .leading)
        .padding(18)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }
}

struct PickyHubQuickStartResumeCard: View {
    let workflow: PickyHubQuickStartWorkflow
    let record: PickyHubQuickStartRecord
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("hub.quickStart.resume.kicker")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .bold)
                    .foregroundColor(PickyHubTheme.Colors.action)
                Text(workflow.titleKey)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .bold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                if record.deliveryState != .accepted {
                    Text("hub.quickStart.resume.pending")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.t("hub.quickStart.resume.lastStarted", record.startedAt.formatted(date: .abbreviated, time: .shortened)))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
            }
            Spacer(minLength: 8)
            PickyHubButton(title: "hub.quickStart.resume.action", role: .secondary, action: action)
        }
        .padding(16)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }
}

struct PickyHubQuickStartSuccessView: View {
    let workflow: PickyHubQuickStartWorkflow
    let sessionID: String
    let onOpen: () -> Void
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark")
                .pickyFont(size: 22, weight: .bold)
                .foregroundColor(PickyHubTheme.Colors.success)
                .frame(width: 46, height: 46)
                .background(Circle().fill(PickyHubTheme.Colors.successBackground))
                .accessibilityHidden(true)
            Text("hub.quickStart.success.title")
                .pickyFont(size: 20, weight: .bold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .padding(.top, 15)
            Text("hub.quickStart.success.message")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 7)
            PickyHubButton(title: "hub.quickStart.success.showWorkflows", role: .secondary, action: onAcknowledge)
                .padding(.top, 18)
            PickyHubTextLink(title: "hub.quickStart.success.openPickle", action: onOpen)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .padding(.horizontal, 24)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
        .accessibilityElement(children: .contain)
    }
}

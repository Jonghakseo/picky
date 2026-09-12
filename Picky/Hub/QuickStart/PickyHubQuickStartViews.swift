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
                .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                .tracking(-0.4)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .padding(.top, PickyHubTheme.Spacing.field)

            Text(workflow.descriptionKey)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
                .padding(.top, PickyHubTheme.Spacing.related)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    startButton
                    chooseFolderButton
                }
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                    startButton
                    chooseFolderButton
                }
            }
            .padding(.top, PickyHubTheme.Spacing.field)
        }
        .frame(maxWidth: .infinity, minHeight: 208, alignment: .leading)
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private var startButton: some View {
        PickyHubPillButton(title: "hub.quickStart.start", systemImage: "play.fill", isBusy: isBusy, action: onStart)
            .disabled(!isEnabled)
    }

    private var chooseFolderButton: some View {
        PickyHubTextLink(title: "hub.quickStart.chooseFolder", action: onChooseFolder)
            .disabled(!isEnabled)
    }
}

struct PickyHubQuickStartResumeCard: View {
    let workflow: PickyHubQuickStartWorkflow
    let record: PickyHubQuickStartRecord
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
                details
                Spacer(minLength: PickyHubTheme.Spacing.related)
                resumeButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                details
                resumeButton
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text("hub.quickStart.resume.kicker")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.action)
            Text(workflow.titleKey)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            if record.deliveryState != .accepted {
                Text("hub.quickStart.resume.pending")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
            }
            Text(L10n.t("hub.quickStart.resume.lastStarted", record.startedAt.formatted(date: .abbreviated, time: .shortened)))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .pickyHubSelectableText()
        }
    }

    private var resumeButton: some View {
        PickyHubButton(title: "hub.quickStart.resume.action", role: .secondary, action: action)
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
                .pickyFont(size: 22, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.success)
                .frame(width: 46, height: 46)
                .background(Circle().fill(PickyHubTheme.Colors.successBackground))
                .accessibilityHidden(true)
            Text("hub.quickStart.success.title")
                .pickyFont(size: 20, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .padding(.top, PickyHubTheme.Spacing.field)
            Text("hub.quickStart.success.message")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .pickyHubSelectableText()
                .padding(.top, PickyHubTheme.Spacing.related)
            PickyHubButton(title: "hub.quickStart.success.showWorkflows", role: .secondary, action: onAcknowledge)
                .padding(.top, PickyHubTheme.Spacing.field)
            PickyHubTextLink(title: "hub.quickStart.success.openPickle", action: onOpen)
                .padding(.top, PickyHubTheme.Spacing.related)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PickyHubTheme.Layout.sectionSpacing)
        .padding(.horizontal, PickyHubTheme.Spacing.group)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
        .accessibilityElement(children: .contain)
    }
}

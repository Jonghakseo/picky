//
//  CompanionPanelPrerequisitesView.swift
//  Picky
//
//  Prerequisites copy and rows for the companion panel. Bundles the macOS
//  permission gates into a single "setup" surface that hides the rest of the
//  panel until everything is in place.
//

import AVFoundation
import SwiftUI

struct CompanionPanelPrerequisitesCopyView: View {
    @ObservedObject var companionManager: CompanionManager

    /// The copy view is only embedded by the Status tab when prerequisites are
    /// still missing, so the body always renders the "setup needed" wording.
    /// Kept as its own view (rather than inlined) so the Status tab and any
    /// future entry point can share the same blurb without copy duplication.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("prereq.copy.runsLocally")
                .pickyFont(size: 12, weight: .bold)
                .foregroundColor(DS.Colors.textSecondary)

            Text("prereq.copy.contextHandoff")
                .pickyFont(size: 11)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("prereq.copy.noAccount")
                .pickyFont(size: 11)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompanionPanelPrerequisitesView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 2) {
            Text("prereq.heading")
                .pickyFont(size: 10, weight: .semibold, design: .rounded)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .pickyFont(size: 12, weight: .medium)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warningText)
                    .frame(width: 16)

                Text("prereq.accessibility.title")
                    .pickyFont(size: 13, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("common.granted")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.successText)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("common.grant")
                            .pickyFont(size: 11, weight: .semibold)
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("common.findApp")
                            .pickyFont(size: 11, weight: .semibold)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .pickyFont(size: 12, weight: .medium)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warningText)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("prereq.screenRecording.title")
                        .pickyFont(size: 13, weight: .medium)
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted ? "prereq.screenRecording.detail.granted" : "prereq.screenRecording.detail.missing")
                        .pickyFont(size: 10)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("common.granted")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.successText)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("common.grant")
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .pickyFont(size: 12, weight: .medium)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warningText)
                    .frame(width: 16)

                Text("prereq.screenContent.title")
                    .pickyFont(size: 13, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("common.granted")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.successText)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("common.grant")
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .pickyFont(size: 12, weight: .medium)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warningText)
                    .frame(width: 16)

                Text("prereq.microphone.title")
                    .pickyFont(size: 13, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("common.granted")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.successText)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("common.grant")
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .pickyFont(size: 12, weight: .medium)
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warningText)
                    .frame(width: 16)

                Text(label)
                    .pickyFont(size: 13, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("common.granted")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.successText)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("common.grant")
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }




}

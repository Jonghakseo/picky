//
//  PickyHubForegroundContextPreserver.swift
//  Picky
//
//  Preserves the external app that the Hub temporarily covered so PTT context
//  capture can read that app after the Hub yields focus.
//

import AppKit
import Foundation

struct PickyForegroundApplication: Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t

    init(bundleIdentifier: String?, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    init(_ application: NSRunningApplication) {
        self.bundleIdentifier = application.bundleIdentifier
        self.processIdentifier = application.processIdentifier
    }
}

@MainActor
final class PickyHubForegroundContextPreserver {
    typealias FrontmostApplicationProvider = @MainActor () -> PickyForegroundApplication?
    typealias HubDismissal = @MainActor () -> Void
    typealias ApplicationActivator = @MainActor (PickyForegroundApplication) async -> Bool

    private let pickyBundleIdentifier: String?
    private let frontmostApplicationProvider: FrontmostApplicationProvider
    private let applicationActivator: ApplicationActivator
    private var externalApplicationBeforeHub: PickyForegroundApplication?

    init(
        pickyBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        frontmostApplicationProvider: @escaping FrontmostApplicationProvider = {
            NSWorkspace.shared.frontmostApplication.map(PickyForegroundApplication.init)
        },
        applicationActivator: @escaping ApplicationActivator = PickyHubForegroundContextPreserver.activateAndAwait
    ) {
        self.pickyBundleIdentifier = pickyBundleIdentifier
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.applicationActivator = applicationActivator
    }

    /// Re-focusing an open Hub must preserve the latest observed external app.
    func recordExternalForegroundBeforeHubActivation(hubIsVisible: Bool = false) {
        guard let frontmost = frontmostApplicationProvider(), !isPicky(frontmost) else {
            if !hubIsVisible { externalApplicationBeforeHub = nil }
            return
        }
        recordExternalActivation(frontmost)
    }

    /// Called by Workspace observations while Hub is open, including when the
    /// user switches back by clicking the window rather than calling `show()`.
    func recordExternalActivation(_ application: PickyForegroundApplication) {
        guard !isPicky(application) else { return }
        externalApplicationBeforeHub = application
    }

    /// Yields a still-visible Hub only when it is currently covering the app it
    /// recorded. If another external app is already frontmost, preserve that
    /// newer user choice and discard the old target so it cannot be revived by
    /// a later PTT invocation.
    func restoreExternalForegroundForContextCapture(
        hubIsVisible: Bool,
        dismissHub: HubDismissal
    ) async {
        guard hubIsVisible,
              let externalApplicationBeforeHub else {
            return
        }
        guard let frontmost = frontmostApplicationProvider(), isPicky(frontmost) else {
            self.externalApplicationBeforeHub = nil
            return
        }

        dismissHub()
        guard await applicationActivator(externalApplicationBeforeHub) else {
            self.externalApplicationBeforeHub = nil
            return
        }
        self.externalApplicationBeforeHub = nil
    }

    func clearRememberedExternalForeground() {
        externalApplicationBeforeHub = nil
    }

    private func isPicky(_ application: PickyForegroundApplication) -> Bool {
        application.bundleIdentifier == pickyBundleIdentifier
    }

    private static func activateAndAwait(_ target: PickyForegroundApplication) async -> Bool {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }
        guard application.activate(options: []) else {
            return false
        }

        // `activate` returning true only means the request was accepted. Wait
        // for the Workspace activation notification, or accept an already
        // updated frontmost value, before AX/browser/selection capture runs.
        if PickyForegroundApplication(NSWorkspace.shared.frontmostApplication) == target {
            return true
        }

        return await withCheckedContinuation { continuation in
            let notificationCenter = NSWorkspace.shared.notificationCenter
            var observer: NSObjectProtocol?
            var settled = false
            func finish(_ didActivate: Bool) {
                guard !settled else { return }
                settled = true
                if let observer {
                    notificationCenter.removeObserver(observer)
                }
                continuation.resume(returning: didActivate)
            }

            observer = notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                guard let activatedApplication,
                      PickyForegroundApplication(activatedApplication) == target else {
                    return
                }
                finish(true)
            }

            if PickyForegroundApplication(NSWorkspace.shared.frontmostApplication) == target {
                finish(true)
                return
            }

            // An activation request can be denied by macOS or by a terminating
            // process. A bounded failure keeps PTT capture moving without using
            // a sleep to infer focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                finish(false)
            }
        }
    }
}

private extension PickyForegroundApplication {
    init?(_ application: NSRunningApplication?) {
        guard let application else { return nil }
        self.init(application)
    }
}

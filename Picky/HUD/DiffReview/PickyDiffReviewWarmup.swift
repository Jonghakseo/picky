//
//  PickyDiffReviewWarmup.swift
//  Picky
//
//  Keeps a pre-initialized PickyDiffReviewWebHost ready so that the first
//  diff viewer click can adopt an already-loaded Monaco editor instead of
//  paying ~1–2 s of JS parse + module evaluation cost.
//

import AppKit
import Foundation
import WebKit

@MainActor
final class PickyDiffReviewWarmup {
    static let shared = PickyDiffReviewWarmup()

    private var preparedHost: PickyDiffReviewWebHost?
    private var preparedWindow: NSWindow?
    private var isPreparing = false

    private init() {}

    /// Start (or restart) the background warmup. Safe to call multiple times.
    func prepare() {
        guard preparedHost == nil, !isPreparing else { return }
        isPreparing = true

        let host = PickyDiffReviewWebHost(
            queueIncomingMessages: true,
            onMessage: { _ in /* live handlers swap in via attachLiveHandlers */ },
            onClose: { /* warmup window cannot be closed by the user */ }
        )

        // An off-screen NSWindow keeps the WKWebView in a view hierarchy so its
        // run loop and layout pipeline actually progress. A `.borderless`
        // window with `isExcludedFromWindowsMenu` stays out of Dock / mission
        // control while letting WebKit warm up normally.
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = host.webView
        window.orderBack(nil)

        do {
            try host.loadInitialPage(initialData: nil)
            preparedHost = host
            preparedWindow = window
        } catch {
            // Warmup failure is non-fatal — the presenter falls back to the
            // fresh path that builds a brand-new host on demand.
            window.close()
        }
        isPreparing = false
    }

    /// Hand the prepared host off to the presenter, then kick off another
    /// warmup so the next diff click is fast too. Returns `nil` if no host is
    /// ready yet (cold start or a viewer is already adopted).
    func consume() -> PickyDiffReviewWebHost? {
        guard let host = preparedHost else { return nil }
        preparedHost = nil

        host.webView.removeFromSuperview()
        preparedWindow?.contentView = nil
        preparedWindow?.close()
        preparedWindow = nil

        // Schedule the next warmup off the current event loop tick so the
        // caller can finish attaching this host to the real window first.
        DispatchQueue.main.async { [weak self] in
            self?.prepare()
        }

        return host
    }
}

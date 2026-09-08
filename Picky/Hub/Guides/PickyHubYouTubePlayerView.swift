//
//  PickyHubYouTubePlayerView.swift
//  Picky
//

import AppKit
import SwiftUI
import WebKit

enum PickyHubYouTubeNavigationPolicy {
    static func shouldAllow(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "youtube-nocookie.com" || host == "www.youtube-nocookie.com"
    }
}

enum PickyHubYouTubePlayerLoadState: Equatable {
    case loading
    case loaded
    case failed
}

struct PickyHubYouTubePlayerView: NSViewRepresentable {
    let url: URL?
    var onLoadStateChange: (PickyHubYouTubePlayerLoadState) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadStateChange: onLoadStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadStateChange = onLoadStateChange
        guard context.coordinator.currentURL != url else { return }
        load(url, in: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    private func load(_ url: URL?, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentURL = url
        guard let url, PickyHubYouTubeNavigationPolicy.shouldAllow(url: url) else {
            coordinator.onLoadStateChange(.failed)
            return
        }
        coordinator.onLoadStateChange(.loading)
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentURL: URL?
        var onLoadStateChange: (PickyHubYouTubePlayerLoadState) -> Void

        init(onLoadStateChange: @escaping (PickyHubYouTubePlayerLoadState) -> Void) {
            self.onLoadStateChange = onLoadStateChange
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadStateChange(.loaded)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadStateChange(.failed)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadStateChange(.failed)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard PickyHubYouTubeNavigationPolicy.shouldAllow(url: url) else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

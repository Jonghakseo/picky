//
//  PickyFaviconStore.swift
//  Picky
//
//  Same-origin favicon loading for generic conversation links.
//

import AppKit
import Combine
import Foundation

enum PickyFaviconRequestPolicy {
    static let maximumResponseBytes = 1_048_576

    nonisolated static func faviconURL(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              pageURL.host?.isEmpty == false,
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    nonisolated static func allowsRedirect(from originalURL: URL, to redirectURL: URL) -> Bool {
        origin(of: originalURL) == origin(of: redirectURL)
    }

    nonisolated private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

protocol PickyFaviconTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class PickyFaviconRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let redirectURL = request.url,
              PickyFaviconRequestPolicy.allowsRedirect(from: originalURL, to: redirectURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class PickyURLSessionFaviconTransport: PickyFaviconTransport {
    private let redirectDelegate: PickyFaviconRedirectDelegate
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1_048_576, diskCapacity: 0)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6

        let redirectDelegate = PickyFaviconRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(PickyFaviconRequestPolicy.maximumResponseBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), PickyFaviconRequestPolicy.maximumResponseBytes))
        }
        for try await byte in bytes {
            guard data.count < PickyFaviconRequestPolicy.maximumResponseBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, response)
    }
}

@MainActor
final class PickyFaviconStore: ObservableObject {
    static let shared = PickyFaviconStore()

    @Published private var imagesByURL: [URL: NSImage] = [:]
    private var unavailableURLs: Set<URL> = []
    private var inFlightTasks: [URL: Task<Void, Never>] = [:]
    private let transport: PickyFaviconTransport

    init(transport: PickyFaviconTransport = PickyURLSessionFaviconTransport()) {
        self.transport = transport
    }

    func image(for pageURL: URL) -> NSImage? {
        guard let faviconURL = PickyFaviconRequestPolicy.faviconURL(for: pageURL) else { return nil }
        return imagesByURL[faviconURL]
    }

    func load(pageURLs: [URL]) async {
        let faviconURLs = Array(Set(pageURLs.compactMap(PickyFaviconRequestPolicy.faviconURL(for:))))
        let batchSize = 4
        for startIndex in stride(from: 0, to: faviconURLs.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, faviconURLs.count)
            let tasks = faviconURLs[startIndex..<endIndex].compactMap(task(for:))
            for task in tasks {
                await task.value
            }
        }
    }

    private func task(for faviconURL: URL) -> Task<Void, Never>? {
        if let task = inFlightTasks[faviconURL] {
            return task
        }
        guard imagesByURL[faviconURL] == nil, !unavailableURLs.contains(faviconURL) else {
            return nil
        }

        var request = URLRequest(url: faviconURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 4
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let transport = transport
        let task = Task { [weak self] in
            let image: NSImage?
            do {
                let (data, response) = try await transport.data(for: request)
                guard (200..<300).contains(response.statusCode),
                      !data.isEmpty,
                      data.count <= PickyFaviconRequestPolicy.maximumResponseBytes else {
                    throw URLError(.badServerResponse)
                }
                image = NSImage(data: data)
            } catch {
                image = nil
            }
            self?.finish(faviconURL: faviconURL, image: image)
        }
        inFlightTasks[faviconURL] = task
        return task
    }

    private func finish(faviconURL: URL, image: NSImage?) {
        inFlightTasks[faviconURL] = nil
        if let image {
            imagesByURL[faviconURL] = image
        } else {
            unavailableURLs.insert(faviconURL)
        }
    }
}

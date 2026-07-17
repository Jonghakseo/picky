import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
private final class FakePickyFaviconTransport: PickyFaviconTransport {
    private let responseData: Data
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            responseData,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}

@Suite("Picky favicon store")
@MainActor
struct PickyFaviconStoreTests {
    @Test func faviconURLUsesSameOriginRootWithoutCredentialsOrPageState() throws {
        let pageURL = try #require(URL(string: "https://user:secret@example.com:8443/docs/page?tab=mac#install"))

        let faviconURL = try #require(PickyFaviconRequestPolicy.faviconURL(for: pageURL))

        #expect(faviconURL.absoluteString == "https://example.com:8443/favicon.ico")
    }

    @Test func redirectsStayOnTheOriginalOrigin() throws {
        let faviconURL = try #require(URL(string: "https://example.com/favicon.ico"))
        let sameOrigin = try #require(URL(string: "https://example.com/assets/icon.png"))
        let differentHost = try #require(URL(string: "https://cdn.example.com/icon.png"))
        let differentScheme = try #require(URL(string: "http://example.com/icon.png"))

        #expect(PickyFaviconRequestPolicy.allowsRedirect(from: faviconURL, to: sameOrigin))
        #expect(!PickyFaviconRequestPolicy.allowsRedirect(from: faviconURL, to: differentHost))
        #expect(!PickyFaviconRequestPolicy.allowsRedirect(from: faviconURL, to: differentScheme))
    }

    @Test func storeLoadsEachOriginOnceAndReusesTheDecodedImage() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z8ZcAAAAASUVORK5CYII="))
        let transport = FakePickyFaviconTransport(responseData: png)
        let store = PickyFaviconStore(transport: transport)
        let firstPage = try #require(URL(string: "https://example.com/one"))
        let secondPage = try #require(URL(string: "https://example.com/two?tab=details"))

        await store.load(pageURLs: [firstPage, secondPage])
        await store.load(pageURLs: [firstPage])

        let requestCount = transport.requestCount()
        #expect(requestCount == 1)
        #expect(store.image(for: firstPage) != nil)
        #expect(store.image(for: firstPage) === store.image(for: secondPage))
    }

    @Test func failedImageDataFallsBackWithoutRepeatedRequests() async throws {
        let transport = FakePickyFaviconTransport(responseData: Data("not-an-image".utf8))
        let store = PickyFaviconStore(transport: transport)
        let pageURL = try #require(URL(string: "https://example.com/page"))

        await store.load(pageURLs: [pageURL])
        await store.load(pageURLs: [pageURL])

        let requestCount = transport.requestCount()
        #expect(requestCount == 1)
        #expect(store.image(for: pageURL) == nil)
    }
}

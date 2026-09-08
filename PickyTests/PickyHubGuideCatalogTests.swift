//
//  PickyHubGuideCatalogTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyHubGuideCatalogTests {
    @Test func decodesAndSortsGuidesNewestFirstWithStableIDs() {
        let data = Data(#"""
        [
          {"id":"later","kind":"update","title":{"en":"Later","ko":"나중"},"summary":{"en":"Summary","ko":"설명"},"publishedOn":"2026-08-20","youtubeVideoID":"later-id","thumbnailURL":null},
          {"id":"same-date-b","kind":"guide","title":{"en":"B","ko":"비"},"summary":{"en":"Summary","ko":"설명"},"publishedOn":"2026-08-13","youtubeVideoID":"b-id","thumbnailURL":null},
          {"id":"same-date-a","kind":"guide","title":{"en":"A","ko":"에이"},"summary":{"en":"Summary","ko":"설명"},"publishedOn":"2026-08-13","youtubeVideoID":"a-id","thumbnailURL":null}
        ]
        """#.utf8)

        let entries = PickyHubGuideCatalog.decode(data)

        #expect(entries.map(\.id) == ["later", "same-date-a", "same-date-b"])
        #expect(entries.first?.title.resolved(for: Locale(identifier: "ko_KR")) == "나중")
        #expect(entries.first?.title.resolved(for: Locale(identifier: "en_US")) == "Later")
    }

    @Test func exposesPublishedDateEmbedAndThumbnailURLs() throws {
        let entry = try #require(PickyHubGuideCatalog.decode(Data(#"""
        [{"id":"guide","kind":"guide","title":{"en":"Title","ko":"제목"},"summary":{"en":"Summary","ko":"설명"},"publishedOn":"2026-08-20","youtubeVideoID":"M7lc1UVf-VE","thumbnailURL":null}]
        """#.utf8)).first)

        #expect(entry.publishedDate != nil)
        #expect(entry.embedURL?.absoluteString == "https://www.youtube-nocookie.com/embed/M7lc1UVf-VE?rel=0&autoplay=1&playsinline=1")
        #expect(entry.watchURL?.absoluteString == "https://www.youtube.com/watch?v=M7lc1UVf-VE")
        #expect(entry.resolvedThumbnailURL?.absoluteString == "https://i.ytimg.com/vi/M7lc1UVf-VE/hqdefault.jpg")
    }

    @Test func navigationPolicyKeepsPlaybackInsideNoCookieEmbedOnly() {
        #expect(PickyHubYouTubeNavigationPolicy.shouldAllow(url: URL(string: "https://www.youtube-nocookie.com/embed/demo")!))
        #expect(!PickyHubYouTubeNavigationPolicy.shouldAllow(url: URL(string: "https://www.youtube.com/watch?v=demo")!))
        #expect(!PickyHubYouTubeNavigationPolicy.shouldAllow(url: URL(string: "http://www.youtube-nocookie.com/embed/demo")!))
    }

    @Test func malformedCatalogDataProducesAnEmptyFeed() {
        #expect(PickyHubGuideCatalog.decode(Data("not json".utf8)).isEmpty)
    }
}

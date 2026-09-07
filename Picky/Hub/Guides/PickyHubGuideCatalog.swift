//
//  PickyHubGuideCatalog.swift
//  Picky
//
//  Guides and product updates ship as a fixed JSON file in the app bundle
//  (`hub-guides.json`); refreshing the feed is an app update. Both the
//  dashboard carousel and the Guides page read the same newest-first list.
//

import Foundation

struct PickyHubGuideEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case guide
        case update

        var titleKey: String {
            switch self {
            case .guide: "hub.guides.kind.guide"
            case .update: "hub.guides.kind.update"
            }
        }
    }

    struct LocalizedText: Codable, Equatable {
        let en: String
        let ko: String

        /// Picks the catalog language that matches the app locale.
        func resolved(for locale: Locale) -> String {
            locale.language.languageCode?.identifier == "ko" ? ko : en
        }
    }

    let id: String
    let kind: Kind
    let title: LocalizedText
    let summary: LocalizedText
    /// `yyyy-MM-dd`.
    let publishedOn: String
    let youtubeVideoID: String
    /// Optional override; defaults to the YouTube poster frame.
    let thumbnailURL: String?

    var publishedDate: Date? { PickyHubGuideCatalog.dayFormatter.date(from: publishedOn) }

    var embedURL: URL? {
        URL(string: "https://www.youtube-nocookie.com/embed/\(youtubeVideoID)?rel=0&autoplay=1&playsinline=1")
    }

    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(youtubeVideoID)")
    }

    var resolvedThumbnailURL: URL? {
        if let thumbnailURL, let url = URL(string: thumbnailURL) { return url }
        return URL(string: "https://i.ytimg.com/vi/\(youtubeVideoID)/hqdefault.jpg")
    }
}

enum PickyHubGuideCatalog {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Newest first. Missing or malformed bundle data yields an empty feed so
    /// the pages render their empty state instead of failing.
    static func load(bundle: Bundle = .main) -> [PickyHubGuideEntry] {
        guard let url = bundle.url(forResource: "hub-guides", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> [PickyHubGuideEntry] {
        guard let entries = try? JSONDecoder().decode([PickyHubGuideEntry].self, from: data) else { return [] }
        return entries.sorted { lhs, rhs in
            if lhs.publishedOn != rhs.publishedOn { return lhs.publishedOn > rhs.publishedOn }
            return lhs.id < rhs.id
        }
    }
}

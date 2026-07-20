import Foundation
import Testing
@testable import Picky

@Suite("Picky conversation attachment thumbnail cache policy")
struct PickyConversationAttachmentThumbnailPolicyTests {
    @Test
    func cacheKeyNormalizesPathAndVersionForEquivalentInputs() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)

        let canonical = PickyConversationAttachmentThumbnailPolicy.cacheKey(
            for: "/tmp/../tmp/preview.webp",
            modificationDate: date
        )
        let raw = PickyConversationAttachmentThumbnailPolicy.cacheKey(
            for: "/tmp/preview.webp",
            modificationDate: date
        )

        #expect(canonical == raw)
        #expect(canonical.keyString == raw.keyString)
    }

    @Test
    func cacheKeyVersionChangesWhenModificationDateChanges() {
        let path = "/tmp/preview.webp"
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = initial.addingTimeInterval(60)

        let initialKey = PickyConversationAttachmentThumbnailPolicy.cacheKey(for: path, modificationDate: initial)
        let updatedKey = PickyConversationAttachmentThumbnailPolicy.cacheKey(for: path, modificationDate: updated)

        #expect(initialKey.standardizedPath == updatedKey.standardizedPath)
        #expect(initialKey.modificationVersion != updatedKey.modificationVersion)
    }

    @Test
    func cacheKeyForNonFileURLIsNil() throws {
        let webURL = try #require(URL(string: "https://example.com/avatar.png"))

        #expect(PickyConversationAttachmentThumbnailPolicy.cacheKey(for: webURL) == nil)
    }
}

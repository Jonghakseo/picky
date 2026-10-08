import Combine
import Testing
@testable import Picky

@MainActor
struct PickyHUDArchiveHoverRevealTests {
    @Test func passingOverARowNeverShowsTheArchiveButton() async throws {
        let reveal = PickyHUDArchiveHoverReveal(delay: .milliseconds(150))
        defer { reveal.cancel() }
        reveal.setHovering(true)
        try await Task.sleep(for: .milliseconds(60))
        reveal.setHovering(false)
        // Cross the reveal deadline: a cancelled wait must not show the button late.
        try await Task.sleep(for: .milliseconds(250))
        #expect(!reveal.isRevealed)
    }

    @Test func restingRevealsTheButtonAndLeavingHidesItAtOnce() async throws {
        let reveal = PickyHUDArchiveHoverReveal(delay: .milliseconds(150))
        defer { reveal.cancel() }
        reveal.setHovering(true)
        #expect(!reveal.isRevealed)
        try await withPickyTestTimeout("archive button appears after resting") {
            for await revealed in reveal.$isRevealed.values where revealed { return }
        }

        reveal.setHovering(false)
        #expect(!reveal.isRevealed)

        // Coming back starts a fresh wait instead of showing the button immediately.
        reveal.setHovering(true)
        #expect(!reveal.isRevealed)
    }
}

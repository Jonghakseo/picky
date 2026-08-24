//
//  OnboardingFlowControllerArchiveProjectionTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct OnboardingFlowControllerArchiveProjectionTests {
    @Test func archiveMembershipPublisherEmitsInitialArchivedIDs() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel()
        PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.bootstrapSnapshotEvent(), to: viewModel)
        let expectedIDs = Set(PickyProjectionReplayFixtures.lightweightBootstrapSessions()
            .filter { $0.archived == true }
            .map(\.id))
        var emissions: [Set<String>] = []

        let cancellable = viewModel.archivedSessionIDsPublisher.sink { emissions.append($0) }

        #expect(emissions == [expectedIDs])
        #expect(viewModel.isSessionArchived("bootstrap-000"))
        #expect(!viewModel.isSessionArchived("bootstrap-001"))
        withExtendedLifetime(cancellable) {}
    }

    @Test func archiveMembershipPublisherUpdatesAfterArchiveAndUnarchive() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel()
        PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.bootstrapSnapshotEvent(), to: viewModel)
        let initialIDs = Set(viewModel.archivedSessions.map(\.id))
        var emissions: [Set<String>] = []
        let cancellable = viewModel.archivedSessionIDsPublisher.sink { emissions.append($0) }

        viewModel.archive(sessionID: "bootstrap-001")
        viewModel.unarchive(sessionID: "bootstrap-001")

        #expect(emissions == [initialIDs, initialIDs.union(["bootstrap-001"]), initialIDs])
        withExtendedLifetime(cancellable) {}
    }

    @Test func archiveMembershipPublisherReleasesCancelledSubscriber() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel()
        weak var weakProbe: ArchiveMembershipSubscriberProbe?

        do {
            let probe = ArchiveMembershipSubscriberProbe()
            weakProbe = probe
            let cancellable = viewModel.archivedSessionIDsPublisher.sink { [probe] _ in
                _ = probe
            }
            withExtendedLifetime(cancellable) {}
        }

        #expect(weakProbe == nil)
    }
}

private final class ArchiveMembershipSubscriberProbe {}

//
//  PickyHUDDockSummaryPolicyTests.swift
//  PickyTests
//
//  Coverage for the minimized dock status summary aggregation.
//

import Testing
@testable import Picky

struct PickyHUDDockSummaryPolicyTests {
    @Test func everyStatusIsBucketedAcrossAllStates() {
        let statuses: [PickySessionStatus] = [
            .running, .running, .running,
            .waiting_for_input, .blocked,
            .failed,
            .completed, .completed,
            .queued, .cancelled
        ]
        let summary = PickyHUDDockSummaryPolicy.summary(for: statuses)
        #expect(summary == [
            PickyHUDDockSummaryItem(status: .running, count: 3),
            PickyHUDDockSummaryItem(status: .waiting, count: 2),
            PickyHUDDockSummaryItem(status: .failed, count: 1),
            PickyHUDDockSummaryItem(status: .completed, count: 2),
            PickyHUDDockSummaryItem(status: .neutral, count: 2)
        ])
        // Counts cover every input session.
        #expect(summary.reduce(0) { $0 + $1.count } == statuses.count)
    }

    @Test func ordersByAllCasesRegardlessOfInputOrder() {
        let summary = PickyHUDDockSummaryPolicy.summary(for: [.cancelled, .completed, .failed, .waiting_for_input, .running])
        #expect(summary.map(\.status) == [.running, .waiting, .failed, .completed, .neutral])
    }

    @Test func zeroCountBucketsAreHidden() {
        let summary = PickyHUDDockSummaryPolicy.summary(for: [.completed])
        #expect(summary == [PickyHUDDockSummaryItem(status: .completed, count: 1)])
        #expect(!PickyHUDDockSummaryPolicy.isCalm(summary))
    }

    @Test func queuedAndCancelledShareTheNeutralBucket() {
        let summary = PickyHUDDockSummaryPolicy.summary(for: [.queued, .cancelled, .queued])
        #expect(summary == [PickyHUDDockSummaryItem(status: .neutral, count: 3)])
    }

    @Test func onlyEmptyInputIsCalm() {
        #expect(PickyHUDDockSummaryPolicy.isCalm(PickyHUDDockSummaryPolicy.summary(for: [])))
        #expect(!PickyHUDDockSummaryPolicy.isCalm(PickyHUDDockSummaryPolicy.summary(for: [.completed])))
    }
}

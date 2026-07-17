//
//  PickyHUDDockSummaryPolicyTests.swift
//  PickyTests
//
//  Coverage for the minimized dock status summary aggregation.
//

import Testing
@testable import Picky

struct PickyHUDDockSummaryPolicyTests {
    @Test func bucketsMapRunningWaitingFailedAndIgnoreNeutralTerminal() {
        let statuses: [PickySessionStatus] = [
            .running, .running, .running,
            .waiting_for_input, .blocked,
            .failed,
            .queued, .completed, .cancelled
        ]
        let summary = PickyHUDDockSummaryPolicy.summary(for: statuses)
        #expect(summary == [
            PickyHUDDockSummaryItem(status: .running, count: 3),
            PickyHUDDockSummaryItem(status: .waiting, count: 2),
            PickyHUDDockSummaryItem(status: .failed, count: 1)
        ])
    }

    @Test func ordersRunningWaitingFailedRegardlessOfInputOrder() {
        let summary = PickyHUDDockSummaryPolicy.summary(for: [.failed, .waiting_for_input, .running])
        #expect(summary.map(\.status) == [.running, .waiting, .failed])
    }

    @Test func zeroCountBucketsAreHidden() {
        let summary = PickyHUDDockSummaryPolicy.summary(for: [.failed])
        #expect(summary == [PickyHUDDockSummaryItem(status: .failed, count: 1)])
        #expect(!PickyHUDDockSummaryPolicy.isCalm(summary))
    }

    @Test func onlyNeutralOrTerminalSessionsAreCalm() {
        let summary = PickyHUDDockSummaryPolicy.summary(for: [.queued, .completed, .cancelled])
        #expect(summary.isEmpty)
        #expect(PickyHUDDockSummaryPolicy.isCalm(summary))
    }

    @Test func emptyInputIsCalm() {
        #expect(PickyHUDDockSummaryPolicy.isCalm(PickyHUDDockSummaryPolicy.summary(for: [])))
    }
}

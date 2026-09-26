import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyAsyncTaskShelfTests {
    @Test func missingDetailPreservesSummaryAndIsNotKnownEmpty() {
        let summary = PickyAsyncTaskShelfFixtures.summary(active: 0)
        #expect(PickyAsyncTaskShelfPresentation.isVisible(summary: summary, detail: .unavailable))
        #expect(!PickyAsyncTaskShelfPresentation.isVisible(summary: summary, detail: .loaded(.init(tasks: [], tickets: []))))
        #expect(PickyAsyncTaskShelfPresentation.isVisible(summary: PickyAsyncTaskShelfFixtures.summary(active: 2),
                                                          detail: .loaded(.init(tasks: [], tickets: []))))
    }

    @Test func currentRootsPrecedeHistoryAndSettledSuccessDoesNotKeepShelfOpen() {
        var old = PickyAsyncTaskShelfFixtures.task("old", execution: .succeeded, presence: .settled)
        old.createdAt = Date(timeIntervalSince1970: 100)
        let active = PickyAsyncTaskShelfFixtures.task("active")
        let failed = PickyAsyncTaskShelfFixtures.task("failed", execution: .failed, presence: .settled)
        let detail = PickyAsyncTaskDetail(tasks: [old, failed, active], tickets: [])
        #expect(PickyAsyncTaskShelfPresentation.roots(in: detail).map(\.taskId) == ["active", "failed"])
        #expect(!PickyAsyncTaskShelfPresentation.isVisible(summary: PickyAsyncTaskShelfFixtures.summary(active: 0),
            detail: .loaded(.init(tasks: [old], tickets: []))))
        #expect(PickyAsyncTaskShelfPresentation.isVisible(summary: PickyAsyncTaskShelfFixtures.summary(active: 0, attention: 1),
            detail: .loaded(detail)))
    }

    @Test func pendingDeliveryAndQueuedRegistrationStayAheadOfRecentFailedHistory() {
        var delivery = PickyAsyncTaskShelfFixtures.task("delivery", execution: .succeeded, presence: .settled)
        delivery.createdAt = Date(timeIntervalSince1970: 10)
        var queued = PickyAsyncTaskShelfFixtures.task("queued", execution: .queued, presence: .settled)
        queued.registration = .reserved
        queued.createdAt = Date(timeIntervalSince1970: 20)
        var failed = PickyAsyncTaskShelfFixtures.task("failed", execution: .failed, presence: .settled)
        failed.createdAt = Date(timeIntervalSince1970: 30)
        let detail = PickyAsyncTaskDetail(tasks: [failed, delivery, queued], tickets: [
            PickyAsyncTaskShelfFixtures.ticket(delivery, state: .processing)
        ])
        #expect(PickyAsyncTaskShelfPresentation.roots(in: detail).map(\.taskId) == ["queued", "delivery", "failed"])
        #expect(PickyAsyncTaskShelfPresentation.primaryStateKey(delivery, tickets: detail.tickets) == "hud.asyncTasks.result.processing")
        #expect(PickyAsyncTaskShelfPresentation.roots(in: .init(tasks: [delivery], tickets: [])).isEmpty)
    }

    @Test func refreshedNotesNeverOverrideNewerLifecycleOrResultState() {
        let root = PickyAsyncTaskShelfFixtures.task("root")
        var fetched = root
        fetched.details = ["report": .string("Ready")]
        let response = PickyAsyncTaskDetail(tasks: [fetched], tickets: [PickyAsyncTaskShelfFixtures.ticket(root, state: .pending)])
        #expect(PickyAsyncTaskShelfPresentation.supplementalLines(for: root, in: response) == ["report: Ready"])
        var updated = root
        updated.execution = .succeeded
        updated.presence = .settled
        updated.providerRevision += 1
        updated.updatedAt = updated.updatedAt.addingTimeInterval(1)
        let authoritative = PickyAsyncTaskDetail(tasks: [updated], tickets: [PickyAsyncTaskShelfFixtures.ticket(updated, state: .handled)])
        #expect(PickyAsyncTaskShelfPresentation.supplementalLines(for: updated, in: response).isEmpty)
        #expect(PickyAsyncTaskShelfPresentation.roots(in: authoritative).isEmpty)
        #expect(PickyAsyncTaskShelfPresentation.primaryStateKey(updated, tickets: authoritative.tickets) == "hud.asyncTasks.execution.succeeded")
    }

    @Test func archivedDeletionRequiresReadyQuiescentAuthoritativeSummary() {
        var summary = PickyAsyncTaskShelfFixtures.summary(active: 0)
        summary.canReleaseRuntime = true
        #expect(summary.permitsArchivedDeletion)
        summary.pendingCompletionCount = 1
        #expect(!summary.permitsArchivedDeletion)
        summary.pendingCompletionCount = 0
        summary.tracking = .reconciling
        #expect(!summary.permitsArchivedDeletion)
        summary.tracking = .ready
        summary.uncertainExecutionCount = 1
        #expect(!summary.permitsArchivedDeletion)
    }

    @Test func descendantsAreDetailsNotIndependentCancelTargets() {
        let root = PickyAsyncTaskShelfFixtures.task("group", kind: "subagent")
        let child = PickyAsyncTaskShelfFixtures.task("child", root: "group")
        let detail = PickyAsyncTaskDetail(tasks: [root, child], tickets: [])
        #expect(PickyAsyncTaskShelfPresentation.roots(in: detail).map(\.taskId) == ["group"])
        #expect(PickyAsyncTaskShelfPresentation.members(of: root, in: detail).count == 2)
        #expect(!PickyAsyncTaskShelfPresentation.canCancel(child, in: detail, summary: PickyAsyncTaskShelfFixtures.summary(), availability: .available))
    }

    @Test func ownerScopesIdentityChildrenAndResultTickets() {
        var root = PickyAsyncTaskShelfFixtures.task("same")
        var other = root
        other.providerInstanceId = "restarted"
        let detail = PickyAsyncTaskDetail(tasks: [root, other], tickets: [PickyAsyncTaskShelfFixtures.ticket(other, state: .failed)])
        #expect(root.shelfIdentity != other.shelfIdentity)
        let identity = root.shelfIdentity
        root.progress = "new progress"
        root.providerRevision += 1
        #expect(root.shelfIdentity == identity)
        #expect(PickyAsyncTaskShelfPresentation.members(of: root, in: detail).count == 1)
        #expect(PickyAsyncTaskShelfPresentation.tickets(for: root, in: detail).isEmpty)
    }

    @Test func providerDetailFieldsStayReadOnlyTextWithoutOpeningPaths() {
        var root = PickyAsyncTaskShelfFixtures.task("root")
        root.details = ["log": .string("build completed"), "report": .string("/tmp/provider-report.md")]
        #expect(PickyAsyncTaskShelfPresentation.detailLines(root) == [
            "log: build completed", "report: /tmp/provider-report.md"
        ])
    }

    @Test func resultHandlingDoesNotPretendExecutionIsRunning() {
        let root = PickyAsyncTaskShelfFixtures.task("done", execution: .succeeded, presence: .settled)
        #expect(PickyAsyncTaskShelfPresentation.executionKey(root) == "hud.asyncTasks.execution.succeeded")
        #expect(PickyAsyncTaskShelfPresentation.resultKey([PickyAsyncTaskShelfFixtures.ticket(root, state: .pending)]) == "hud.asyncTasks.result.pending")
        #expect(PickyAsyncTaskShelfPresentation.resultKey([PickyAsyncTaskShelfFixtures.ticket(root, state: .processing)]) == "hud.asyncTasks.result.processing")
        #expect(PickyAsyncTaskShelfPresentation.resultKey([PickyAsyncTaskShelfFixtures.ticket(root, state: .failed)]) == "hud.asyncTasks.result.failed")
        #expect(PickyAsyncTaskShelfPresentation.resultKey([PickyAsyncTaskShelfFixtures.ticket(root, state: .handled)]) == nil)
    }

    @Test func cancellationRequiresCapabilityAndReadyTracking() {
        let root = PickyAsyncTaskShelfFixtures.task("running")
        let detail = PickyAsyncTaskDetail(tasks: [root], tickets: [])
        let summary = PickyAsyncTaskShelfFixtures.summary()
        #expect(PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: summary, availability: .available))
        for capability in [PickyAsyncTaskCancelAvailability.unsupported, .pending, .unavailable("Offline")] {
            #expect(!PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: summary, availability: capability))
        }
        #expect(PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: summary, availability: .failed("Rejected")))
        #expect(!PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: PickyAsyncTaskShelfFixtures.summary(tracking: .reconciling), availability: .available))
    }

    @Test func rejectedStartingGrantIsNotCancellableAfterResourceSettlement() {
        var root = PickyAsyncTaskShelfFixtures.task("rejected", kind: "subagent", execution: .failed, presence: .settled)
        root.registration = .starting
        let summary = PickyAsyncTaskShelfFixtures.summary(active: 0)
        #expect(!PickyAsyncTaskShelfPresentation.canCancel(root, in: .init(tasks: [root], tickets: []),
                                                          summary: summary, availability: .available))
        let child = PickyAsyncTaskShelfFixtures.task("survivor", root: "rejected")
        #expect(PickyAsyncTaskShelfPresentation.canCancel(root, in: .init(tasks: [root, child], tickets: []),
                                                         summary: PickyAsyncTaskShelfFixtures.summary(), availability: .available))
    }

    @Test func cancellingRootDoesNotOfferAnotherStopEvenWithActiveDescendants() {
        let root = PickyAsyncTaskShelfFixtures.task("stopping", execution: .cancelling)
        let child = PickyAsyncTaskShelfFixtures.task("survivor", root: "stopping")
        let detail = PickyAsyncTaskDetail(tasks: [root, child], tickets: [])
        #expect(!PickyAsyncTaskShelfPresentation.canCancel(root, in: detail,
                                                          summary: PickyAsyncTaskShelfFixtures.summary(), availability: .available))
    }

    @Test func settledRootWithSurvivingChildCanStillBeStopped() {
        let root = PickyAsyncTaskShelfFixtures.task("root", execution: .failed, presence: .settled)
        let child = PickyAsyncTaskShelfFixtures.task("child", root: "root")
        let summary = PickyAsyncTaskShelfFixtures.summary()
        #expect(!PickyAsyncTaskShelfPresentation.canCancel(root, in: .init(tasks: [root], tickets: []), summary: summary, availability: .available))
        #expect(PickyAsyncTaskShelfPresentation.canCancel(root, in: .init(tasks: [root, child], tickets: []), summary: summary, availability: .available))
        var unknown = root
        unknown.presence = .unknown
        #expect(PickyAsyncTaskShelfPresentation.executionKey(unknown) == "hud.asyncTasks.execution.unknown")
    }
}

@MainActor
enum PickyAsyncTaskShelfFixtures {
    static func summary(active: Int = 1, pending: Int = 0, unknown: Int = 0, attention: Int = 0,
                        tracking: PickyAsyncWorkSummary.Tracking = .ready) -> PickyAsyncWorkSummary {
        .init(tracking: tracking, activeRootCount: active, pendingCompletionCount: pending,
              uncertainExecutionCount: unknown, attentionCount: attention, workRevision: 1, canReleaseRuntime: false)
    }

    static func task(_ id: String, root: String? = nil, kind: String = "bash", title: String? = nil,
                     execution: PickyExecutionState = .running, presence: PickyExecutionPresence = .active) -> PickyAsyncTask {
        .init(sessionId: "session", piSessionId: "pi", runtimeInstanceId: "runtime",
              providerId: "provider", providerInstanceId: "instance",
              taskId: id, rootTaskId: root ?? id, parentTaskId: root, kind: kind, title: title ?? "Run local checks",
              execution: execution, presence: presence, registration: .spawned, providerRevision: 1,
              controlGeneration: 1, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }

    static func ticket(_ root: PickyAsyncTask, state: PickyCompletionState) -> PickyCompletionTicket {
        .init(sessionId: root.sessionId, piSessionId: root.piSessionId, runtimeInstanceId: root.runtimeInstanceId,
              providerId: root.providerId, providerInstanceId: root.providerInstanceId,
              completionId: "completion", rootTaskId: root.taskId, target: .model,
              state: state, controlGeneration: 1, cycleId: state == .processing || state == .handled ? "cycle" : nil)
    }
}

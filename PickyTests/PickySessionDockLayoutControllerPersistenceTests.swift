//
//  PickySessionDockLayoutControllerPersistenceTests.swift
//  PickyTests
//
//  Regression coverage for durable CLI/main-agent dock mutations that overlap
//  synchronous UI mutations at the shared FIFO persistence boundary.
//

import XCTest
@testable import Picky

@MainActor
final class PickySessionDockLayoutControllerPersistenceTests: XCTestCase {
    func testDurableGroupAdmissionAndLaterUIGroupBothSurviveInMemoryAndOnDisk() async throws {
        let initial = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b")
        ])
        let store = FIFODockLayoutStore(layout: initial)
        let controller = PickySessionDockLayoutController(store: store)

        let durableMutation = Task {
            try await controller.createGroupPersisting(name: "CLI", withMemberIDs: ["a"])
        }
        await store.waitUntilAdmissionCount(1)

        let cliGroupID = try XCTUnwrap(controller.layout.groups.first?.id)
        let uiGroupID = controller.createGroup(name: "UI", withMemberIDs: ["b"])
        let expected = ["group:\(cliGroupID)[a]", "group:\(uiGroupID)[b]"]

        XCTAssertEqual(controller.layout.persistenceTestEntryDescriptions, expected)

        store.completeNext()
        store.completeNext()
        _ = try await durableMutation.value

        XCTAssertEqual(controller.layout.persistenceTestEntryDescriptions, expected)
        XCTAssertEqual(store.disk.persistenceTestEntryDescriptions, expected)
    }

    func testFailedDurableGroupAdmissionRollsBackWhenNoLaterMutationWasAccepted() async {
        let initial = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b")
        ])
        let store = FIFODockLayoutStore(
            layout: initial,
            outcomes: [.failure(FIFODockLayoutStore.SaveError.failed)]
        )
        var reportedErrors: [Error] = []
        let controller = PickySessionDockLayoutController(store: store) { reportedErrors.append($0) }

        let durableMutation = Task {
            try await controller.createGroupPersisting(name: "CLI", withMemberIDs: ["a"])
        }
        await store.waitUntilAdmissionCount(1)

        XCTAssertEqual(controller.layout.groups.map(\.name), ["CLI"])
        store.completeNext()

        do {
            _ = try await durableMutation.value
            XCTFail("Expected durable persistence failure")
        } catch is FIFODockLayoutStore.SaveError {}
        catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(controller.layout, initial)
        XCTAssertEqual(store.disk, initial)
        XCTAssertEqual(reportedErrors.count, 1)
    }

    func testFailedDurableGroupAdmissionKeepsLaterAcceptedUIGroupAndPersistsCompositeLayout() async {
        let initial = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b")
        ])
        let store = FIFODockLayoutStore(
            layout: initial,
            outcomes: [.failure(FIFODockLayoutStore.SaveError.failed), .success(())]
        )
        var reportedErrors: [Error] = []
        let controller = PickySessionDockLayoutController(store: store) { reportedErrors.append($0) }

        let durableMutation = Task {
            try await controller.createGroupPersisting(name: "CLI", withMemberIDs: ["a"])
        }
        await store.waitUntilAdmissionCount(1)

        guard let cliGroupID = controller.layout.groups.first?.id else {
            return XCTFail("Expected the durable group to be published before its save completes")
        }
        let uiGroupID = controller.createGroup(name: "UI", withMemberIDs: ["b"])
        let expected = ["group:\(cliGroupID)[a]", "group:\(uiGroupID)[b]"]

        store.completeNext()
        store.completeNext()

        do {
            _ = try await durableMutation.value
            XCTFail("Expected durable persistence failure")
        } catch is FIFODockLayoutStore.SaveError {}
        catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(controller.layout.persistenceTestEntryDescriptions, expected)
        XCTAssertEqual(store.disk.persistenceTestEntryDescriptions, expected)
        XCTAssertEqual(reportedErrors.count, 1)
    }
}

@MainActor
private final class FIFODockLayoutStore: PickyDockLayoutStoring {
    enum SaveError: Error { case failed }

    private struct Admission {
        let layout: PickyDockLayout
        let completion: @MainActor (Result<Void, Error>) -> Void
    }

    private var admissions: [Admission] = []
    private var admissionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var outcomes: [Result<Void, Error>]

    private(set) var disk: PickyDockLayout

    init(layout: PickyDockLayout, outcomes: [Result<Void, Error>] = []) {
        disk = layout
        self.outcomes = outcomes
    }

    func load() -> PickyDockLayout { disk }

    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        admissions.append(Admission(layout: layout, completion: completion))
        resumeAdmissionWaiters()
    }

    func waitUntilAdmissionCount(_ count: Int) async {
        guard admissions.count < count else { return }
        await withCheckedContinuation { continuation in
            admissionWaiters.append((count, continuation))
        }
    }

    func completeNext() {
        let admission = admissions.removeFirst()
        let result = outcomes.isEmpty ? Result<Void, Error>.success(()) : outcomes.removeFirst()
        if case .success = result {
            disk = admission.layout
        }
        admission.completion(result)
        resumeAdmissionWaiters()
    }

    private func resumeAdmissionWaiters() {
        let ready = admissionWaiters.filter { admissions.count >= $0.count }
        admissionWaiters.removeAll { admissions.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private extension PickyDockLayout {
    var persistenceTestEntryDescriptions: [String] {
        entries.map { entry in
            switch entry {
            case .session(let id): "session:\(id)"
            case .group(let group): "group:\(group.id)[\(group.memberSessionIDs.joined(separator: ","))]"
            }
        }
    }
}

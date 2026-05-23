//
//  PickyGitChipActionRunnerTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickyGitChipActionRunnerTests {
    @Test func resolvePiDestinationFollowsRenameBranchPolicy() {
        // Mirrors PickyConversationHeaderView.sendRenameCommand: terminal-ish
        // statuses (completed, blocked) queue as follow-up so the next user
        // turn picks them up; everything else steers into the current turn.
        #expect(PickyGitChipPiDestination.resolve(for: .completed) == .followUp)
        #expect(PickyGitChipPiDestination.resolve(for: .blocked) == .followUp)
        #expect(PickyGitChipPiDestination.resolve(for: .running) == .steer)
        #expect(PickyGitChipPiDestination.resolve(for: .waiting_for_input) == .steer)
        #expect(PickyGitChipPiDestination.resolve(for: .queued) == .steer)
        #expect(PickyGitChipPiDestination.resolve(for: .cancelled) == .steer)
        #expect(PickyGitChipPiDestination.resolve(for: .failed) == .steer)
    }

    @Test func piActionInRunningSessionDispatchesSteer() async {
        let viewModel = RecordingDispatch()
        let env = RecordingEnvironment()
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .pi, command: "/diff-review"),
            sessionID: "session-running",
            status: .running,
            cwd: "/tmp/project",
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(viewModel.steerCalls == [.init(text: "/diff-review", sessionID: "session-running")])
        #expect(viewModel.followUpCalls.isEmpty)
        #expect(env.shellInvocations.isEmpty)
        #expect(env.failureNotifications.isEmpty)
    }

    @Test func piActionInCompletedSessionDispatchesFollowUp() async {
        let viewModel = RecordingDispatch()
        let env = RecordingEnvironment()
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .pi, command: "/diff-review HEAD~3"),
            sessionID: "session-done",
            status: .completed,
            cwd: "/tmp/project",
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(viewModel.followUpCalls == [.init(text: "/diff-review HEAD~3", sessionID: "session-done")])
        #expect(viewModel.steerCalls.isEmpty)
    }

    @Test func piActionFailureBecomesNotification() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let viewModel = RecordingDispatch(throwOnDispatch: Boom())
        let env = RecordingEnvironment()
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .pi, command: "/diff-review"),
            sessionID: "session-running",
            status: .running,
            cwd: nil,
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(env.failureNotifications.count == 1)
        #expect(env.failureNotifications.first?.message == "boom")
    }

    @Test func shellActionInvokesEnvironmentWithSessionCwd() async {
        let viewModel = RecordingDispatch()
        let env = RecordingEnvironment()
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .shell, command: "open -a Cursor ."),
            sessionID: "session",
            status: .completed,
            cwd: "/tmp/project",
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(env.shellInvocations == [.init(command: "open -a Cursor .", cwd: "/tmp/project")])
        #expect(env.failureNotifications.isEmpty)
        #expect(viewModel.followUpCalls.isEmpty)
        #expect(viewModel.steerCalls.isEmpty)
    }

    @Test func shellActionWithoutCwdFailsLoudly() async {
        let viewModel = RecordingDispatch()
        let env = RecordingEnvironment()
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .shell, command: "open ."),
            sessionID: "session",
            status: .completed,
            cwd: nil,
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(env.shellInvocations.isEmpty)
        #expect(env.failureNotifications.count == 1)
    }

    @Test func shellActionLaunchFailurePostsNotification() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "exec failed" } }
        let viewModel = RecordingDispatch()
        let env = RecordingEnvironment(shellError: Boom())
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .shell, command: "missing"),
            sessionID: "session",
            status: .completed,
            cwd: "/tmp/project",
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(env.failureNotifications.first?.message == "exec failed")
    }

    @Test func emptyCommandSurfacesAsConfigurationNotification() async {
        let viewModel = RecordingDispatch()
        let env = RecordingEnvironment()
        await PickyGitChipActionRunner.run(
            action: PickyGitChipAction(kind: .pi, command: "   "),
            sessionID: "session",
            status: .running,
            cwd: "/tmp/project",
            viewModel: viewModel,
            environment: env.environment
        )
        #expect(viewModel.steerCalls.isEmpty)
        #expect(viewModel.followUpCalls.isEmpty)
        #expect(env.failureNotifications.first?.title == "Git chip action is empty")
    }
}

@MainActor
private final class RecordingDispatch: PickyGitChipActionViewModelDispatch {
    struct Call: Equatable {
        let text: String
        let sessionID: String?
    }
    var followUpCalls: [Call] = []
    var steerCalls: [Call] = []
    let throwOnDispatch: Error?

    init(throwOnDispatch: Error? = nil) {
        self.throwOnDispatch = throwOnDispatch
    }

    func followUp(text: String, sessionID: String?) async throws {
        followUpCalls.append(Call(text: text, sessionID: sessionID))
        if let throwOnDispatch { throw throwOnDispatch }
    }

    func steer(text: String, sessionID: String?) async throws {
        steerCalls.append(Call(text: text, sessionID: sessionID))
        if let throwOnDispatch { throw throwOnDispatch }
    }
}

@MainActor
private final class RecordingEnvironment {
    struct ShellInvocation: Equatable {
        let command: String
        let cwd: String
    }
    struct FailureNotification: Equatable {
        let title: String
        let message: String
    }

    var shellInvocations: [ShellInvocation] = []
    var failureNotifications: [FailureNotification] = []
    private let shellError: Error?

    init(shellError: Error? = nil) {
        self.shellError = shellError
    }

    var environment: PickyGitChipActionEnvironment {
        PickyGitChipActionEnvironment(
            runShell: { [weak self] command, cwd in
                self?.shellInvocations.append(ShellInvocation(command: command, cwd: cwd))
                if let shellError = self?.shellError { throw shellError }
            },
            deliverFailureNotification: { [weak self] title, message in
                self?.failureNotifications.append(FailureNotification(title: title, message: message))
            }
        )
    }
}

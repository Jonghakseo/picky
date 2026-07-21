//
//  PickySystemPermissionGatewayTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickySystemPermissionGatewayTests {
    @Test func unitTestsBlockScreenContentBeforeTheSystemProviderIsInvoked() async {
        var invocationCount = 0
        let gateway = PickySystemPermissionGateway(
            isRunningUnitTests: { true },
            screenShareableContentProvider: {
                invocationCount += 1
                throw PermissionGatewayTestError.invoked
            }
        )

        await #expect(throws: PickySystemPermissionAccessError.self) {
            _ = try await gateway.screenShareableContent()
        }
        #expect(invocationCount == 0)
    }

    @Test func liveEnvironmentDelegatesScreenContentToTheSystemProvider() async {
        var invocationCount = 0
        let gateway = PickySystemPermissionGateway(
            isRunningUnitTests: { false },
            screenShareableContentProvider: {
                invocationCount += 1
                throw PermissionGatewayTestError.invoked
            }
        )

        await #expect(throws: PermissionGatewayTestError.self) {
            _ = try await gateway.screenShareableContent()
        }
        #expect(invocationCount == 1)
    }

    @Test func pttWarmupDoesNotCreateAScreenContentTaskInUnitTests() async {
        var warmupInvocationCount = 0
        let pipeline = PickyVoiceContextCapturePipeline(
            coordinator: PickyVoiceContextCaptureCoordinator(
                screenCapture: { _, _, _ in [] },
                contextPreflightCapture: { fatalError("PTT warmup must not capture context") },
                contextPreparer: { _, _, _, _ in fatalError("PTT warmup must not prepare context") }
            ),
            isRunningUnitTests: { true },
            screenShareableContentWarmup: {
                warmupInvocationCount += 1
            }
        )

        pipeline.beginInput()
        await Task.yield()

        #expect(warmupInvocationCount == 0)
    }
}

private enum PermissionGatewayTestError: Error {
    case invoked
}

//
//  PickyRuntimeEnvironmentTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

struct PickyRuntimeEnvironmentTests {
    @Test func unitTestsFailClosedAtUserEnvironmentBoundaries() {
        #expect(PickyRuntimeEnvironment.isRunningUnitTests)
        #expect(!PickyRuntimeEnvironment.allowsUserEnvironmentEffects)
    }

    @Test func unitTestDetectionAcceptsXCTestEnvironmentAndExecutable() {
        #expect(PickyRuntimeEnvironment.isUnitTestProcess(
            environment: ["XCTestConfigurationFilePath": "/tmp/Picky.xctestconfiguration"],
            arguments: ["/tmp/Picky.app/Contents/MacOS/Picky"]
        ))
        #expect(PickyRuntimeEnvironment.isUnitTestProcess(
            environment: [:],
            arguments: ["/usr/bin/xctest"]
        ))
    }

    @Test func unitTestDetectionRejectsArbitraryArgumentsContainingXCTest() {
        #expect(!PickyRuntimeEnvironment.isUnitTestProcess(
            environment: [:],
            arguments: ["/tmp/xctest/Picky", "--note=xctest"]
        ))
    }

    @Test func unitTestsUseAnIsolatedUserDefaultsDomain() {
        #expect(PickyRuntimeEnvironment.unitTestDefaultsSuiteName.hasSuffix(
            ".\(ProcessInfo.processInfo.processIdentifier)"
        ))
        let key = "PickyRuntimeEnvironmentTests.\(UUID().uuidString)"
        let productionValueBeforeTest = UserDefaults.standard.object(forKey: key) as? String
        defer { PickyRuntimeEnvironment.userDefaults.removeObject(forKey: key) }

        PickyRuntimeEnvironment.userDefaults.set("unit-test-value", forKey: key)

        #expect(PickyRuntimeEnvironment.userDefaults.string(forKey: key) == "unit-test-value")
        #expect(UserDefaults.standard.object(forKey: key) as? String == productionValueBeforeTest)
    }

    @Test func uiEffectsRequireBothExplicitOptInAndAnIsolatedSession() {
        let key = PickyRuntimeEnvironment.prePushUIEffectTestsEnvironmentKey
        let session = PickyRuntimeEnvironment.uiTestSessionEnvironmentKey

        #expect(PickyRuntimeEnvironment.shouldRunPrePushUIEffectTests(environment: [key: "1", session: "isolated"]))
        #expect(!PickyRuntimeEnvironment.shouldRunPrePushUIEffectTests(environment: [key: "1"]))
        #expect(!PickyRuntimeEnvironment.shouldRunPrePushUIEffectTests(environment: [key: "1", session: "desktop"]))
        #expect(!PickyRuntimeEnvironment.shouldRunPrePushUIEffectTests(environment: [key: "0", session: "isolated"]))
        #expect(!PickyRuntimeEnvironment.shouldRunPrePushUIEffectTests(environment: [session: "isolated"]))
        #expect(!PickyRuntimeEnvironment.shouldRunPrePushUIEffectTests(environment: [:]))
    }

    @MainActor
    @Test func ordinaryTestHostCannotActivateOnTheDesktop() {
        guard !PickyRuntimeEnvironment.runsPrePushUIEffectTests else { return }
        #expect(NSApp.activationPolicy() == .prohibited)
        #expect(!NSApp.isActive)
    }

    @Test func unitTestsDoNotInvokeTheKeychainFallback() {
        var providerInvocationCount = 0

        let value = AzureOpenAIKeychainStore.value(
            for: "OPENAI_API_KEY",
            environment: [:],
            keychainValuesProvider: {
                providerInvocationCount += 1
                return ["OPENAI_API_KEY": "secret-from-keychain"]
            }
        )

        #expect(value == nil)
        #expect(providerInvocationCount == 0)
    }

    @Test func explicitEnvironmentValuesStillTakePrecedenceWithoutKeychainAccess() {
        let value = AzureOpenAIKeychainStore.value(
            for: "OPENAI_API_KEY",
            environment: ["OPENAI_API_KEY": "test-environment-key"],
            keychainValuesProvider: {
                Issue.record("Keychain fallback must not run when an environment value exists")
                return [:]
            }
        )

        #expect(value == "test-environment-key")
    }

    @Test func liveKeychainBoundaryDelegatesToItsProvider() {
        var providerInvocationCount = 0

        let value = AzureOpenAIKeychainStore.value(
            for: "OPENAI_API_KEY",
            environment: [:],
            allowsKeychainAccess: true,
            keychainValuesProvider: {
                providerInvocationCount += 1
                return ["OPENAI_API_KEY": "recorded-keychain-value"]
            }
        )

        #expect(value == "recorded-keychain-value")
        #expect(providerInvocationCount == 1)
    }
}

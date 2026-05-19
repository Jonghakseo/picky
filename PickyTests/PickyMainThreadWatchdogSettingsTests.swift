//
//  PickyMainThreadWatchdogSettingsTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickySettings.mainThreadWatchdogEnabled")
struct PickyMainThreadWatchdogSettingsTests {
    @Test("defaults는 mainThreadWatchdogEnabled = true")
    func defaultsToEnabled() {
        let settings = PickySettings.defaults()
        #expect(settings.mainThreadWatchdogEnabled == true)
    }

    @Test("기존 settings.json에 키가 없으면 기본값으로 디코드")
    func decodingLegacyFileFallsBackToDefault() throws {
        // Simulate a pre-watchdog settings file that doesn't mention the key.
        let legacy = try PickySettings.defaults().normalizedPaths()
        let data = try JSONEncoder().encode(legacy)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "mainThreadWatchdogEnabled")
        let stripped = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(PickySettings.self, from: stripped)
        #expect(decoded.mainThreadWatchdogEnabled == true)
    }

    @Test("false로 저장하면 라운드트립에서 false로 복원")
    func roundTripsExplicitFalse() throws {
        var settings = PickySettings.defaults()
        settings.mainThreadWatchdogEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PickySettings.self, from: data)
        #expect(decoded.mainThreadWatchdogEnabled == false)
    }
}

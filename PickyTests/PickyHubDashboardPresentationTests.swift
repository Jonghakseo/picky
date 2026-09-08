//
//  PickyHubDashboardPresentationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyHubDashboardPresentationTests {
    @Test func buildsKoreanGreetingForEachDayPart() {
        let locale = Locale(identifier: "ko_KR")

        #expect(PickyHubDashboardPresentation.greeting(date: date("2026-07-16T08:00:00Z"), locale: locale, name: "서 종학", calendar: calendar).title == "좋은 아침입니다, 서님")
        #expect(PickyHubDashboardPresentation.greeting(date: date("2026-07-16T13:00:00Z"), locale: locale, name: "서 종학", calendar: calendar).title == "좋은 오후입니다, 서님")
        #expect(PickyHubDashboardPresentation.greeting(date: date("2026-07-16T20:00:00Z"), locale: locale, name: "서 종학", calendar: calendar).title == "좋은 저녁입니다, 서님")
    }

    @Test func omitsNameWhenItIsBlankAndUsesEnglishCopy() {
        let greeting = PickyHubDashboardPresentation.greeting(
            date: date("2026-07-16T08:00:00Z"),
            locale: Locale(identifier: "en_US"),
            name: "   ",
            calendar: calendar
        )

        #expect(greeting.title == "Good morning")
        #expect(!greeting.subtitle.isEmpty)
    }

    @Test func choosesEmptyWorkTitleForEveryPeriod() {
        #expect(String(describing: PickyHubDashboardPresentation.emptyWorkTitle(period: .thisWeek)).contains("thisWeek"))
        #expect(String(describing: PickyHubDashboardPresentation.emptyWorkTitle(period: .thisMonth)).contains("thisMonth"))
        #expect(String(describing: PickyHubDashboardPresentation.emptyWorkTitle(period: .lastThreeMonths)).contains("lastThreeMonths"))
        #expect(String(describing: PickyHubDashboardPresentation.emptyWorkTitle(period: .all)).contains("all"))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}

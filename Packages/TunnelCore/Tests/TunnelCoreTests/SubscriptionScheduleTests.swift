import XCTest
@testable import TunnelCore

final class SubscriptionScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testEveryDayIsDueAfterTwentyFourHours() {
        let hour = SubscriptionSchedule.everyDay
        XCTAssertTrue(SubscriptionSchedule.isDue(updatedAt: nil, now: date(17, 12), hour: hour, calendar: calendar))
        XCTAssertFalse(SubscriptionSchedule.isDue(updatedAt: date(17, 1), now: date(17, 23), hour: hour, calendar: calendar))
        XCTAssertTrue(SubscriptionSchedule.isDue(updatedAt: date(16, 12), now: date(17, 12), hour: hour, calendar: calendar))
    }

    /// At 7:00: the first opening after 7:00 updates once; before 7:00 the last
    /// day's 7:00 counts.
    func testAtAnHourIsDueOnceAfterIt() {
        // Updated yesterday evening: not due at 6:59, due at 7:00 and later.
        XCTAssertFalse(SubscriptionSchedule.isDue(updatedAt: date(16, 21), now: date(17, 6, 59), hour: 7, calendar: calendar))
        XCTAssertTrue(SubscriptionSchedule.isDue(updatedAt: date(16, 21), now: date(17, 7), hour: 7, calendar: calendar))
        XCTAssertTrue(SubscriptionSchedule.isDue(updatedAt: date(16, 21), now: date(17, 15), hour: 7, calendar: calendar))
        // Updated at 7:05 today: not again until tomorrow's 7:00.
        XCTAssertFalse(SubscriptionSchedule.isDue(updatedAt: date(17, 7, 5), now: date(17, 23), hour: 7, calendar: calendar))
        XCTAssertFalse(SubscriptionSchedule.isDue(updatedAt: date(17, 7, 5), now: date(18, 6), hour: 7, calendar: calendar))
        XCTAssertTrue(SubscriptionSchedule.isDue(updatedAt: date(17, 7, 5), now: date(18, 7, 1), hour: 7, calendar: calendar))
        // Not opened for days: due.
        XCTAssertTrue(SubscriptionSchedule.isDue(updatedAt: date(10, 9), now: date(17, 3), hour: 7, calendar: calendar))
    }
}

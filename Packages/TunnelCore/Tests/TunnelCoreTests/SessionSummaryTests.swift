import XCTest
@testable import TunnelCore

final class SessionSummaryTests: XCTestCase {
    func testRoundTrip() {
        let summary = SessionSummary(started: 1_800_000_000, ended: 1_800_004_325, up: 28 * 1_048_576, down: 340 * 1_048_576)
        XCTAssertEqual(summary.encoded.count, 32)
        XCTAssertEqual(SessionSummary(encoded: summary.encoded), summary)
        XCTAssertEqual(summary.seconds, 4325)
        XCTAssertEqual(summary.total, 368 * 1_048_576)
    }

    func testBadDataAndBackwardClock() {
        XCTAssertNil(SessionSummary(encoded: Data([1, 2, 3])))
        XCTAssertNil(SessionSummary(encoded: Data()))
        XCTAssertEqual(SessionSummary(started: 100, ended: 50, up: 0, down: 0).seconds, 0)
    }
}

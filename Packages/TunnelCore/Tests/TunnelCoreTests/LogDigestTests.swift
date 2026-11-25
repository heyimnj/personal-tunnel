import Foundation
@testable import TunnelCore
import XCTest

final class LogDigestTests: XCTestCase {
    func testUptimeIsDropped() {
        XCTAssertEqual(LogDigest.dropUptime("[0031] [2639462006 15.12s] connection: closed"), "[2639462006 15.12s] connection: closed")
        XCTAssertEqual(LogDigest.dropUptime("[app] Подписка"), "[app] Подписка")
    }

    func testRepeatedLinesStandOnceWithTheirCount() {
        let entries = [
            LogDigest.Entry(level: "ERROR", time: "12:00:01", text: "[11 1.2s] connection: dial tcp <host>: i/o timeout"),
            LogDigest.Entry(level: "INFO", time: "12:00:02", text: "[app] Проверка задержки"),
            LogDigest.Entry(level: "ERROR", time: "12:00:05", text: "[12 300ms] connection: dial tcp <host>: i/o timeout"),
            LogDigest.Entry(level: "ERROR", time: nil, text: "router: rule-set not found"),
            LogDigest.Entry(level: "ERROR", time: nil, text: "router: rule-set not found"),
        ]
        // 3.5.14: the order stays; only a run, and repeats past the third, fold.
        XCTAssertEqual(LogDigest.collapse(entries), [
            "ERROR 12:00:01 [11 1.2s] connection: dial tcp <host>: i/o timeout",
            "INFO 12:00:02 [app] Проверка задержки",
            "ERROR 12:00:05 [12 300ms] connection: dial tcp <host>: i/o timeout",
            "ERROR --:--:-- router: rule-set not found (×2)",
        ])
    }

    func testRepeatsPastTheThirdAreCountedOnItsPlace() {
        var entries: [LogDigest.Entry] = []
        for second in 0 ..< 6 {
            entries.append(LogDigest.Entry(level: "ERROR", time: "12:00:0\(second)", text: "[\(second) 1s] connection: EOF"))
            entries.append(LogDigest.Entry(level: "INFO", time: "12:00:0\(second)", text: "[app] шаг \(second)"))
        }
        let lines = LogDigest.collapse(entries)
        XCTAssertEqual(lines.count, 3 + 6)
        XCTAssertEqual(lines[0], "ERROR 12:00:00 [0 1s] connection: EOF")
        XCTAssertEqual(lines[4], "ERROR 12:00:02 [2 1s] connection: EOF (×4, последний раз 12:00:05)")
        XCTAssertEqual(lines.last, "INFO 12:00:05 [app] шаг 5")
    }

    func testEventsKeepTheLastSessionsAndTheirTellingMemoryLines() {
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        func at(_ seconds: TimeInterval, _ text: String) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: now.addingTimeInterval(seconds)) + " " + text
        }
        let lines = [
            at(-5 * 86_400, "запуск, ядро combined"),
            at(-5 * 86_400 + 10, "остановка, причина 1"),
            at(-3000, "запуск, ядро combined"),
            at(-2900, "[mem] занято 20.0 МиБ, пик 20.0 МиБ"),
            at(-2800, "[mem] занято 31.5 МиБ, пик 31.5 МиБ"),
            at(-2700, "[mem] занято 25.0 МиБ, пик 31.5 МиБ"),
            at(-2600, "[mem] занято 22.0 МиБ, пик 31.5 МиБ"),
            at(-2500, "остановка, причина 1"),
            at(-2000, "запуск не удался: нет сети"),
            at(-1000, "запуск, ядро combined"),
            at(-900, "[mem] занято 18.0 МиБ, пик 18.0 МиБ"),
            at(-800, "[mem] занято 19.0 МиБ, пик 19.0 МиБ"),
        ]
        let digest = TunnelEvents.digest(lines, now: now)
        XCTAssertEqual(digest, [lines[2], lines[4], lines[6], lines[7], lines[8], lines[9], lines[10], lines[11]])
        XCTAssertEqual(TunnelEvents.starts(lines).count, 4)
        XCTAssertEqual(TunnelEvents.digest(lines, now: now, sessions: 1), [lines[9], lines[10], lines[11]])
    }
}

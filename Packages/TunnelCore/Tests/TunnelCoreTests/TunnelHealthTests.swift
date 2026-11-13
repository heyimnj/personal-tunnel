import XCTest
@testable import TunnelCore

final class TunnelHealthTests: XCTestCase {
    func testEventsKeepTheLastLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0 ..< TunnelEvents.keep + 5 { TunnelEvents.append("line \(index)\nnext", to: url) }
        let lines = TunnelEvents.read(url)
        XCTAssertEqual(lines.count, TunnelEvents.keep)
        XCTAssertTrue(lines.first?.hasSuffix("line 5 next") ?? false)
        XCTAssertTrue(lines.last?.hasSuffix("line \(TunnelEvents.keep + 4) next") ?? false)
    }

    func testMemoryLineAndRoundTrip() {
        let sample = MemorySample(used: 21.44, peak: 25, available: 28.6, date: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(sample.line, "[mem] занято 21.4 МиБ, пик 25.0 МиБ, доступно 28.6 МиБ")
        XCTAssertEqual(MemorySample.decode(sample.encoded()), sample)
        XCTAssertFalse(sample.isNearLimit)
        XCTAssertTrue(MemorySample(used: 47, peak: 48, available: 2).isNearLimit)
        XCTAssertEqual(MemorySample(used: 1, peak: 2, available: 0).line, "[mem] занято 1.0 МиБ, пик 2.0 МиБ")
    }

    func testCrashCausePrefersCoreThenMemoryThenSystem() {
        let near = MemorySample(used: 47, peak: 48, available: 2)
        XCTAssertEqual(CrashReport.text(startedAt: nil, systemReason: "x", memory: near, events: [], coreCrash: "panic: boom").cause, "Ядро завершилось с ошибкой.")
        XCTAssertTrue(CrashReport.text(startedAt: nil, systemReason: "x", memory: near, events: [], coreCrash: nil).cause.contains("памяти"))
        XCTAssertEqual(CrashReport.text(startedAt: nil, systemReason: "x", memory: nil, events: [], coreCrash: nil).cause, "x")
        let report = CrashReport.text(startedAt: Date(), systemReason: nil, memory: near, events: ["a", "b"], coreCrash: "panic: boom")
        XCTAssertTrue(report.details.contains("panic: boom"))
        XCTAssertTrue(report.details.contains("a\nb"))
        XCTAssertTrue(report.details.contains("[mem]"))
    }
}

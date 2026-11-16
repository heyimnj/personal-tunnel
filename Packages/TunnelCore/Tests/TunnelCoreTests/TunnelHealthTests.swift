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

    /// 3.0.6: memory is sampled every 15 s but written only when it moves.
    func testMemoryLineIsWrittenWhenItMoves() {
        let start = Date(timeIntervalSince1970: 1_000)
        let logged = MemorySample(used: 30, peak: 31, available: 20, date: start)
        XCTAssertFalse(MemorySample(used: 30.6, peak: 31.5, available: 19.4, date: start.addingTimeInterval(15)).differs(from: logged))
        XCTAssertTrue(MemorySample(used: 31.2, peak: 31.5, available: 18.8, date: start.addingTimeInterval(15)).differs(from: logged))
        XCTAssertTrue(MemorySample(used: 30, peak: 32.1, available: 20, date: start.addingTimeInterval(15)).differs(from: logged))
        XCTAssertTrue(MemorySample(used: 30, peak: 31, available: 20, date: start.addingTimeInterval(600)).differs(from: logged))
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

    func testExpectedEnds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let line = { (offset: TimeInterval, text: String) -> String in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: start.addingTimeInterval(offset)) + " " + text
        }
        // An unexplained end is reported.
        XCTAssertFalse(CrashReport.isExpectedEnd(startedAt: start, startedBuild: "252", currentBuild: "252", bootTime: start.addingTimeInterval(-600),
                                                 events: [line(0, "запуск, ядро combined"), line(60, "[mem] used 30 MiB")]))
        // An update replaced the extension.
        XCTAssertTrue(CrashReport.isExpectedEnd(startedAt: start, startedBuild: "252", currentBuild: "253", bootTime: nil, events: []))
        // The device restarted after the start.
        XCTAssertTrue(CrashReport.isExpectedEnd(startedAt: start, startedBuild: nil, currentBuild: "253", bootTime: start.addingTimeInterval(60), events: []))
        // The extension logged its stop after this start.
        XCTAssertTrue(CrashReport.isExpectedEnd(startedAt: start, startedBuild: "253", currentBuild: "253", bootTime: nil,
                                                events: [line(0, "запуск, ядро combined"), line(30, "остановка, причина 9")]))
        // A stop before this start does not count.
        XCTAssertFalse(CrashReport.isExpectedEnd(startedAt: start, startedBuild: "253", currentBuild: "253", bootTime: nil,
                                                 events: [line(-30, "остановка, причина 1"), line(0, "запуск, ядро combined")]))
    }
}

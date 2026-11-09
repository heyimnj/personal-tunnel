@testable import TunnelKit
import XCTest

final class LatencyTests: XCTestCase {
    actor Collector {
        var samples: [UUID: [LatencySample]] = [:]
        func add(_ id: UUID, _ sample: LatencySample) { samples[id, default: []].append(sample) }
    }

    func testPrimaryModeFiltersByTCPBeforeURLTest() async {
        let reachable = LatencyTarget(id: UUID(), host: "ok", port: 443, isUDPBased: false, tunnelTag: "ok")
        let unreachable = LatencyTarget(id: UUID(), host: "down", port: 443, isUDPBased: false, tunnelTag: "down")
        let udp = LatencyTarget(id: UUID(), host: "hy", port: 443, isUDPBased: true, tunnelTag: "hy")
        let probes = LatencyProbes(
            tcp: { host, _, _ in host == "ok" ? 40 : nil },
            url: { tag, _ in tag == "hy" ? 90 : 120 }
        )
        let collector = Collector()
        await LatencyRunner.run([reachable, unreachable, udp], mode: .primary, priority: [], probes: probes) { id, sample in
            await collector.add(id, sample)
        }
        let samples = await collector.samples
        XCTAssertEqual(samples[reachable.id]?.map(\.kind), [.tcp, .url])
        XCTAssertEqual(samples[reachable.id]?.last?.milliseconds, 120)
        XCTAssertEqual(samples[unreachable.id]?.map(\.kind), [.tcp])
        XCTAssertNil(samples[unreachable.id]?.first?.milliseconds)
        XCTAssertEqual(samples[udp.id]?.map(\.kind), [.url])
    }

    func testWithoutTunnelOnlyTCP() async {
        let target = LatencyTarget(id: UUID(), host: "ok", port: 443, isUDPBased: false, tunnelTag: nil)
        let udp = LatencyTarget(id: UUID(), host: "hy", port: 443, isUDPBased: true, tunnelTag: nil)
        XCTAssertEqual(LatencyRunner.plan(for: target, mode: .classic), [.tcp])
        XCTAssertEqual(LatencyRunner.plan(for: udp, mode: .primary), [])
        XCTAssertEqual(LatencyRunner.plan(for: udp, mode: .alternative), [])
    }

    func testManyTargetsComplete() async {
        let targets = (0 ..< 200).map { LatencyTarget(id: UUID(), host: "h\($0)", port: 1, isUDPBased: $0 % 3 == 0, tunnelTag: "t\($0)") }
        let probes = LatencyProbes(
            tcp: { _, _, _ in
                try? await Task.sleep(nanoseconds: 1_000_000)
                return 10
            },
            url: { _, _ in
                try? await Task.sleep(nanoseconds: 1_000_000)
                return 20
            },
            urlConcurrency: { 3 }
        )
        let collector = Collector()
        await LatencyRunner.run(targets, mode: .primary, priority: [targets[199].id], probes: probes) { id, sample in
            await collector.add(id, sample)
        }
        let samples = await collector.samples
        XCTAssertEqual(samples.count, 200)
        XCTAssertTrue(samples.values.allSatisfy { $0.last?.kind == .url && $0.last?.milliseconds == 20 })
    }

    func testCancellationStopsQuickly() async {
        let targets = (0 ..< 50).map { LatencyTarget(id: UUID(), host: "h\($0)", port: 1, isUDPBased: false, tunnelTag: "t") }
        let probes = LatencyProbes(
            tcp: { _, _, _ in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return 10
            },
            url: { _, _ in 1 }
        )
        let started = Date()
        let task = Task {
            await LatencyRunner.run(targets, mode: .primary, priority: [], probes: probes) { _, _ in }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testUnstableDetection() {
        var record = LatencyRecord(sample: LatencySample(kind: .url, milliseconds: 100))
        XCTAssertFalse(record.isUnstable)
        record.add(LatencySample(kind: .url, milliseconds: 110))
        XCTAssertFalse(record.isUnstable)
        record.add(LatencySample(kind: .url, milliseconds: 300))
        XCTAssertTrue(record.isUnstable)
        var flaky = LatencyRecord(sample: LatencySample(kind: .url, milliseconds: 100))
        flaky.add(LatencySample(kind: .url, milliseconds: nil))
        XCTAssertTrue(flaky.isUnstable)
        XCTAssertEqual(LatencyRunner.urlConcurrency(forExtensionMemory: 45 * 1024 * 1024), 2)
    }
}

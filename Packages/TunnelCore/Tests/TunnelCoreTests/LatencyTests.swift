import XCTest
@testable import TunnelCore

private struct FakeProbes: LatencyProbes {
    var hang: Set<String> = []
    func tcp(host: String, port: Int, timeout: TimeInterval) async -> ProbeResult {
        if hang.contains(host) { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        return host.hasPrefix("dead") ? .failed(.refused) : .delay(port)
    }
    func url(tag: String, link: String, timeoutMs: Int) async -> ProbeResult { .delay(tag.count) }
}

/// Remembers the names the runner gives a direct probe for its log.
private final class LabelProbes: LatencyProbes, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String?] = []
    var labels: [String?] { lock.lock(); defer { lock.unlock() }; return seen }
    func tcp(host _: String, port _: Int, timeout _: TimeInterval) async -> ProbeResult { .failed(.other) }
    func tcp(host _: String, port _: Int, timeout _: TimeInterval, label: String?) async -> ProbeResult {
        lock.lock(); seen.append(label); lock.unlock()
        return .failed(.timeout)
    }
    func url(tag _: String, link _: String, timeoutMs _: Int) async -> ProbeResult { .delay(1) }
}

private actor Sink {
    var all: [String: ProbeResult] = [:]
    var batches = 0
    func add(_ r: [String: ProbeResult]) { all.merge(r) { $1 }; batches += 1 }
}

final class LatencyTests: XCTestCase {
    func testDirectRunMeasuresAndExplains() async {
        let sink = Sink()
        let runner = LatencyRunner(probes: FakeProbes())
        await runner.run([.init(tag: "a", host: "h", port: 42, udp: false), .init(tag: "b", host: "dead", port: 1, udp: false),
                          .init(tag: "c", host: "h", port: 1, udp: true), .init(tag: "d", host: nil, port: nil, udp: false)],
                         mode: .named(nil), tunnel: false) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .delay(42))
        XCTAssertEqual(all["b"], .failed(.refused))
        XCTAssertEqual(all["c"], .failed(.unsupported))
        XCTAssertEqual(all["d"], .failed(.noAddress))
    }

    func testTunnelRunFiltersThenURLTests() async {
        let sink = Sink()
        await LatencyRunner(probes: FakeProbes()).run([.init(tag: "abc", host: "h", port: 1, udp: false), .init(tag: "x", host: "dead", port: 1, udp: false)],
                                                      mode: .named("primary"), tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["abc"], .delay(3))
        XCTAssertEqual(all["x"], .failed(.refused))
    }

    func testDirectProbeGetsTheServerNameAndOneRetry() async {
        let probes = LabelProbes()
        let sink = Sink()
        await LatencyRunner(probes: probes).run([.init(tag: "1:a", host: "h", port: 1, udp: false, label: "США")],
                                                mode: .named(nil), tunnel: false) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["1:a"], .failed(.timeout))
        XCTAssertEqual(probes.labels, ["США", "США"])
    }

    func testHangingProbeEndsWithTimeout() async {
        let result = await LatencyRunner.deadline(seconds: 0.2) { try? await Task.sleep(nanoseconds: 30_000_000_000); return .delay(1) }
        XCTAssertEqual(result, .failed(.timeout))
    }

    func testCancelReturnsImmediately() async {
        let runner = LatencyRunner(probes: FakeProbes(hang: ["slow"]))
        let task = Task { await runner.run((0 ..< 30).map { .init(tag: "\($0)", host: "slow", port: 1, udp: false) }, mode: .named(nil), tunnel: false) { _ in } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        task.cancel()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testClassify() {
        XCTAssertEqual(ProbeFailure.classify("dial tcp: lookup x: no such host"), .dns)
        XCTAssertEqual(ProbeFailure.classify("context deadline exceeded"), .timeout)
        XCTAssertEqual(ProbeFailure.classify("reality verification failed"), .tls)
    }
}

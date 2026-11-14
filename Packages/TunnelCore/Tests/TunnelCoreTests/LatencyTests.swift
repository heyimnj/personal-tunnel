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

/// URL tests that time out a set number of times per server, then answer.
private final class ColdProbes: LatencyProbes, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    let coldFor: Int
    let failure: ProbeFailure
    init(coldFor: Int, failure: ProbeFailure = .timeout) { self.coldFor = coldFor; self.failure = failure }
    func count(_ tag: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[tag] ?? 0 }
    func tcp(host _: String, port _: Int, timeout _: TimeInterval) async -> ProbeResult { .delay(5) }
    func url(tag: String, link _: String, timeoutMs _: Int) async -> ProbeResult {
        lock.lock(); calls[tag, default: 0] += 1; let n = calls[tag]!; lock.unlock()
        return n <= coldFor ? .failed(failure) : .delay(120)
    }
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

    func testColdURLTestIsTriedOnceMore() async {
        let probes = ColdProbes(coldFor: 1)
        let sink = Sink()
        await LatencyRunner(probes: probes).run([.init(tag: "a", host: "h", port: 1, udp: false)],
                                                mode: .localCore(link: "https://x"), tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .delay(120))
        XCTAssertEqual(probes.count("a"), 2)
    }

    func testURLTestRetriesOnlyOnce() async {
        let probes = ColdProbes(coldFor: 5)
        let sink = Sink()
        await LatencyRunner(probes: probes).run([.init(tag: "a", host: "h", port: 1, udp: false)],
                                                mode: .named("primary"), tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .failed(.timeout))
        XCTAssertEqual(probes.count("a"), 2)
    }

    func testSlowRefusalIsNotRetried() async {
        let probes = ColdProbes(coldFor: 1, failure: .refused)
        let sink = Sink()
        var mode = LatencyMode.localCore(link: "https://x")
        mode.quickFailure = 0 // every failure counts as slow
        await LatencyRunner(probes: probes).run([.init(tag: "a", host: "h", port: 1, udp: false)],
                                                mode: mode, tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .failed(.refused))
        XCTAssertEqual(probes.count("a"), 1)
    }

    /// 3.0.5: a failure that comes back at once (a dead pooled connection) is
    /// tried again after a short pause, and the second answer counts.
    func testQuickFailureIsRetriedAfterAPause() async {
        let probes = ColdProbes(coldFor: 1, failure: .refused)
        let sink = Sink()
        let start = Date()
        await LatencyRunner(probes: probes).run([.init(tag: "a", host: "h", port: 1, udp: false)],
                                                mode: .localCore(link: "https://x"), tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .delay(120))
        XCTAssertEqual(probes.count("a"), 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
    }

    /// 3.0.6: a connection cut midway (EOF) is tried again even when it took long.
    func testSlowEOFIsRetried() async {
        let probes = ColdProbes(coldFor: 1, failure: .closed)
        let sink = Sink()
        var mode = LatencyMode.localCore(link: "https://x")
        mode.quickFailure = 0
        await LatencyRunner(probes: probes).run([.init(tag: "a", host: "h", port: 1, udp: false)],
                                                mode: mode, tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .delay(120))
        XCTAssertEqual(probes.count("a"), 2)
    }

    /// A certificate that is not accepted stays so: no second attempt.
    func testCertificateFailureIsNotRetried() async {
        let probes = ColdProbes(coldFor: 1, failure: .certificate)
        let sink = Sink()
        await LatencyRunner(probes: probes).run([.init(tag: "a", host: "h", port: 1, udp: false)],
                                                mode: .localCore(link: "https://x"), tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["a"], .failed(.certificate))
        XCTAssertEqual(probes.count("a"), 1)
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

    func testTLSNameForDirectProbes() throws {
        let reality = NodeAssembler.assemble([try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?security=reality&sni=www.apple.com&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=ab&type=tcp#R")])[0]
        XCTAssertEqual(reality.tlsServerName, "www.apple.com")
        let tlsByHost = NodeAssembler.assemble([try ShareLink.parse("trojan://pw@tr.example.com:443#T")])[0]
        XCTAssertEqual(tlsByHost.tlsServerName, "tr.example.com")
        let plain = NodeAssembler.assemble([try ShareLink.parse("ss://" + Data("aes-256-gcm:secret".utf8).base64EncodedString() + "@1.2.3.4:8388#SS")])[0]
        XCTAssertNil(plain.tlsServerName)
        let quic = NodeAssembler.assemble([try ShareLink.parse("hy2://pass@hy.example.com:443#H")])[0]
        XCTAssertNil(quic.tlsServerName)
    }

    func testTunnelRunTCPForAllThenURLForSurvivors() async {
        let sink = Sink()
        let targets: [LatencyRunner.Target] = [
            .init(tag: "ok", host: "h", port: 1, udp: false), .init(tag: "gone", host: "dead", port: 1, udp: false),
            .init(tag: "quic", host: "dead", port: 1, udp: true),
        ]
        await LatencyRunner(probes: FakeProbes()).run(targets, mode: .named("primary"), tunnel: true) { await sink.add($0) }
        let all = await sink.all
        XCTAssertEqual(all["ok"], .delay(2))       // URL test after the TCP pass
        XCTAssertEqual(all["gone"], .failed(.refused)) // TCP failure is final
        XCTAssertEqual(all["quic"], .delay(4))     // UDP goes straight to the URL test
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
        XCTAssertEqual(ProbeFailure.classify("tls: failed to verify certificate: x509: \u{201C}a.internal\u{201D} certificate is not standards compliant"), .certificate)
        XCTAssertEqual(ProbeFailure.classify("certificate pin: unrecognized server certificate 00ff"), .certificate)
        XCTAssertEqual(ProbeFailure.classify("timeout: no recent network activity"), .timeout)
        XCTAssertEqual(ProbeFailure.classify("EOF"), .closed)
        XCTAssertEqual(ProbeFailure.classify("read tcp 1.2.3.4:5->6.7.8.9:443: read: connection reset by peer"), .closed)
        XCTAssertEqual(ProbeFailure.classify("dial tcp 1.2.3.4:443: connect: connection refused"), .refused)
    }
}

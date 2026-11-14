import Foundation

/// Why a server did not answer. Stored with the result and shown in its row and the log.
public enum ProbeFailure: String, Codable, Sendable, Equatable {
    /// `certificate` (3.0.5): the server's certificate was not accepted — a
    /// self-signed server without its pin, or one that does not match. Shown
    /// apart from `tls`, which is a TLS/REALITY handshake that broke.
    /// `closed` (3.0.6): the connection was cut midway («EOF», «reset», «broken
    /// pipe») — most often a pooled one the server had already dropped; it is
    /// always tried once more.
    /// `reality` (3.1.0): a REALITY handshake that broke, apart from `tls` (both
    /// read «TLS/Reality» before, and TLS servers showed «Reality»).
    case dns, timeout, refused, tls, reality, certificate, unreachable, noAddress, unsupported, closed, other

    public var title: String {
        switch self {
        case .dns: return "DNS"
        case .timeout: return CoreText.t("таймаут")
        case .refused: return CoreText.t("отказ")
        case .tls: return "TLS"
        case .reality: return "Reality"
        case .certificate: return CoreText.t("сертификат")
        case .unreachable: return CoreText.t("нет маршрута")
        case .noAddress: return CoreText.t("нет адреса")
        case .unsupported: return CoreText.t("только с VPN")
        case .closed: return CoreText.t("обрыв")
        case .other: return CoreText.t("ошибка")
        }
    }

    /// Sorts an error text from the core or the system into a reason.
    public static func classify(_ text: String) -> ProbeFailure {
        let t = text.lowercased()
        if t.contains("timeout") || t.contains("timed out") || t.contains("deadline") { return .timeout }
        if t.contains("x509") || t.contains("certificate") { return .certificate }
        if t.contains("no such host") || t.contains("lookup") || t.contains("dns") || t.contains("nxdomain") { return .dns }
        if t.contains("refused") { return .refused }
        if t.contains("eof") || t.contains("reset") || t.contains("broken pipe") || t.contains("connection closed")
            || t.contains("closed network connection") { return .closed }
        if t.contains("reality") { return .reality }
        if t.contains("tls") || t.contains("handshake") { return .tls }
        if t.contains("unreachable") || t.contains("no route") || t.contains("network is down") { return .unreachable }
        return .other
    }
}

public enum ProbeResult: Codable, Sendable, Equatable {
    case delay(Int)
    case failed(ProbeFailure)

    public var milliseconds: Int? {
        if case let .delay(value) = self { return value }
        return nil
    }
}

public struct LatencyMode: Equatable, Sendable {
    public var tcpFilter: Bool
    public var directTimeout: TimeInterval
    public var directConcurrency: Int
    public var urlTimeoutMs: Int
    public var urlConcurrency: Int
    public var link: String
    /// A URL test that failed sooner than this (seconds) most likely met a
    /// connection that was already gone (a pooled QUIC, gRPC or XHTTP one): it is
    /// tried again after a short pause, whatever the reason (3.0.5).
    public var quickFailure: TimeInterval = 1
    /// 3.1.0: the URL test runs in two waves. The first gives every server this
    /// long (ms): a server that answers at all answers well within it. Those
    /// that stay silent get a second, longer try (`urlTimeoutMs`) once the first
    /// wave is through, `retryConcurrency` at a time — unless they were silent
    /// in the previous test as well. A list of 200 servers, most of them dead,
    /// took minutes when each dead one cost two full timeouts in turn.
    public var firstTimeoutMs = 2500
    public var retryConcurrency = 0

    /// The app's own core without the VPN (3.0): a URL test of every server,
    /// 4 s each (3.0.3, was 3: a cold first test spends most of it finding the
    /// server's address), 10 at a time, at the address the chosen mode uses.
    /// 3.1.0: 32 at a time, the retries 48 (a silent server costs the app
    /// nothing but a waiting socket); was 10.
    public static func localCore(link: String) -> LatencyMode {
        LatencyMode(tcpFilter: false, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 4000, urlConcurrency: 32, link: link,
                    firstTimeoutMs: 2500, retryConcurrency: 48)
    }

    /// «Основной», «Классика», «Альтернативный» — параметры 1.5.0.
    public static func named(_ name: String?) -> LatencyMode {
        switch name {
        // Through the tunnel the tests run in the extension (about 50 MiB): its
        // first wave stays at 1.5.0's numbers, only the retries, mostly silent
        // servers, go wider.
        case "classic": return LatencyMode(tcpFilter: false, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 5000, urlConcurrency: 8, link: "https://www.gstatic.com/generate_204",
                                           firstTimeoutMs: 3000, retryConcurrency: 12)
        case "alternative": return LatencyMode(tcpFilter: false, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 2500, urlConcurrency: 12, link: "http://www.gstatic.com/generate_204",
                                               firstTimeoutMs: 2500, retryConcurrency: 16)
        default: return LatencyMode(tcpFilter: true, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 4000, urlConcurrency: 20, link: "https://www.gstatic.com/generate_204",
                                    firstTimeoutMs: 2500, retryConcurrency: 28)
        }
    }
}

/// Measurement backends, injected so the runner is testable.
public protocol LatencyProbes: Sendable {
    /// TCP connect straight to the server, outside the tunnel.
    func tcp(host: String, port: Int, timeout: TimeInterval) async -> ProbeResult
    /// The same, with the server's name for the log.
    func tcp(host: String, port: Int, timeout: TimeInterval, label: String?) async -> ProbeResult
    /// A TLS handshake with `serverName` (SNI) instead of a bare connect, when given.
    func handshake(host: String, port: Int, serverName: String?, timeout: TimeInterval, label: String?) async -> ProbeResult
    /// URL test through the running tunnel's outbound.
    func url(tag: String, link: String, timeoutMs: Int) async -> ProbeResult
}

public extension LatencyProbes {
    func tcp(host: String, port: Int, timeout: TimeInterval, label _: String?) async -> ProbeResult {
        await tcp(host: host, port: port, timeout: timeout)
    }

    func handshake(host: String, port: Int, serverName _: String?, timeout: TimeInterval, label: String?) async -> ProbeResult {
        await tcp(host: host, port: port, timeout: timeout, label: label)
    }
}

/// Runs one latency test. Every probe has a hard deadline, the whole run is
/// cancellable at once, and results arrive in batches.
public actor LatencyRunner {
    public struct Target: Sendable, Hashable {
        public var tag: String
        public var host: String?
        public var port: Int?
        public var udp: Bool
        /// The server's name, for the log (never its address).
        public var label: String?
        /// SNI for a TLS handshake probe; nil probes with a bare TCP connect.
        public var tlsName: String?
        /// The server did not answer the previous test either (3.1.0): a silent
        /// first wave is then its result, without a second try.
        public var silentBefore: Bool
        public init(tag: String, host: String?, port: Int?, udp: Bool, label: String? = nil, tlsName: String? = nil, silentBefore: Bool = false) {
            self.tag = tag; self.host = host; self.port = port; self.udp = udp; self.label = label; self.tlsName = tlsName
            self.silentBefore = silentBefore
        }
    }

    private let probes: LatencyProbes
    public init(probes: LatencyProbes) { self.probes = probes }

    /// `tunnel`: the tags can be URL-tested (their subscription runs in the tunnel).
    /// With the tunnel and a TCP filter (the primary mode) the test runs in two
    /// passes, as 1.5.0 did: first a quick TCP connect to every server at once
    /// (those that fail get their result straight away), then the URL test only
    /// through the servers that answered. UDP protocols go straight to the URL test.
    public func run(_ targets: [Target], mode: LatencyMode, tunnel: Bool,
                    deliver: @escaping @Sendable ([String: ProbeResult]) async -> Void) async
    {
        guard tunnel else {
            await pass(targets, concurrency: mode.directConcurrency, deliver: deliver) { [probes] target in
                await LatencyRunner.measure(target, probes: probes, mode: mode, tunnel: false)
            }
            return
        }
        guard mode.tcpFilter else {
            await urlWaves(targets, mode: mode, deliver: deliver)
            return
        }
        let filtered = targets.filter { !$0.udp && $0.host != nil && $0.port != nil }
        let survivors = SurvivorBox()
        await pass(filtered, concurrency: max(mode.urlConcurrency, mode.directConcurrency), deliver: { results in
            // Only failures are final here; answers wait for their URL test.
            let failed = results.filter { if case .failed = $0.value { return true }; return false }
            if !failed.isEmpty { await deliver(failed) }
        }) { [probes] target in
            var result = await LatencyRunner.deadline(seconds: 2) {
                await probes.tcp(host: target.host ?? "", port: target.port ?? 0, timeout: 1.5, label: target.label)
            }
            // A quick connect that only ran out of time gets one more try before the
            // server is written off.
            if LatencyRunner.worthRetry(result), !Task.isCancelled {
                result = await LatencyRunner.deadline(seconds: 2) {
                    await probes.tcp(host: target.host ?? "", port: target.port ?? 0, timeout: 1.5, label: target.label)
                }
            }
            if case .delay = result { await survivors.add(target.tag) }
            return result
        }
        guard !Task.isCancelled else { return }
        let passed = await survivors.tags
        let second = targets.filter { $0.udp || $0.host == nil || $0.port == nil || passed.contains($0.tag) }
        await urlWaves(second, mode: mode, deliver: deliver)
    }

    /// The URL test in two waves (3.1.0, see `LatencyMode.firstTimeoutMs`). Results
    /// of the first wave arrive as they come, except silence that gets a second
    /// try; the second wave runs once the first is through.
    private func urlWaves(_ targets: [Target], mode: LatencyMode, deliver: @escaping @Sendable ([String: ProbeResult]) async -> Void) async {
        let later = SurvivorBox()
        let first = min(mode.firstTimeoutMs, mode.urlTimeoutMs)
        let twoWaves = first < mode.urlTimeoutMs
        await pass(targets, concurrency: mode.urlConcurrency, deliver: { results in
            var now = results
            for tag in await later.tags { now[tag] = nil }
            if !now.isEmpty { await deliver(now) }
        }) { [probes] target in
            let result = await LatencyRunner.urlTest(target, probes: probes, mode: mode, timeoutMs: first)
            if LatencyRunner.worthRetry(result), !target.silentBefore, !Task.isCancelled {
                // Not delivered: the second wave decides.
                await later.add(target.tag)
            }
            return result
        }
        guard !Task.isCancelled else { return }
        let silent = await later.tags
        guard !silent.isEmpty else { return }
        let retry = targets.filter { silent.contains($0.tag) }
        await pass(retry, concurrency: max(mode.urlConcurrency, mode.retryConcurrency), deliver: deliver) { [probes] target in
            // Warmed up by the first try; with one timeout only, the second wave
            // is the same try once more.
            await LatencyRunner.urlTest(target, probes: probes, mode: mode, timeoutMs: twoWaves ? mode.urlTimeoutMs : first)
        }
    }

    private actor SurvivorBox {
        var tags = Set<String>()
        func add(_ tag: String) { tags.insert(tag) }
    }

    /// Runs `probe` over the targets, `concurrency` at a time, delivering in batches.
    private func pass(_ targets: [Target], concurrency: Int, deliver: @escaping @Sendable ([String: ProbeResult]) async -> Void,
                      probe: @escaping @Sendable (Target) async -> ProbeResult) async
    {
        var pending = targets[...]
        var buffer: [String: ProbeResult] = [:]
        var lastFlush = Date()
        await withTaskGroup(of: (String, ProbeResult).self) { group in
            func next() -> Bool {
                guard let target = pending.popFirst() else { return false }
                group.addTask { (target.tag, await probe(target)) }
                return true
            }
            for _ in 0 ..< concurrency { if !next() { break } }
            while let (tag, result) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                buffer[tag] = result
                if Date().timeIntervalSince(lastFlush) > 0.5 {
                    await deliver(buffer); buffer = [:]; lastFlush = Date()
                }
                _ = next()
            }
        }
        if !buffer.isEmpty, !Task.isCancelled { await deliver(buffer) }
    }

    /// A first test through a server is often cold: the core still has to find the
    /// server's address and open every layer of the connection. One that runs out
    /// of time (or trips on that lookup) is tried once more at once, warmed up; a
    /// second answer that comes is the real delay. A connection cut midway
    /// (EOF, reset) is tried again too, however long it took (3.0.6).
    static func worthRetry(_ result: ProbeResult) -> Bool {
        if case let .failed(reason) = result { return reason == .timeout || reason == .dns || reason == .closed }
        return false
    }

    /// Failures that a second attempt cannot change: the certificate stays the
    /// same, and a server without an address or a protocol the probe cannot run
    /// stays that way.
    static func isFinal(_ reason: ProbeFailure) -> Bool {
        reason == .certificate || reason == .noAddress || reason == .unsupported
    }

    /// One URL test of `timeoutMs`, tried again at once when the connection was
    /// cut, or when it came back immediately with an error (3.0.5–3.0.6: a pooled
    /// connection that was already dead answers «reset» at once, and the very
    /// next test opens a fresh one). Silence and a failed lookup are not retried
    /// here: the second wave does that (3.1.0).
    static func urlTest(_ target: Target, probes: LatencyProbes, mode: LatencyMode, timeoutMs: Int) async -> ProbeResult {
        let once: () async -> ProbeResult = {
            await deadline(seconds: Double(timeoutMs) / 1000 + 1) {
                await probes.url(tag: target.tag, link: mode.link, timeoutMs: timeoutMs)
            }
        }
        let start = Date()
        let first = await once()
        guard case let .failed(reason) = first, !isFinal(reason), !Task.isCancelled else { return first }
        let quick = Date().timeIntervalSince(start) < mode.quickFailure
        guard reason == .closed || (quick && reason != .timeout && reason != .dns) else { return first }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return first }
        return await once()
    }

    static func measure(_ target: Target, probes: LatencyProbes, mode: LatencyMode, tunnel: Bool) async -> ProbeResult {
        if tunnel { return await urlTest(target, probes: probes, mode: mode, timeoutMs: mode.urlTimeoutMs) }
        // Without the VPN: a quick TCP connect with one retry, as 1.5.0 did.
        guard !target.udp else { return .failed(.unsupported) }
        guard let host = target.host, let port = target.port else { return .failed(.noAddress) }
        let label = target.label
        var result = await deadline(seconds: mode.directTimeout + 1) { await probes.tcp(host: host, port: port, timeout: mode.directTimeout, label: label) }
        if case .failed = result, !Task.isCancelled {
            result = await deadline(seconds: mode.directTimeout + 1) { await probes.tcp(host: host, port: port, timeout: mode.directTimeout, label: label) }
        }
        return result
    }

    /// Guarantees an answer: a probe that hangs counts as a timeout.
    public static func deadline(seconds: TimeInterval, _ work: @escaping @Sendable () async -> ProbeResult) async -> ProbeResult {
        await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return Task.isCancelled ? nil : .failed(.timeout)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed(.timeout)
        }
    }
}

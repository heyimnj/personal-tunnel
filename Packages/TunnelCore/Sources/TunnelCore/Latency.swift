import Foundation

/// Why a server did not answer. Stored with the result and shown in its row and the log.
public enum ProbeFailure: String, Codable, Sendable, Equatable {
    case dns, timeout, refused, tls, unreachable, noAddress, unsupported, other

    public var title: String {
        switch self {
        case .dns: return "DNS"
        case .timeout: return "таймаут"
        case .refused: return "отказ"
        case .tls: return "TLS/Reality"
        case .unreachable: return "нет маршрута"
        case .noAddress: return "нет адреса"
        case .unsupported: return "только с VPN"
        case .other: return "ошибка"
        }
    }

    /// Sorts an error text from the core or the system into a reason.
    public static func classify(_ text: String) -> ProbeFailure {
        let t = text.lowercased()
        if t.contains("timeout") || t.contains("timed out") || t.contains("deadline") { return .timeout }
        if t.contains("no such host") || t.contains("lookup") || t.contains("dns") || t.contains("nxdomain") { return .dns }
        if t.contains("refused") || t.contains("reset") { return .refused }
        if t.contains("tls") || t.contains("reality") || t.contains("certificate") || t.contains("handshake") { return .tls }
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

    /// «Основной», «Классика», «Альтернативный» — параметры 1.5.0.
    public static func named(_ name: String?) -> LatencyMode {
        switch name {
        case "classic": return LatencyMode(tcpFilter: false, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 5000, urlConcurrency: 8, link: "https://www.gstatic.com/generate_204")
        case "alternative": return LatencyMode(tcpFilter: false, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 2500, urlConcurrency: 12, link: "http://www.gstatic.com/generate_204")
        default: return LatencyMode(tcpFilter: true, directTimeout: 3, directConcurrency: 10, urlTimeoutMs: 3000, urlConcurrency: 20, link: "https://www.gstatic.com/generate_204")
        }
    }
}

/// Measurement backends, injected so the runner is testable.
public protocol LatencyProbes: Sendable {
    /// TCP connect straight to the server, outside the tunnel.
    func tcp(host: String, port: Int, timeout: TimeInterval) async -> ProbeResult
    /// URL test through the running tunnel's outbound.
    func url(tag: String, link: String, timeoutMs: Int) async -> ProbeResult
}

/// Runs one latency test. Every probe has a hard deadline, the whole run is
/// cancellable at once, and results arrive in batches.
public actor LatencyRunner {
    public struct Target: Sendable, Hashable {
        public var tag: String
        public var host: String?
        public var port: Int?
        public var udp: Bool
        public init(tag: String, host: String?, port: Int?, udp: Bool) {
            self.tag = tag; self.host = host; self.port = port; self.udp = udp
        }
    }

    private let probes: LatencyProbes
    public init(probes: LatencyProbes) { self.probes = probes }

    /// `tunnel`: the tags can be URL-tested (their subscription runs in the tunnel).
    public func run(_ targets: [Target], mode: LatencyMode, tunnel: Bool,
                    deliver: @escaping @Sendable ([String: ProbeResult]) async -> Void) async
    {
        let concurrency = tunnel ? mode.urlConcurrency : mode.directConcurrency
        var pending = targets[...]
        var buffer: [String: ProbeResult] = [:]
        var lastFlush = Date()
        await withTaskGroup(of: (String, ProbeResult).self) { group in
            func next() -> Bool {
                guard let target = pending.popFirst() else { return false }
                group.addTask { [probes] in
                    (target.tag, await LatencyRunner.measure(target, probes: probes, mode: mode, tunnel: tunnel))
                }
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

    static func measure(_ target: Target, probes: LatencyProbes, mode: LatencyMode, tunnel: Bool) async -> ProbeResult {
        if tunnel {
            if mode.tcpFilter, !target.udp, let host = target.host, let port = target.port {
                if case let .failed(reason) = await deadline(seconds: 2) { await probes.tcp(host: host, port: port, timeout: 1.5) } {
                    return .failed(reason)
                }
            }
            return await deadline(seconds: Double(mode.urlTimeoutMs) / 1000 + 1) {
                await probes.url(tag: target.tag, link: mode.link, timeoutMs: mode.urlTimeoutMs)
            }
        }
        guard !target.udp else { return .failed(.unsupported) }
        guard let host = target.host, let port = target.port else { return .failed(.noAddress) }
        var result = await deadline(seconds: mode.directTimeout + 1) { await probes.tcp(host: host, port: port, timeout: mode.directTimeout) }
        if case .failed = result, !Task.isCancelled {
            result = await deadline(seconds: mode.directTimeout + 1) { await probes.tcp(host: host, port: port, timeout: mode.directTimeout) }
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

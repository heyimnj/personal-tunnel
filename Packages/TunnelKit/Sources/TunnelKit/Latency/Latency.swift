import Foundation

/// How server latency is measured.
public enum PingMode: String, Codable, CaseIterable, Sendable {
    /// TCP connect filter (bypassing the tunnel), then a URL test through each
    /// reachable server. Shows delay only; never switches servers.
    case primary
    /// URL test through every server while the tunnel runs, TCP otherwise.
    case classic
    /// TCP connect time only.
    case alternative
}

public enum LatencyKind: String, Codable, Sendable {
    case tcp
    case url
}

/// One measurement.
public struct LatencySample: Codable, Hashable, Sendable {
    public var kind: LatencyKind
    /// `nil` means the server did not answer in time.
    public var milliseconds: Int?
    public var date: Date

    public init(kind: LatencyKind, milliseconds: Int?, date: Date = Date()) {
        self.kind = kind
        self.milliseconds = milliseconds
        self.date = date
    }
}

/// The recent measurements of one server.
public struct LatencyRecord: Codable, Hashable, Sendable {
    public static let freshness: TimeInterval = 150
    public static let historyLength = 4

    public var latest: LatencySample
    /// Recent URL-test samples, newest last.
    public var history: [LatencySample]

    public init(sample: LatencySample) {
        latest = sample
        history = sample.kind == .url ? [sample] : []
    }

    public mutating func add(_ sample: LatencySample) {
        latest = sample
        if sample.kind == .url {
            history.append(sample)
            if history.count > LatencyRecord.historyLength { history.removeFirst(history.count - LatencyRecord.historyLength) }
        }
    }

    public var milliseconds: Int? { latest.milliseconds }
    public var failed: Bool { latest.milliseconds == nil }

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(latest.date) < LatencyRecord.freshness
    }

    /// Spread of the recent URL tests above half of their mean, or some of
    /// them unanswered.
    public var isUnstable: Bool {
        guard history.count >= 2 else { return false }
        let values = history.compactMap(\.milliseconds)
        if values.count < history.count { return !values.isEmpty }
        guard let low = values.min(), let high = values.max() else { return false }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        return mean > 0 && Double(high - low) > mean * 0.5
    }
}

/// What to measure for one server.
public struct LatencyTarget: Hashable, Sendable {
    public var id: UUID
    public var host: String
    public var port: Int
    public var isUDPBased: Bool
    /// The outbound tag when the server is part of the running tunnel.
    public var tunnelTag: String?

    public init(id: UUID, host: String, port: Int, isUDPBased: Bool, tunnelTag: String?) {
        self.id = id
        self.host = host
        self.port = port
        self.isUDPBased = isUDPBased
        self.tunnelTag = tunnelTag
    }
}

public struct LatencyProbes: Sendable {
    public var tcp: @Sendable (_ host: String, _ port: Int, _ timeout: TimeInterval) async -> Int?
    public var url: @Sendable (_ tag: String, _ timeoutMilliseconds: Int) async -> Int?
    /// Current URL-test concurrency; lowered when the extension's memory grows.
    public var urlConcurrency: @Sendable () -> Int

    public init(
        tcp: @escaping @Sendable (String, Int, TimeInterval) async -> Int?,
        url: @escaping @Sendable (String, Int) async -> Int?,
        urlConcurrency: @escaping @Sendable () -> Int = { LatencyRunner.urlConcurrency }
    ) {
        self.tcp = tcp
        self.url = url
        self.urlConcurrency = urlConcurrency
    }
}

/// Runs a latency test over many servers with bounded concurrency. Results
/// stream out as they arrive; cancelling the task stops it at once.
public enum LatencyRunner {
    public static let tcpTimeout: TimeInterval = 1.5
    public static let urlTimeoutMilliseconds = 3000
    public static let tcpConcurrency = 30
    public static let urlConcurrency = 20

    /// URL-test concurrency for an extension using `memoryBytes`. iOS kills
    /// packet tunnels at about 50 MiB.
    public static func urlConcurrency(forExtensionMemory memoryBytes: Int64) -> Int {
        let mib = memoryBytes / (1024 * 1024)
        switch mib {
        case ..<28: return 20
        case ..<34: return 14
        case ..<40: return 8
        default: return 2
        }
    }

    /// The stages a server goes through in `mode`.
    public static func plan(for target: LatencyTarget, mode: PingMode) -> [LatencyKind] {
        let canURL = target.tunnelTag != nil
        switch mode {
        case .primary:
            if target.isUDPBased { return canURL ? [.url] : [] }
            return canURL ? [.tcp, .url] : [.tcp]
        case .classic:
            if canURL { return [.url] }
            return target.isUDPBased ? [] : [.tcp]
        case .alternative:
            return target.isUDPBased ? [] : [.tcp]
        }
    }

    /// Orders targets so the ones in `priority` (visible, favourite,
    /// selected) are measured first.
    public static func ordered(_ targets: [LatencyTarget], priority: Set<UUID>) -> [LatencyTarget] {
        let first = targets.filter { priority.contains($0.id) }
        let rest = targets.filter { !priority.contains($0.id) }
        return first + rest
    }

    /// Measures `targets` and reports each sample through `report` (called on
    /// an arbitrary task). Returns when everything finished or was cancelled.
    public static func run(
        _ targets: [LatencyTarget],
        mode: PingMode,
        priority: Set<UUID>,
        probes: LatencyProbes,
        report: @escaping @Sendable (UUID, LatencySample) async -> Void
    ) async {
        let ordered = ordered(targets, priority: priority)
        let tcpTargets = ordered.filter { plan(for: $0, mode: mode).first == .tcp }
        let directURL = ordered.filter { plan(for: $0, mode: mode).first == .url }
        let urlQueue = URLQueue(initial: directURL)

        await withTaskGroup(of: Void.self) { group in
            // Stage 1: TCP connect, bypassing the tunnel.
            group.addTask {
                await forEach(tcpTargets, concurrency: tcpConcurrency) { target in
                    let rtt = await probes.tcp(target.host, target.port, tcpTimeout)
                    guard !Task.isCancelled else { return }
                    await report(target.id, LatencySample(kind: .tcp, milliseconds: rtt))
                    if rtt != nil, plan(for: target, mode: mode).contains(.url) {
                        await urlQueue.push(target)
                    }
                }
                await urlQueue.finishProducing()
            }
            // Stage 2: URL test through the server inside the running tunnel.
            group.addTask {
                await withTaskGroup(of: Void.self) { workers in
                    var running = 0
                    while !Task.isCancelled {
                        let limit = max(1, probes.urlConcurrency())
                        if running >= limit {
                            _ = await workers.next()
                            running -= 1
                            continue
                        }
                        guard let target = await urlQueue.pop(wait: running == 0) else {
                            if running == 0, await urlQueue.isFinished { break }
                            if running > 0 {
                                _ = await workers.next()
                                running -= 1
                            }
                            continue
                        }
                        running += 1
                        workers.addTask {
                            guard let tag = target.tunnelTag else { return }
                            let delay = await probes.url(tag, urlTimeoutMilliseconds)
                            guard !Task.isCancelled else { return }
                            await report(target.id, LatencySample(kind: .url, milliseconds: delay))
                        }
                    }
                    workers.cancelAll()
                }
            }
        }
    }

    static func forEach(_ items: [LatencyTarget], concurrency: Int, _ body: @escaping @Sendable (LatencyTarget) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            var running = 0
            while !Task.isCancelled, let item = iterator.next() {
                if running >= concurrency {
                    _ = await group.next()
                    running -= 1
                }
                running += 1
                group.addTask { await body(item) }
            }
            if Task.isCancelled { group.cancelAll() }
        }
    }
}

/// Hands TCP-stage survivors to the URL stage.
actor URLQueue {
    private var items: [LatencyTarget]
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(initial: [LatencyTarget]) {
        items = initial
    }

    var isFinished: Bool { finished && items.isEmpty }

    func push(_ target: LatencyTarget) {
        items.append(target)
        wake()
    }

    func finishProducing() {
        finished = true
        wake()
    }

    private func wake() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// The next target; with `wait`, suspends until one arrives or the
    /// producer finishes.
    func pop(wait: Bool) async -> LatencyTarget? {
        while items.isEmpty {
            if finished || !wait || Task.isCancelled { return nil }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return items.removeFirst()
    }
}

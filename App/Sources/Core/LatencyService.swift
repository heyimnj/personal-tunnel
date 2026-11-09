import Foundation
import Libbox
import Network
import Observation
import TunnelKit

/// Runs latency tests and keeps the results for 2.5 minutes.
@MainActor
@Observable
final class LatencyService {
    private(set) var records: [UUID: LatencyRecord] = [:]
    private(set) var testing: Set<UUID> = []
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var lastFinished: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onFinish: (() -> Void)?

    func record(_ id: UUID) -> LatencyRecord? { records[id] }

    func milliseconds(_ id: UUID) -> Int? { records[id]?.milliseconds }

    /// Starts a test. Fresh results are kept unless `force` is set.
    func run(_ targets: [LatencyTarget], mode: PingMode, priority: Set<UUID>, force: Bool, memory: AtomicInt64) {
        cancel()
        let now = Date()
        let pending = force ? targets : targets.filter { records[$0.id]?.isFresh(now: now) != true }
        guard !pending.isEmpty else {
            lastFinished = now
            return
        }
        isRunning = true
        completed = 0
        total = pending.count
        testing = Set(pending.map(\.id))
        let probes = LatencyProbes(
            tcp: { host, port, timeout in await Probe.tcp(host: host, port: port, timeout: timeout) },
            url: { tag, timeout in await Probe.url(tag: tag, timeoutMilliseconds: timeout) },
            urlConcurrency: { LatencyRunner.urlConcurrency(forExtensionMemory: memory.value) }
        )
        let plans = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, LatencyRunner.plan(for: $0, mode: mode)) })
        let sink = LatencySink(owner: self)
        task = Task {
            await LatencyRunner.run(pending, mode: mode, priority: priority, probes: probes) { id, sample in
                await sink.store(id, sample, finalStage: plans[id]?.last ?? .tcp)
            }
            if !Task.isCancelled { sink.finish() }
        }
        // Servers with nothing to measure (UDP without a running tunnel).
        for target in pending where plans[target.id]?.isEmpty == true {
            testing.remove(target.id)
            completed += 1
        }
    }

    fileprivate func store(_ id: UUID, _ sample: LatencySample, finalStage: LatencyKind) {
        if var record = records[id] {
            record.add(sample)
            records[id] = record
        } else {
            records[id] = LatencyRecord(sample: sample)
        }
        // A server is done after its last stage, or when the TCP filter failed.
        if sample.kind == finalStage || (sample.kind == .tcp && sample.milliseconds == nil) {
            if testing.remove(id) != nil { completed += 1 }
        }
    }

    fileprivate func finish() {
        isRunning = false
        testing.removeAll()
        task = nil
        lastFinished = Date()
        NetworkActivityLog.record(NetworkActivityEntry(
            purpose: L("Проверка задержки"),
            method: "TCP / URL",
            target: "\(total) " + L("серверов"),
            headers: [],
            outcome: L("завершено")
        ))
        onFinish?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning {
            isRunning = false
            testing.removeAll()
            lastFinished = Date()
        }
    }

    func clear() {
        cancel()
        records.removeAll()
    }

    /// The fastest stable server with a fresh URL test.
    func best(among ids: [UUID]) -> UUID? {
        let now = Date()
        return ids
            .compactMap { id -> (UUID, Int)? in
                guard let record = records[id], record.isFresh(now: now), record.latest.kind == .url,
                      let value = record.milliseconds, !record.isUnstable else { return nil }
                return (id, value)
            }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Delivers results from the test task to the service on the main actor.
@MainActor
private final class LatencySink {
    weak var owner: LatencyService?

    init(owner: LatencyService) {
        self.owner = owner
    }

    func store(_ id: UUID, _ sample: LatencySample, finalStage: LatencyKind) {
        owner?.store(id, sample, finalStage: finalStage)
    }

    func finish() {
        owner?.finish()
    }
}

/// The two kinds of measurement.
enum Probe {
    /// TCP connect time to the server, never through the tunnel.
    static func tcp(host: String, port: Int, timeout: TimeInterval) async -> Int? {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        let started = DispatchTime.now()
        let gate = ResumeGate<Int?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                        gate.resume(max(1, elapsed))
                        connection.cancel()
                    case .failed, .cancelled:
                        gate.resume(nil)
                    case .waiting:
                        gate.resume(nil)
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: Probe.queue)
                Probe.queue.asyncAfter(deadline: .now() + timeout) {
                    gate.resume(nil)
                    connection.cancel()
                }
            }
        } onCancel: {
            gate.resume(nil)
            connection.cancel()
        }
    }

    /// generate_204 through the server inside the running tunnel. The Libbox
    /// call blocks, so it runs on its own queue and is abandoned on cancel.
    static func url(tag: String, timeoutMilliseconds: Int) async -> Int? {
        let gate = ResumeGate<Int?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                Probe.urlQueue.async {
                    guard let client = LibboxNewStandaloneCommandClient() else {
                        gate.resume(nil)
                        return
                    }
                    var delay: Int?
                    if let result = try? client.urlTestOutbound(tag, link: Probe.testURL, timeout: Int32(timeoutMilliseconds)),
                       result.error.isEmpty, result.delay > 0
                    {
                        delay = Int(result.delay)
                    }
                    gate.resume(delay)
                }
            }
        } onCancel: {
            gate.resume(nil)
        }
    }

    static let testURL = "https://www.gstatic.com/generate_204"
    static let queue = DispatchQueue(label: "personaltunnel.tcp-probe", attributes: .concurrent)
    static let urlQueue = DispatchQueue(label: "personaltunnel.url-probe", attributes: .concurrent)
}

/// Resumes a continuation exactly once, whichever side finishes first.
final class ResumeGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var done = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if done, let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        if done {
            lock.unlock()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            pending = value
            lock.unlock()
        }
    }
}

import Foundation
import Libbox
import Network
import TunnelCore

/// Real probes: a TCP connect outside the tunnel and the core's URL test.
struct NetworkProbes: LatencyProbes {
    private static let blocking = DispatchQueue(label: "personaltunnel.url-test", qos: .utility, attributes: .concurrent)

    func tcp(host: String, port: Int, timeout: TimeInterval) async -> ProbeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed(.noAddress) }
        let parameters = NWParameters.tcp
        // Never through a VPN interface: the point is to reach the server directly.
        parameters.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let box = ResultBox()
        let start = DispatchTime.now()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
                box.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                        box.finish(.delay(max(1, Int(elapsed))), connection)
                    case let .failed(error):
                        box.finish(.failed(NetworkProbes.reason(error)), connection)
                    case let .waiting(error):
                        // DNS or the path may still come up: remember why, keep waiting.
                        box.pending = NetworkProbes.reason(error)
                    case .cancelled:
                        box.finish(.failed(box.pending ?? .timeout), connection)
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    box.finish(.failed(box.pending ?? .timeout), connection)
                }
            }
        } onCancel: {
            box.finish(.failed(.timeout), connection)
        }
    }

    private static func reason(_ error: NWError) -> ProbeFailure {
        switch error {
        case .dns: return .dns
        case .tls: return .tls
        case let .posix(code):
            switch code {
            case .ECONNREFUSED, .ECONNRESET: return .refused
            case .ETIMEDOUT: return .timeout
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN: return .unreachable
            default: return .other
            }
        default: return .other
        }
    }

    func url(tag: String, link: String, timeoutMs: Int) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            NetworkProbes.blocking.async {
                guard let client = LibboxNewStandaloneCommandClient() else {
                    continuation.resume(returning: .failed(.other))
                    return
                }
                do {
                    let result = try client.urlTestOutbound(tag, link: link, timeout: Int32(timeoutMs))
                    if result.error.isEmpty {
                        continuation.resume(returning: .delay(max(1, Int(result.delay))))
                    } else {
                        continuation.resume(returning: .failed(ProbeFailure.classify(result.error)))
                    }
                } catch {
                    continuation.resume(returning: .failed(ProbeFailure.classify(error.localizedDescription)))
                }
            }
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var continuation: CheckedContinuation<ProbeResult, Never>?
    var pending: ProbeFailure?

    func finish(_ result: ProbeResult, _ connection: NWConnection) {
        lock.lock()
        let first = !done
        done = true
        let target = continuation
        continuation = nil
        lock.unlock()
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        target?.resume(returning: result)
    }
}

struct LatencyEntry: Equatable {
    var result: ProbeResult
    var date: Date
}

struct LatencyProgress: Equatable {
    var running = false
    var done = 0
    var total = 0
}

/// Keeps ping results and runs tests. Results reach the lists in batches.
final class LatencyService {
    /// Key: `subscriptionID:tag`.
    private(set) var results: [String: LatencyEntry] = [:]
    /// Keys changed by the last batch.
    let changed = Observable<Set<String>>([])
    let progress = Observable(LatencyProgress())
    private(set) var testing: Set<String> = []
    private var task: Task<Void, Never>?
    private let runner = LatencyRunner(probes: NetworkProbes())

    static func key(_ subscription: Int64, _ tag: String) -> String { "\(subscription):\(tag)" }

    func entry(_ subscription: Int64, _ tag: String) -> LatencyEntry? { results[LatencyService.key(subscription, tag)] }

    func isTesting(_ subscription: Int64, _ tag: String) -> Bool { testing.contains(LatencyService.key(subscription, tag)) }

    /// Starts a test of the given servers; an already running test is stopped first.
    func test(_ items: [(subscription: Subscription, node: ServerNode)], tunnelSubscription: Int64?) {
        cancel()
        guard !items.isEmpty else { return }
        let mode = LatencyMode.named(Prefs.pingMode)
        let keys = Set(items.map { LatencyService.key($0.subscription.id, $0.node.id) })
        testing = keys
        progress.value = LatencyProgress(running: true, done: 0, total: items.count)
        changed.value = keys
        // Servers of the subscription in the tunnel get the URL test; the rest a direct connect.
        var live: [LatencyRunner.Target] = []
        var direct: [LatencyRunner.Target] = []
        var owner: [String: Int64] = [:]
        for item in items {
            let address = item.node.address
            let target = LatencyRunner.Target(tag: item.node.id, host: address?.host, port: address?.port, udp: item.node.isUDPBased)
            owner[LatencyService.key(item.subscription.id, item.node.id)] = item.subscription.id
            if item.subscription.id == tunnelSubscription { live.append(target) } else { direct.append(TargetKeyed.wrap(target, item.subscription.id)) }
        }
        let liveID = tunnelSubscription
        task = Task { [weak self, runner] in
            let deliver: @Sendable ([String: ProbeResult], Int64?) async -> Void = { batch, subscription in
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    var keys = Set<String>()
                    for (tag, result) in batch {
                        let key = subscription.map { LatencyService.key($0, tag) } ?? tag
                        self.results[key] = LatencyEntry(result: result, date: Date())
                        self.testing.remove(key)
                        keys.insert(key)
                    }
                    var progress = self.progress.value
                    progress.done += batch.count
                    self.progress.value = progress
                    self.changed.value = keys
                }
            }
            if !live.isEmpty { await runner.run(live, mode: mode, tunnel: true) { await deliver($0, liveID) } }
            if !direct.isEmpty, !Task.isCancelled { await runner.run(direct, mode: mode, tunnel: false) { await deliver($0, nil) } }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.finish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if progress.value.running { finish() }
    }

    private func finish() {
        let left = testing
        testing = []
        progress.value = LatencyProgress(running: false, done: progress.value.done, total: progress.value.total)
        if !left.isEmpty { changed.value = left }
    }
}

/// Direct targets carry their subscription in the tag so results map back.
private enum TargetKeyed {
    static func wrap(_ target: LatencyRunner.Target, _ subscription: Int64) -> LatencyRunner.Target {
        LatencyRunner.Target(tag: LatencyService.key(subscription, target.tag), host: target.host, port: target.port, udp: target.udp)
    }
}

import Foundation
import Libbox
import Network
import TunnelCore

/// Real probes: a TCP connect outside the tunnel and the core's URL test.
struct NetworkProbes: LatencyProbes {
    private static let blocking = DispatchQueue(label: "personaltunnel.url-test", qos: .utility, attributes: .concurrent)

    /// The VPN is up: a direct connect must leave by the physical interface, not through it.
    /// Without the VPN no interface is ruled out, as in 1.5.0.
    var avoidTunnel = false
    /// Receives why a direct connect failed, for the service log.
    var report: (@Sendable (String) -> Void)?

    func tcp(host: String, port: Int, timeout: TimeInterval) async -> ProbeResult {
        await tcp(host: host, port: port, timeout: timeout, label: nil)
    }

    func tcp(host: String, port: Int, timeout: TimeInterval, label: String?) async -> ProbeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed(.noAddress) }
        let parameters = NWParameters.tcp
        if avoidTunnel { parameters.prohibitedInterfaceTypes = [.other] }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let box = ResultBox()
        if let report {
            // The server is named, never its address: the log leaves the app.
            let name = label.map { "«\($0)»" } ?? "сервера"
            box.explain = { failure, error, state, path in
                var parts = ["Пинг \(name) напрямую: \(failure.title)"]
                if let error { parts.append(NetworkProbes.describe(error)) } else { parts.append("нет ответа за \(String(format: "%g", timeout)) с, состояние \(state)") }
                if let path { parts.append("путь: " + NetworkProbes.describe(path)) }
                report(parts.joined(separator: "; "))
            }
        }
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
                        box.error = error
                        box.finish(.failed(NetworkProbes.reason(error)), connection)
                    case let .waiting(error):
                        // DNS or the path may still come up: remember why, keep waiting.
                        box.error = error
                        box.state = "waiting"
                        box.pending = NetworkProbes.reason(error)
                    case .preparing:
                        box.state = "preparing"
                    case .cancelled:
                        box.finish(.failed(box.pending ?? .timeout), connection)
                    default: break
                    }
                }
                // One serial queue: state changes and the deadline never run at once.
                let queue = DispatchQueue(label: "personaltunnel.tcp-probe", qos: .utility)
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    box.finish(.failed(box.pending ?? .timeout), connection)
                }
            }
        } onCancel: {
            box.finish(.failed(.timeout), connection, explain: false)
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

    private static func describe(_ error: NWError) -> String {
        switch error {
        case let .posix(code): return "POSIX \(code.rawValue) (\(String(cString: strerror(code.rawValue))))"
        case let .dns(code): return "DNS \(code)"
        case let .tls(status): return "TLS \(status)"
        default: return String(describing: error)
        }
    }

    private static func describe(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "есть"
        case .unsatisfied:
            switch path.unsatisfiedReason {
            case .cellularDenied: status = "нет (сотовые данные запрещены)"
            case .wifiDenied: status = "нет (Wi-Fi запрещён)"
            case .localNetworkDenied: status = "нет (локальная сеть запрещена)"
            default: status = "нет"
            }
        case .requiresConnection: status = "требует подключения"
        @unknown default: status = "неизвестно"
        }
        let interfaces = path.availableInterfaces.map { "\($0.name)/\(NetworkProbes.name($0.type))" }
        return interfaces.isEmpty ? status : status + ", " + interfaces.joined(separator: " ")
    }

    private static func name(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "?"
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
    /// What the connection last said, for the log.
    var error: NWError?
    var state = "setup"
    var explain: ((ProbeFailure, NWError?, String, NWPath?) -> Void)?

    func finish(_ result: ProbeResult, _ connection: NWConnection, explain shouldExplain: Bool = true) {
        lock.lock()
        let first = !done
        done = true
        let target = continuation
        continuation = nil
        lock.unlock()
        guard first else { return }
        if shouldExplain, case let .failed(failure) = result, let explain {
            explain(failure, error, state, connection.currentPath)
        }
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
    /// Outcome of the running test, summed up in the log when it ends.
    private var tally: [ProbeFailure: Int] = [:]
    private var answered = 0

    static func key(_ subscription: Int64, _ tag: String) -> String { "\(subscription):\(tag)" }

    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "classic": return "Классика"
        case "alternative": return "Альтернативный"
        default: return "Основной"
        }
    }

    func entry(_ subscription: Int64, _ tag: String) -> LatencyEntry? { results[LatencyService.key(subscription, tag)] }

    func isTesting(_ subscription: Int64, _ tag: String) -> Bool { testing.contains(LatencyService.key(subscription, tag)) }

    /// Starts a test of the given servers; an already running test is stopped first.
    /// `tunnelUp`: the VPN is on, so direct connects must go around it.
    func test(_ items: [(subscription: Subscription, node: ServerNode)], tunnelSubscription: Int64?, tunnelUp: Bool) {
        cancel()
        guard !items.isEmpty else { return }
        let mode = LatencyMode.named(Prefs.pingMode)
        let log: @Sendable (Int32, String) -> Void = { level, text in DispatchQueue.main.async { App.shared.core.note(text, level: level) } }
        let runner = LatencyRunner(probes: NetworkProbes(avoidTunnel: tunnelUp, report: { log(3, $0) }))
        tally = [:]
        answered = 0
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
            let target = LatencyRunner.Target(tag: item.node.id, host: address?.host, port: address?.port, udp: item.node.isUDPBased, label: item.node.name)
            owner[LatencyService.key(item.subscription.id, item.node.id)] = item.subscription.id
            if item.subscription.id == tunnelSubscription { live.append(target) } else { direct.append(TargetKeyed.wrap(target, item.subscription.id)) }
        }
        let liveID = tunnelSubscription
        let total = items.count
        let how = live.isEmpty ? "напрямую" : (direct.isEmpty ? "через туннель" : "\(live.count) через туннель, \(direct.count) напрямую")
        log(4, "Проверка задержки: \(Format.plural(items.count, "сервер", "сервера", "серверов")) \(how); режим «\(LatencyService.modeTitle(Prefs.pingMode))», VPN \(tunnelUp ? "включён" : "выключен")")
        task = Task { [weak self] in
            let deliver: @Sendable ([String: ProbeResult], Int64?) async -> Void = { batch, subscription in
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    var keys = Set<String>()
                    for (tag, result) in batch {
                        let key = subscription.map { LatencyService.key($0, tag) } ?? tag
                        self.results[key] = LatencyEntry(result: result, date: Date())
                        switch result {
                        case .delay: self.answered += 1
                        case let .failed(reason): self.tally[reason, default: 0] += 1
                        }
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
                let reasons = self.tally.sorted { $0.value > $1.value }.map { "\($0.key.title) ×\($0.value)" }
                log(4, "Проверка задержки завершена: ответили \(self.answered) из \(total)" + (reasons.isEmpty ? "." : "; " + reasons.joined(separator: ", ")))
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
        LatencyRunner.Target(tag: LatencyService.key(subscription, target.tag), host: target.host, port: target.port, udp: target.udp, label: target.label)
    }
}

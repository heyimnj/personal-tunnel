import Foundation
import AppCore
import Network
import Security
import TunnelCore

/// Real probes: a TCP connect outside the tunnel and the core's URL test.
struct NetworkProbes: LatencyProbes {
    private static let blocking = DispatchQueue(label: "personaltunnel.url-test", qos: .utility, attributes: .concurrent)

    /// The VPN is up: a direct connect must leave by the physical interface, not through it.
    /// Without the VPN no interface is ruled out, as in 1.5.0.
    var avoidTunnel = false
    /// Receives why a direct connect failed, for the service log.
    var report: (@Sendable (String) -> Void)?
    let samples = FailureSamples()

    func tcp(host: String, port: Int, timeout: TimeInterval) async -> ProbeResult {
        await tcp(host: host, port: port, timeout: timeout, label: nil)
    }

    func tcp(host: String, port: Int, timeout: TimeInterval, label: String?) async -> ProbeResult {
        await connect(host: host, port: port, parameters: .tcp, kind: "TCP", timeout: timeout, label: label)
    }

    /// A full TLS handshake with the server's SNI. Where the network answers TCP
    /// handshakes itself (a few ms whatever the server) or drops them, only this
    /// measures the server. Any certificate is accepted: REALITY shows the
    /// borrowed site's, and the point is the round trip, not trust.
    func handshake(host: String, port: Int, serverName: String?, timeout: TimeInterval, label: String?) async -> ProbeResult {
        guard let serverName else { return await tcp(host: host, port: port, timeout: timeout, label: label) }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(options, serverName)
        sec_protocol_options_add_tls_application_protocol(options, "h2")
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) }, NetworkProbes.blocking)
        return await connect(host: host, port: port, parameters: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), kind: "TLS", timeout: timeout, label: label)
    }

    private func connect(host: String, port: Int, parameters: NWParameters, kind: String, timeout: TimeInterval, label: String?) async -> ProbeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed(.noAddress) }
        if avoidTunnel { parameters.prohibitedInterfaceTypes = [.other] }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let box = ResultBox()
        if let report {
            // The server is named, never its address: the log leaves the app.
            let name = label.map { "«\($0)»" } ?? "«—»"
            box.explain = { failure, error, state, path in
                var parts = [Lf("Пинг %@ напрямую (%@): %@", "\(name)", "\(kind)", "\(failure.title)")]
                if let error { parts.append(NetworkProbes.describe(error)) } else { parts.append(Lf("нет ответа за %@ с, состояние %@", "\(String(format: "%g", timeout))", "\(state)")) }
                if let path { parts.append(L("путь: ") + NetworkProbes.describe(path)) }
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
        case .satisfied: status = L("есть")
        case .unsatisfied:
            switch path.unsatisfiedReason {
            case .cellularDenied: status = L("нет (сотовые данные запрещены)")
            case .wifiDenied: status = L("нет (Wi-Fi запрещён)")
            case .localNetworkDenied: status = L("нет (локальная сеть запрещена)")
            default: status = L("нет")
            }
        case .requiresConnection: status = L("требует подключения")
        @unknown default: status = L("неизвестно")
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
        let report = report, samples = samples
        return await withCheckedContinuation { continuation in
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
                        if samples.take() { report?(Lf("URL-тест «%@» через туннель: %@", tag, Redactor.redact(result.error))) }
                        continuation.resume(returning: .failed(ProbeFailure.classify(result.error)))
                    }
                } catch {
                    if samples.take() { report?(Lf("URL-тест «%@» через туннель: %@", tag, Redactor.redact(error.localizedDescription))) }
                    continuation.resume(returning: .failed(ProbeFailure.classify(error.localizedDescription)))
                }
            }
        }
    }
}

/// Without the VPN the app's own core measures servers (3.0): each subscription's
/// servers run in a core without a tunnel, and a URL is fetched through every
/// server the way a connection would use it, UDP protocols included. Tags are
/// `subscriptionID:tag`, as for direct targets.
final class LocalCoreProbes: LatencyProbes, @unchecked Sendable {
    private static let blocking = DispatchQueue(label: "personaltunnel.local-core", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var probers: [Int64: PtbridgeProber]
    /// Xray-core for the servers only it can run, one per subscription that has them.
    private var xrays: [PtbridgeXrayInstance] = []
    /// Receives the core's own words for the first few failures of a run.
    var report: ((String) -> Void)?
    private let samples = FailureSamples()

    private init(probers: [Int64: PtbridgeProber], xrays: [PtbridgeXrayInstance]) {
        self.probers = probers
        self.xrays = xrays
    }

    /// Starts a core for every subscription; those that do not start are
    /// returned with the reason, and their servers fall back to TCP.
    static func start(_ subscriptions: [Subscription], options: TunnelOptions) -> (probes: LocalCoreProbes, failed: [Int64: String]) {
        var probers: [Int64: PtbridgeProber] = [:]
        var xrays: [PtbridgeXrayInstance] = []
        var failed: [Int64: String] = [:]
        for (index, subscription) in subscriptions.enumerated() {
            // Each subscription's Xray servers get their own block of local ports.
            let portBase = XrayBacked.appPortBase + index * 500
            do {
                if let runtime = ConfigBuilder.xrayRuntime(subscription: subscription, portBase: portBase) {
                    var error: NSError?
                    if let xray = PtbridgeStartXray(runtime.serialized(pretty: false), &error), error == nil {
                        xrays.append(xray)
                    } else {
                        failed[subscription.id] = Lf("Xray-core не запустился: %@", error?.localizedDescription ?? "—")
                        continue
                    }
                }
                let config = try ConfigBuilder.probe(subscription: subscription, options: options, xrayPortBase: portBase).serialized(pretty: false)
                var error: NSError?
                if let prober = PtbridgeNewProber(config, &error), error == nil {
                    probers[subscription.id] = prober
                } else {
                    failed[subscription.id] = error?.localizedDescription ?? L("ядро не запустилось")
                }
            } catch {
                failed[subscription.id] = (error as? ImportError)?.message ?? error.localizedDescription
            }
        }
        return (LocalCoreProbes(probers: probers, xrays: xrays), failed)
    }

    func close() {
        lock.lock()
        let all = probers.values
        let running = xrays
        probers = [:]
        xrays = []
        lock.unlock()
        for prober in all { prober.close() }
        for xray in running { xray.close() }
    }

    private func prober(_ subscription: Int64) -> PtbridgeProber? {
        lock.lock()
        defer { lock.unlock() }
        return probers[subscription]
    }

    func tcp(host _: String, port _: Int, timeout _: TimeInterval) async -> ProbeResult { .failed(.unsupported) }

    func url(tag: String, link: String, timeoutMs: Int) async -> ProbeResult {
        guard let colon = tag.firstIndex(of: ":"), let subscription = Int64(tag[..<colon]), let prober = prober(subscription) else {
            return .failed(.other)
        }
        let inner = String(tag[tag.index(after: colon)...])
        return await withCheckedContinuation { continuation in
            LocalCoreProbes.blocking.async {
                guard let result = prober.test(inner, link: link, timeoutMs: Int32(timeoutMs)) else {
                    continuation.resume(returning: .failed(.other))
                    return
                }
                if result.error.isEmpty {
                    continuation.resume(returning: .delay(max(1, Int(result.delay))))
                } else {
                    if self.samples.take() { self.report?(Lf("URL-тест «%@» ядром приложения: %@", inner, Redactor.redact(result.error))) }
                    continuation.resume(returning: .failed(ProbeFailure.classify(result.error)))
                }
            }
        }
    }
}

/// The first three failures of a run, so the log says why without filling up.
final class FailureSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var left = 3

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard left > 0 else { return false }
        left -= 1
        return true
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
    /// The app's own core for the running test without the VPN.
    private var local: LocalCoreProbes?
    /// Outcome of the running test, summed up in the log when it ends.
    private var tally: [ProbeFailure: Int] = [:]
    private var answered = 0

    static func key(_ subscription: Int64, _ tag: String) -> String { "\(subscription):\(tag)" }

    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "classic": return L("Классика")
        case "alternative": return L("Альтернативный")
        default: return L("Основной")
        }
    }

    func entry(_ subscription: Int64, _ tag: String) -> LatencyEntry? { results[LatencyService.key(subscription, tag)] }

    func isTesting(_ subscription: Int64, _ tag: String) -> Bool { testing.contains(LatencyService.key(subscription, tag)) }

    /// Servers tapped while a test runs: they are tested right after it, in one go.
    private var pending: [(subscription: Subscription, node: ServerNode)] = []

    /// Starts a test of the given servers; an already running test is stopped first.
    /// `tunnelUp`: the VPN is on, so direct connects must go around it.
    func test(_ items: [(subscription: Subscription, node: ServerNode)], tunnelSubscription: Int64?, tunnelUp: Bool) {
        cancel()
        run(items, tunnelSubscription: tunnelSubscription, tunnelUp: tunnelUp, continuing: false)
    }

    /// A server tapped (or swiped) for its ping. A running test is not stopped: the
    /// server joins it and shows its spinner at once, so several can be tapped in a row.
    func add(_ items: [(subscription: Subscription, node: ServerNode)], tunnelSubscription: Int64?, tunnelUp: Bool) {
        guard task != nil else {
            test(items, tunnelSubscription: tunnelSubscription, tunnelUp: tunnelUp)
            return
        }
        var keys = Set<String>()
        for item in items {
            let key = LatencyService.key(item.subscription.id, item.node.id)
            guard !testing.contains(key), !keys.contains(key) else { continue }
            keys.insert(key)
            pending.append(item)
        }
        guard !keys.isEmpty else { return }
        testing.formUnion(keys)
        var progress = self.progress.value
        progress.total += keys.count
        self.progress.value = progress
        changed.value = keys
    }

    private func run(_ items: [(subscription: Subscription, node: ServerNode)], tunnelSubscription: Int64?, tunnelUp: Bool, continuing: Bool) {
        guard !items.isEmpty else { return }
        let mode = LatencyMode.named(Prefs.pingMode)
        let log: @Sendable (Int32, String) -> Void = { level, text in DispatchQueue.main.async { App.shared.core.note(text, level: level) } }
        let runner = LatencyRunner(probes: NetworkProbes(avoidTunnel: tunnelUp, report: { log(3, $0) }))
        tally = [:]
        answered = 0
        let keys = Set(items.map { LatencyService.key($0.subscription.id, $0.node.id) })
        if continuing {
            // Already counted and spinning since they were added.
            testing.formUnion(keys)
        } else {
            testing = keys
            progress.value = LatencyProgress(running: true, done: 0, total: items.count)
            changed.value = keys
        }
        // Servers of the subscription in the tunnel get the URL test; the rest a direct connect.
        var live: [LatencyRunner.Target] = []
        var direct: [LatencyRunner.Target] = []
        var owner: [String: Int64] = [:]
        var directSubscriptions: [Int64: Subscription] = [:]
        for item in items {
            let address = item.node.address
            let target = LatencyRunner.Target(tag: item.node.id, host: address?.host, port: address?.port, udp: item.node.isUDPBased,
                                              label: item.node.name, tlsName: item.node.tlsServerName)
            owner[LatencyService.key(item.subscription.id, item.node.id)] = item.subscription.id
            if item.subscription.id == tunnelSubscription {
                live.append(target)
            } else {
                direct.append(TargetKeyed.wrap(target, item.subscription.id))
                directSubscriptions[item.subscription.id] = item.subscription
            }
        }
        // Servers outside the tunnel: the app's own core URL-tests them. With the VPN
        // on its connections go through the tunnel (a connect around it found no route
        // on the device), so their delay includes the tunnel's.
        let useLocalCore = !direct.isEmpty
        let options = Prefs.tunnelOptions
        let toStart = Array(directSubscriptions.values)
        let names = directSubscriptions.mapValues(\.name)
        let liveID = tunnelSubscription
        let total = items.count
        let directHow = useLocalCore ? L("ядром приложения") : L("напрямую")
        let how = live.isEmpty ? directHow : (direct.isEmpty ? L("через туннель") : Lf("%@ через туннель, %@ %@", "\(live.count)", "\(direct.count)", directHow))
        log(4, Lf("Проверка задержки: %@ %@; режим «%@», VPN %@", "\(Format.plural(items.count, L("сервер"), L("сервера"), L("серверов")))", "\(how)", "\(LatencyService.modeTitle(Prefs.pingMode))", "\(tunnelUp ? L("включён") : L("выключен"))"))
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
            // The tunnel's own servers: the URL test through the extension, without the
            // TCP prefilter (a connect around the tunnel finds no route on iOS 27).
            var liveMode = mode
            liveMode.tcpFilter = false
            if !live.isEmpty { await runner.run(live, mode: liveMode, tunnel: true) { await deliver($0, liveID) } }
            if useLocalCore, !Task.isCancelled {
                let started = await Task.detached(priority: .utility) { LocalCoreProbes.start(toStart, options: options) }.value
                await MainActor.run { self?.local = started.probes }
                for (id, reason) in started.failed {
                    log(3, Lf("Ядро приложения не запустилось для «%@»: %@. Пинг этой подписки — по TCP.", "\(names[id] ?? "—")", "\(reason)"))
                }
                let fallback = direct.filter { target in started.failed.keys.contains { target.tag.hasPrefix("\($0):") } }
                let measured = direct.filter { target in !started.failed.keys.contains { target.tag.hasPrefix("\($0):") } }
                if !measured.isEmpty, !Task.isCancelled {
                    started.probes.report = { log(3, $0) }
                    let core = LatencyRunner(probes: started.probes)
                    await core.run(measured, mode: LatencyMode.localCore(link: mode.link), tunnel: true) { await deliver($0, nil) }
                }
                if !fallback.isEmpty, !Task.isCancelled { await runner.run(fallback, mode: mode, tunnel: false) { await deliver($0, nil) } }
                started.probes.close()
                await MainActor.run { if self?.local === started.probes { self?.local = nil } }
            } else if !direct.isEmpty, !Task.isCancelled {
                await runner.run(direct, mode: mode, tunnel: false) { await deliver($0, nil) }
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                let reasons = self.tally.sorted { $0.value > $1.value }.map { "\($0.key.title) ×\($0.value)" }
                log(4, Lf("Проверка задержки завершена: ответили %@ из %@", "\(self.answered)", "\(total)") + (reasons.isEmpty ? "." : "; " + reasons.joined(separator: ", ")))
                guard self.pending.isEmpty else {
                    let next = self.pending
                    self.pending = []
                    self.run(next, tunnelSubscription: App.shared.tunnelSubscription,
                             tunnelUp: App.shared.tunnel.state.value != .disconnected, continuing: true)
                    return
                }
                self.task = nil
                self.finish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = []
        local?.close()
        local = nil
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
        LatencyRunner.Target(tag: LatencyService.key(subscription, target.tag), host: target.host, port: target.port, udp: target.udp, label: target.label, tlsName: target.tlsName)
    }
}

import Foundation
import TunnelCore

/// PTLab: the app's `CoreClient` without the core. While the pretend tunnel is
/// up it makes a status a second — speeds that wander, growing totals, memory,
/// a few open connections and their routes — and a few log lines, so analytics,
/// the connections list and the service log have something alive to show. Same
/// surface as the app's (App/Sources/Core/CoreClient.swift).
final class CoreClient {
    let status = Observable<CoreStatus?>(nil)
    let connections = Observable(CoreConnections())
    let history = Observable(TrafficHistory())
    let samples = Observable(CoreSamples())
    let logsChanged = Signal()
    private(set) var logs: [LogLine] = []
    var logsPaused = false

    private var running = false
    private var inBackground = false
    private var wantsConnections = false
    private var logCounter = 0
    private var timer: Timer?

    private var totals: (up: Int64, down: Int64) = (0, 0)
    private var totalsBase: (up: Int64, down: Int64) = (0, 0)
    private var routes: [String: Int64] = [:]
    private var routesBase: [String: Int64] = [:]
    private var down: Double = 40_000
    private var up: Double = 8_000
    private var open: [CoreConnection] = []

    static func setUp(paths _: SharedPaths) {}

    var coreTotals: (up: Int64, down: Int64) { totals }

    var listsConnections = false {
        didSet { publishConnections() }
    }

    func start() {
        guard !running else { return }
        running = true
        totals = (0, 0)
        totalsBase = (0, 0)
        routes = [:]
        routesBase = [:]
        open = []
        appendCore(4, "inbound/tun[tun-in]: started at utun4")
        appendCore(4, "outbound/selector[select]: selected the server")
        appendCore(4, "router: updated default interface en0")
        resume()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        status.value = nil
        connections.value = CoreConnections()
    }

    func setInBackground(_ value: Bool) {
        guard inBackground != value else { return }
        inBackground = value
        if value { timer?.invalidate(); timer = nil } else if running { resume() }
    }

    func setConnectionsStreamed(_ enabled: Bool) {
        wantsConnections = enabled
    }

    func resetStatistics() {
        totalsBase = totals
        routesBase = routes
        if var current = status.value {
            current.uplinkTotal = 0
            current.downlinkTotal = 0
            status.set(current)
        }
        history.value = TrafficHistory()
        samples.value = CoreSamples()
        publishConnections()
    }

    func note(_ text: String, level: Int32 = 4) {
        append(level, "[app] " + text)
    }

    func clearLogs() {
        logs = []
        logsChanged.fire()
    }

    // MARK: Pretend core

    private func resume() {
        guard timer == nil, !inBackground else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard running else { return }
        // Speeds wander, now and then a burst (a page, a video chunk).
        down = max(0, down * Double.random(in: 0.6 ... 1.4) + (Int.random(in: 0 ..< 9) == 0 ? Double.random(in: 200_000 ... 1_400_000) : 0))
        down = min(down, 3_000_000)
        if down < 2_000 { down = Double.random(in: 2_000 ... 30_000) }
        up = max(500, down * Double.random(in: 0.08 ... 0.3))
        let d = Int64(down), u = Int64(up)
        totals.down += d
        totals.up += u
        let server = App.shared.library.activeNode?.id ?? "proxy"
        routes[server, default: 0] += (d + u) * 9 / 10
        routes[CoreConnections.direct, default: 0] += (d + u) / 14
        routes[CoreConnections.dns, default: 0] += (d + u) / 40
        var value = CoreStatus(uplink: u, downlink: d, uplinkTotal: totals.up - totalsBase.up, downlinkTotal: totals.down - totalsBase.down,
                               memory: Int64.random(in: 27_000_000 ... 34_000_000), goroutines: Int32.random(in: 44 ... 58))
        value.uplink = max(0, value.uplink)
        status.set(value)
        var next = history.value
        next.append(down: d, up: u)
        history.value = next
        updateOpen(server: server)
        publishConnections()
        var more = samples.value
        more.append(memory: value.memory, tcp: connections.value.tcp, udp: connections.value.udp)
        samples.value = more
        if Int.random(in: 0 ..< 12) == 0 {
            appendCore(Int.random(in: 0 ..< 6) == 0 ? 3 : 4, Self.lines.randomElement() ?? "router: match")
        }
    }

    private static let sites = ["www.apple.com", "api.github.com", "music.youtube.com", "t.me", "www.wikipedia.org",
                                "cdn.jsdelivr.net", "news.ycombinator.com", "mail.example.org", "i.ytimg.com", "push.apple.com"]
    private static let lines = [
        "outbound/vless: connection to the server opened",
        "router: found process for the connection",
        "dns: exchanged A for the connection",
        "outbound/vless: connection closed by the remote side",
        "inbound/tun[tun-in]: connection upload finished",
    ]

    /// A few connections come and go; their bytes grow.
    private func updateOpen(server: String) {
        open = open.compactMap { item in
            if Int.random(in: 0 ..< 10) == 0 { return nil }
            let addUp = Int64.random(in: 0 ... 6_000), addDown = Int64.random(in: 0 ... 40_000)
            return CoreConnection(id: item.id, udp: item.udp, destination: item.destination, outbound: item.outbound, chain: item.chain,
                                  createdAt: item.createdAt, upload: addUp, download: addDown,
                                  uploadTotal: item.uploadTotal + addUp, downloadTotal: item.downloadTotal + addDown,
                                  rule: item.rule, protocolName: item.protocolName)
        }
        while open.count < 3 || (open.count < 9 && Int.random(in: 0 ..< 3) == 0) {
            let udp = Int.random(in: 0 ..< 5) == 0
            let site = Self.sites.randomElement() ?? "example.com"
            open.append(CoreConnection(id: UUID().uuidString, udp: udp, destination: udp ? site + ":443" : site, outbound: server,
                                       chain: [server], createdAt: Date(), upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0,
                                       rule: "final", protocolName: udp ? "quic" : "tls"))
        }
    }

    private func publishConnections() {
        guard running else { return }
        var value = CoreConnections()
        value.tcp = open.filter { !$0.udp }.count
        value.udp = open.filter(\.udp).count
        for (route, bytes) in routes {
            let shown = bytes - routesBase[route, default: 0]
            if shown > 0 { value.routes[route] = shown }
        }
        if listsConnections { value.open = open }
        connections.set(value)
    }

    // MARK: Log

    private func appendCore(_ level: Int32, _ text: String) {
        append(level, text)
    }

    private func append(_ level: Int32, _ text: String) {
        guard !logsPaused else { return }
        logCounter += 1
        logs.append(LogLine(id: logCounter, level: level, text: text, date: Date()))
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
        logsChanged.fire()
    }
}

import Foundation
import AppCore
import TunnelCore

struct CoreStatus: Equatable {
    var uplink: Int64 = 0
    var downlink: Int64 = 0
    var uplinkTotal: Int64 = 0
    var downlinkTotal: Int64 = 0
    var memory: Int64 = 0
    var goroutines: Int32 = 0
}

struct CoreConnections: Equatable {
    var tcp = 0
    var udp = 0
    /// Bytes per outbound tag over the session (3.5.14; before: only the connections
    /// the core still held), «direct» under `CoreConnections.direct`. Connections the
    /// app never saw (closed and forgotten by the core while it was in the background)
    /// are the session's total less their sum.
    var routes: [String: Int64] = [:]
    static let direct = "\u{1}direct"
    /// 3.5.20: the app's own server tests through the tunnel's way out (kill
    /// switch) and the tunnel's DNS — counted in the session's total, so shown too
    /// (they were «Без разбивки»: 2.6 of 3.8 MB after a ping of every server).
    static let probes = "\u{1}probes"
    static let dns = "\u{1}dns"
    /// The open connections themselves, filled only while a screen lists them.
    var open: [CoreConnection] = []
}

/// One open connection, as the list of TCP or UDP connections shows it.
struct CoreConnection: Equatable {
    let id: String
    let udp: Bool
    /// The domain when the core knows it, else the address with its port.
    let destination: String
    let outbound: String
    let chain: [String]
    let createdAt: Date
    let upload: Int64
    let download: Int64
    let uploadTotal: Int64
    let downloadTotal: Int64
    let rule: String
    let protocolName: String
}

/// The core's memory and open connections, a sample a second (3.5).
struct CoreSamples: Equatable {
    static let capacity = 120
    private(set) var memory: [Int64] = []
    private(set) var tcp: [Int] = []
    private(set) var udp: [Int] = []

    mutating func append(memory value: Int64, tcp tcpCount: Int, udp udpCount: Int) {
        memory.append(value)
        tcp.append(tcpCount)
        udp.append(udpCount)
        if memory.count > Self.capacity {
            memory.removeFirst(memory.count - Self.capacity)
            tcp.removeFirst(tcp.count - Self.capacity)
            udp.removeFirst(udp.count - Self.capacity)
        }
    }
}

struct LogLine {
    let id: Int
    let level: Int32
    let text: String
    /// 3.5: when the app received it. The core's own lines carry no clock time;
    /// nil: it came with the core's buffer, before the app was listening.
    let date: Date?

    var fromApp: Bool { text.hasPrefix("[app]") }

    /// «12:04:51», or nil without a date.
    var time: String? { date.map(LogLine.clock.string(from:)) }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Live data from the running core over the Libbox command socket. Each kind
/// of data has its own observable, so a screen redraws only for what it shows.
final class CoreClient {
    let status = Observable<CoreStatus?>(nil)
    let connections = Observable(CoreConnections())
    let history = Observable(TrafficHistory())
    /// 3.5: the core's memory and the open connections, once a second over the
    /// last two minutes (analytics draws them).
    let samples = Observable(CoreSamples())
    /// Fired when lines are appended to `logs`.
    let logsChanged = Signal()
    private(set) var logs: [LogLine] = []
    var logsPaused = false

    private var client: LibboxCommandClient?
    private var generation = 0
    private var running = false
    /// 3.2.9: the app is in the background. The status stream (every second) is
    /// closed then: iOS suspends the app but keeps its socket open, and the
    /// extension went on waking every second to read and send a status nobody
    /// read, until the socket's buffer filled.
    private var inBackground = false
    private var wantsConnections = false
    private var logCounter = 0
    private let work = DispatchQueue(label: "personaltunnel.core-client", qos: .utility)
    /// Connection events and log lines are prepared here, off the main thread:
    /// the core replays its whole log (up to 1000 lines) on every new stream and
    /// sends connection events every second, and cleaning, masking and counting
    /// them on the main thread stalled the analytics page as it came in.
    private let parse = DispatchQueue(label: "personaltunnel.core-client.parse", qos: .userInitiated)
    /// Owned by `parse`.
    private var store: LibboxConnections?
    /// Owned by `parse`: whether to copy the open connections out (`CoreConnections.open`).
    private var parseListsConnections = false
    /// Owned by `parse` (3.5.14): the session's bytes per route, and how much of each
    /// connection is already in them — the core sends a connection again with its
    /// whole count on every new stream, and the app's store forgets closed ones.
    private var sessionRoutes: [String: Int64] = [:]
    /// Owned by `parse`: the routes at the last «Сбросить статистику» (3.5.27).
    private var routesBase: [String: Int64] = [:]
    private var counted: [String: Int64] = [:]

    static func setUp(paths: SharedPaths) {
        let options = LibboxSetupOptions()
        options.basePath = paths.base.path
        options.workingPath = paths.working.path
        options.tempPath = paths.temp.path
        options.crashReportSource = "app"
        var error: NSError?
        LibboxSetup(options, &error)
    }

    func start() {
        guard !running else { return }
        running = true
        // 3.5: a new session: the app's own lines of long-gone connections go
        // (the core starts its own log again by itself); the last minutes stay,
        // they tell how this start came about.
        let recent = Date().addingTimeInterval(-600)
        let before = logs.count
        logs.removeAll { $0.fromApp && ($0.date ?? .distantPast) < recent }
        if logs.count != before { logsChanged.fire() }
        if !inBackground { connect() }
    }

    /// The app went to the background or came back (3.2.9).
    func setInBackground(_ value: Bool) {
        guard inBackground != value else { return }
        inBackground = value
        guard running else { return }
        if value { disconnect() } else { connect() }
    }

    func stop() {
        running = false
        disconnect()
        status.value = nil
        connections.value = CoreConnections()
        parse.async { self.store = nil; self.sessionRoutes = [:]; self.routesBase = [:]; self.counted = [:]; self.routeOf = [:] }
    }

    /// The core's totals at the last «Сбросить статистику» (3.1.6): the core keeps
    /// counting from the tunnel's start, so the cards show what came after it.
    private var totalsBase: (up: Int64, down: Int64) = (0, 0)
    /// The core's own totals, as they last came.
    private var rawTotals: (up: Int64, down: Int64) = (0, 0)
    /// 3.5.23: the core's own running totals (not after «Сбросить статистику»), the
    /// same counters the extension's timeline notes.
    var coreTotals: (up: Int64, down: Int64) { rawTotals }

    func resetStatistics() {
        totalsBase = rawTotals
        if var current = status.value {
            current.uplinkTotal = 0
            current.downlinkTotal = 0
            status.set(current)
        }
        history.value = TrafficHistory()
        samples.value = CoreSamples()
        connections.value = CoreConnections()
        parse.async { self.routesBase = self.sessionRoutes }
    }

    /// A line from the app itself; the core's own lines arrive over the socket.
    func note(_ text: String, level: Int32 = 4) {
        append([(level, "[app] " + text)])
    }

    func clearLogs() {
        logs = []
        logsChanged.fire()
        // 3.5: the core's buffer too, or the next stream brings its lines back.
        if let client { work.async { try? client.clearLogs() } }
    }

    /// Every new log stream starts with the core's whole buffer (the core starts
    /// it again when the tunnel starts). 3.5: lines already received keep the
    /// time they first came; the others came before the app was listening. The
    /// app's own lines stay, and everything stands in the order of its time.
    fileprivate func replaceCoreLines(_ entries: [(Int32, String)]) {
        var known: [String: [Date?]] = [:]
        for line in logs where !line.fromApp { known[line.text, default: []].append(line.date) }
        // `order`: where the line stands. The core's lines come in their own order,
        // so one without a date stands right after the dated line before it.
        var next: [(level: Int32, text: String, date: Date?, order: Date)] = logs.filter(\.fromApp).map { ($0.level, $0.text, $0.date, $0.date ?? .distantPast) }
        var previous = Date.distantPast
        for (level, text) in entries {
            var date: Date?
            if var dates = known[text], !dates.isEmpty {
                date = dates.removeFirst()
                known[text] = dates
            }
            if let date { previous = max(previous, date) }
            next.append((level, text, date, date ?? previous))
        }
        let sorted = next.enumerated().sorted { left, right in
            let a = left.element.order, b = right.element.order
            return a != b ? a < b : left.offset < right.offset
        }
        logs = sorted.map { item in
            logCounter += 1
            return LogLine(id: logCounter, level: item.element.level, text: item.element.text, date: item.element.date)
        }
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
        logsChanged.fire()
    }

    /// Connection events are streamed while the analytics page can be shown
    /// (3.5: the whole Minimal Home, so the page has its data the first time it opens).
    func setConnectionsStreamed(_ enabled: Bool) {
        guard wantsConnections != enabled else { return }
        wantsConnections = enabled
        if running, !inBackground { disconnect(); connect() }
    }

    /// While a screen lists the open connections, they are copied out with every update.
    /// Turned on, the list is built at once from what the core has already sent: the
    /// core sends events only when a connection opens, closes or moves bytes, so in
    /// a quiet moment the screen would otherwise stay empty.
    var listsConnections = false {
        didSet {
            let value = listsConnections
            let token = generation
            parse.async {
                self.parseListsConnections = value
                guard value, self.store != nil else { return }
                let result = self.prepare(nil)
                self.receive(token) { $0.connections.set(result) }
            }
        }
    }

    private func disconnect() {
        generation += 1
        if let client { work.async { try? client.disconnect() } }
        client = nil
    }

    private func connect() {
        guard !inBackground else { return }
        generation += 1
        let token = generation
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        if wantsConnections { options.addCommand(LibboxCommandConnections) }
        // 3.5: the log is always streamed (it was only while the log screen was
        // open): a line gets the time it came, and the screen opens on all of them.
        options.addCommand(LibboxCommandLog)
        options.statusInterval = Int64(NSEC_PER_SEC)
        guard let client = LibboxNewCommandClient(Handler(owner: self, token: token), options) else { return }
        self.client = client
        work.async { [weak self] in
            // The socket appears a moment after the tunnel reports "connected".
            for _ in 0 ..< 12 {
                if (try? client.connect()) != nil { return }
                Thread.sleep(forTimeInterval: 0.5)
                var current = false
                DispatchQueue.main.sync { current = self?.generation == token }
                if !current { return }
            }
        }
    }

    fileprivate func receive(_ token: Int, _ update: @escaping (CoreClient) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.generation else { return }
            update(self)
        }
    }

    fileprivate func apply(_ value: CoreStatus) {
        var value = value
        // A new tunnel starts its count again from zero; so does the base.
        if value.uplinkTotal < totalsBase.up || value.downlinkTotal < totalsBase.down { totalsBase = (0, 0) }
        // …and the routes of the last one go with it (3.5.14).
        if value.uplinkTotal < rawTotals.up || value.downlinkTotal < rawTotals.down { parse.async { self.sessionRoutes = [:]; self.routesBase = [:]; self.counted = [:]; self.routeOf = [:] } }
        // 3.3 beta 4: a reload starts the core's counters again, and its first rate
        // came out negative: the graph drew far below its card.
        value.uplink = max(0, value.uplink)
        value.downlink = max(0, value.downlink)
        rawTotals = (value.uplinkTotal, value.downlinkTotal)
        value.uplinkTotal -= totalsBase.up
        value.downlinkTotal -= totalsBase.down
        status.set(value)
        var next = history.value
        next.append(down: value.downlink, up: value.uplink)
        history.value = next
        var more = samples.value
        more.append(memory: value.memory, tcp: connections.value.tcp, udp: connections.value.udp)
        samples.value = more
    }

    /// The app's own lines; cleaned here, they are short and few.
    fileprivate func append(_ entries: [(Int32, String)]) {
        appendPrepared(entries.map { ($0.0, CoreClient.prepareLine($0.1)) })
    }

    /// A core line about a connection of the app's tests through the tunnel's
    /// way out for them (`probe-in` → `probe-direct`).
    static func isProbeExitLine(_ text: String) -> Bool {
        text.contains("[\(ProbeExit.directTag)]") || text.contains("[\(ProbeExit.inboundTag)]")
    }

    /// Colours and the level word out, the core's seconds since its start out
    /// (3.5: the line's time is shown instead), masked, translated.
    fileprivate static func prepareLine(_ text: String) -> String {
        TunnelText.localize(Redactor.redact(LogDigest.dropUptime(LogText.clean(text))))
    }

    /// Lines already cleaned and masked (on `parse`).
    fileprivate func appendPrepared(_ entries: [(Int32, String)]) {
        guard !logsPaused else { return }
        let now = Date()
        for (level, text) in entries {
            logCounter += 1
            logs.append(LogLine(id: logCounter, level: level, text: text, date: now))
        }
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
        logsChanged.fire()
    }

    /// On `parse`: applies the events (none: only reads the store) and counts what is open.
    fileprivate func prepare(_ events: LibboxConnectionEvents?) -> CoreConnections {
        if store == nil { store = LibboxNewConnections() }
        var result = CoreConnections()
        guard let store else { return result }
        // 3.5.21: the routes are counted from the events themselves, before the store
        // applies them — the store drops connections closed over five minutes ago,
        // and on every new stream (a return to the app) the core sends the session's
        // closed connections again: those were lost to «Без разбивки».
        if let events {
            countRoutes(events)
            store.apply(events)
        }
        let list = parseListsConnections
        if let iterator = store.iterator() {
            while iterator.hasNext() {
                guard let item = iterator.next() else { continue }
                // The tunnel's DNS and (3.2.10) the app's own server tests through the
                // kill switch's way out are not the device's connections; their bytes
                // count in the session's routes under their own names (3.5.20).
                if item.outboundType == "dns" || item.inbound == ProbeExit.inboundTag { continue }
                if item.closedAt == 0 {
                    let udp = item.network == "udp"
                    if udp { result.udp += 1 } else { result.tcp += 1 }
                    if list {
                        var chain: [String] = []
                        if let links = item.chain() { while links.hasNext() { chain.append(links.next()) } }
                        let domain = item.domain
                        result.open.append(CoreConnection(
                            id: item.id_, udp: udp, destination: domain.isEmpty ? item.destination : domain,
                            outbound: item.outbound, chain: chain,
                            createdAt: Date(timeIntervalSince1970: Double(item.createdAt) / 1000),
                            upload: item.uplink, download: item.downlink,
                            uploadTotal: item.uplinkTotal, downloadTotal: item.downlinkTotal,
                            rule: item.rule, protocolName: item.protocol
                        ))
                    }
                }
            }
        }
        // «Сбросить статистику»: what came before it is taken off (the snapshot
        // counts from the tunnel's start).
        result.routes = [:]
        for (route, value) in sessionRoutes {
            let shown = value - routesBase[route, default: 0]
            if shown > 0 { result.routes[route] = shown }
        }
        return result
    }

    /// Owned by `parse`: the route of each open connection, for its traffic updates.
    private var routeOf: [String: String] = [:]
    /// 3.5.25 (the owner: «Без разбивки» again, 360 KB of 3 MB with the app open):
    /// what the routes could not take, noted in the log once a minute to find why.
    private var missed: (noRoute: Int64, noRouteCount: Int, orphan: Int64, orphanCount: Int) = (0, 0, 0, 0)
    private var missedNotedAt = Date()

    /// Once a minute, while the app watches: what the routes missed, if anything.
    private func noteMissed(reset: Bool) {
        if reset { noteFromParse(L("Маршруты: новый поток соединений от ядра (снимок)")) }
        guard Date().timeIntervalSince(missedNotedAt) > 60 else { return }
        missedNotedAt = Date()
        let value = missed
        missed = (0, 0, 0, 0)
        guard value.noRoute > 0 || value.orphan > 0 else { return }
        noteFromParse(Lf("Маршруты: без исходящего %@ (%@ соед.), обновления без начала %@ (%@)",
                Format.bytes(value.noRoute), "\(value.noRouteCount)", Format.bytes(value.orphan), "\(value.orphanCount)"))
    }

    private func noteFromParse(_ text: String) {
        DispatchQueue.main.async { self.note(text, level: 4) }
    }

    /// The route a connection's bytes count under: the tunnel's DNS and (3.2.10) the
    /// app's own server tests through the kill switch's way out under their own names.
    private static func route(of item: LibboxConnection) -> String {
        if item.outboundType == "dns" { return CoreConnections.dns }
        if item.inbound == ProbeExit.inboundTag { return CoreConnections.probes }
        return item.outboundType == "direct" ? CoreConnections.direct : item.outbound
    }

    /// On `parse`: a connection that comes whole (new, closed, or again in a new
    /// stream's snapshot) adds what it moved beyond what was counted for it; a
    /// traffic update adds its bytes.
    private func countRoutes(_ events: LibboxConnectionEvents) {
        defer { noteMissed(reset: events.reset) }
        // 3.5.27 (the owner: «Без разбивки» 4.2 of 11.6 MB after a video sent in the
        // background): a new stream's snapshot is the whole session — the open
        // connections, the closed ones the core still lists, and (core patch 0009)
        // one closed entry per route for those it no longer lists. The routes are
        // counted from it afresh; before, what the core had dropped while the app
        // was away was lost.
        if events.reset {
            sessionRoutes = [:]
            counted = [:]
            routeOf = [:]
        }
        guard let iterator = events.iterator() else { return }
        while iterator.hasNext() {
            guard let event = iterator.next() else { continue }
            let id = event.id_
            if let item = event.connection {
                let route = Self.route(of: item)
                guard !route.isEmpty else {
                    missed.noRoute += item.uplinkTotal + item.downlinkTotal
                    missed.noRouteCount += 1
                    continue
                }
                let total = item.uplinkTotal + item.downlinkTotal
                let delta = total - counted[id, default: 0]
                if delta > 0 {
                    counted[id] = total
                    sessionRoutes[route, default: 0] += delta
                }
                if item.closedAt == 0 { routeOf[id] = route } else { routeOf[id] = nil }
            } else {
                let delta = event.uplinkDelta + event.downlinkDelta
                guard delta > 0 else { continue }
                guard let route = routeOf[id] else {
                    missed.orphan += delta
                    missed.orphanCount += 1
                    continue
                }
                counted[id, default: 0] += delta
                sessionRoutes[route, default: 0] += delta
            }
        }
    }

    private final class Handler: NSObject, LibboxCommandClientHandlerProtocol {
        weak var owner: CoreClient?
        let token: Int
        /// The core's next lines are its whole buffer again (a new stream, a new start).
        private var replay = false

        init(owner: CoreClient, token: Int) {
            self.owner = owner
            self.token = token
        }

        func connected() {}
        func disconnected(_: String?) {}
        func setDefaultLogLevel(_: Int32) {}

        /// The core always sends its lines right after this (none after a new start).
        func clearLogs() { replay = true }

        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
            guard let owner else { return }
            var entries: [(Int32, String)] = []
            while let messageList, messageList.hasNext() {
                guard let entry = messageList.next() else { continue }
                // 3.5.5 (the owner: red lines while everything worked): the app's own
                // server tests through the tunnel's way out are not the owner's
                // traffic; a dead server's dial gave an ERROR line for every try.
                // Which servers did not answer, the app's own WARN lines already say.
                if CoreClient.isProbeExitLine(entry.message) { continue }
                entries.append((entry.level, entry.message))
            }
            let replaced = replay
            replay = false
            guard replaced || !entries.isEmpty else { return }
            let token = self.token
            owner.parse.async { [weak owner] in
                let prepared = entries.map { ($0.0, CoreClient.prepareLine($0.1)) }
                owner?.receive(token) { replaced ? $0.replaceCoreLines(prepared) : $0.appendPrepared(prepared) }
            }
        }

        func writeStatus(_ message: LibboxStatusMessage?) {
            guard let message else { return }
            let value = CoreStatus(uplink: message.uplink, downlink: message.downlink, uplinkTotal: message.uplinkTotal,
                                   downlinkTotal: message.downlinkTotal, memory: message.memory, goroutines: message.goroutines)
            owner?.receive(token) { $0.apply(value) }
        }

        func writeGroups(_: (any LibboxOutboundGroupIteratorProtocol)?) {}
        func writeOutbounds(_: (any LibboxOutboundGroupItemIteratorProtocol)?) {}
        func initializeClashMode(_: (any LibboxStringIteratorProtocol)?, currentMode _: String?) {}
        func updateClashMode(_: String?) {}

        func write(_ events: LibboxConnectionEvents?) {
            guard let events, let owner else { return }
            let token = self.token
            owner.parse.async { [weak owner] in
                guard let owner else { return }
                let result = owner.prepare(events)
                owner.receive(token) { $0.connections.set(result) }
            }
        }

        func write(_: LibboxDnsQuery?) {}
    }

    // MARK: One-off commands

    /// 3.3 beta 4: asks the running tunnel to load the stored configuration again,
    /// over the core's command socket (the extension's `serviceReload`). The
    /// system's message to the extension never reached it on the device (beta 3:
    /// every server change restarted the VPN). nil: the new configuration runs.
    static func reloadService(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                guard let client = LibboxNewStandaloneCommandClient() else { throw NSError(domain: "PersonalTunnel", code: 1) }
                try client.serviceReload()
            } catch {
                failure = Redactor.redact(error.localizedDescription)
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    /// Switches the server inside the running tunnel.
    static func select(tag: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = (try? LibboxNewStandaloneCommandClient()?.selectOutbound(ConfigBuilder.selectorTag, outboundTag: tag)) != nil
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

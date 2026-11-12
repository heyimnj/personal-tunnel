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
    /// Bytes per outbound tag, observed while the stream was open.
    var routes: [String: Int64] = [:]
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

struct LogLine {
    let id: Int
    let level: Int32
    let text: String
}

/// Live data from the running core over the Libbox command socket. Each kind
/// of data has its own observable, so a screen redraws only for what it shows.
final class CoreClient {
    let status = Observable<CoreStatus?>(nil)
    let connections = Observable(CoreConnections())
    let history = Observable(TrafficHistory())
    /// Fired when lines are appended to `logs`.
    let logsChanged = Signal()
    private(set) var logs: [LogLine] = []
    var logsPaused = false

    private var client: LibboxCommandClient?
    private var generation = 0
    private var running = false
    private var wantsConnections = false
    private var wantsLog = false
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
        connect()
    }

    func stop() {
        running = false
        disconnect()
        status.value = nil
        connections.value = CoreConnections()
        parse.async { self.store = nil }
    }

    func resetStatistics() {
        history.value = TrafficHistory()
        connections.value = CoreConnections()
        parse.async { self.store = nil }
    }

    /// A line from the app itself; the core's own lines arrive over the socket.
    func note(_ text: String, level: Int32 = 4) {
        append([(level, "[app] " + text)])
    }

    func clearLogs() {
        logs = []
        logsChanged.fire()
    }

    /// The core clears its log when it restarts; the app's own lines stay.
    fileprivate func clearCoreLines() {
        logs.removeAll { !$0.text.hasPrefix("[app]") }
        logsChanged.fire()
    }

    /// Connection events are streamed only while analytics is on screen.
    func setConnectionsStreamed(_ enabled: Bool) {
        guard wantsConnections != enabled else { return }
        wantsConnections = enabled
        if running { disconnect(); connect() }
    }

    /// The log is streamed only while the log screen is open: a new log stream
    /// starts with the core's whole buffer, which analytics does not need.
    func setLogStreamed(_ enabled: Bool) {
        guard wantsLog != enabled else { return }
        wantsLog = enabled
        if running { disconnect(); connect() }
    }

    /// While a screen lists the open connections, they are copied out with every update.
    var listsConnections = false {
        didSet {
            let value = listsConnections
            parse.async { self.parseListsConnections = value }
        }
    }

    private func disconnect() {
        generation += 1
        if let client { work.async { try? client.disconnect() } }
        client = nil
    }

    private func connect() {
        generation += 1
        let token = generation
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        if wantsConnections { options.addCommand(LibboxCommandConnections) }
        if wantsLog { options.addCommand(LibboxCommandLog) }
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
        status.set(value)
        var next = history.value
        next.append(down: value.downlink, up: value.uplink)
        history.value = next
    }

    /// The app's own lines; cleaned here, they are short and few.
    fileprivate func append(_ entries: [(Int32, String)]) {
        appendPrepared(entries.map { ($0.0, Redactor.redact(LogText.clean($0.1))) })
    }

    /// Lines already cleaned and masked (on `parse`).
    fileprivate func appendPrepared(_ entries: [(Int32, String)]) {
        guard !logsPaused else { return }
        for (level, text) in entries {
            logCounter += 1
            logs.append(LogLine(id: logCounter, level: level, text: text))
        }
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
        logsChanged.fire()
    }

    /// On `parse`: applies the events and counts what is open.
    fileprivate func prepare(_ events: LibboxConnectionEvents) -> CoreConnections {
        if store == nil { store = LibboxNewConnections() }
        var result = CoreConnections()
        guard let store else { return result }
        store.apply(events)
        let list = parseListsConnections
        if let iterator = store.iterator() {
            while iterator.hasNext() {
                guard let item = iterator.next() else { continue }
                if item.outboundType == "dns" { continue }
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
                if item.outboundType != "direct", !item.outbound.isEmpty {
                    result.routes[item.outbound, default: 0] += item.uplinkTotal + item.downlinkTotal
                }
            }
        }
        return result
    }

    private final class Handler: NSObject, LibboxCommandClientHandlerProtocol {
        weak var owner: CoreClient?
        let token: Int

        init(owner: CoreClient, token: Int) {
            self.owner = owner
            self.token = token
        }

        func connected() {}
        func disconnected(_: String?) {}
        func setDefaultLogLevel(_: Int32) {}

        func clearLogs() {
            // Through `parse`, so it stays in order with the lines prepared there.
            guard let owner else { return }
            let token = self.token
            owner.parse.async { [weak owner] in owner?.receive(token) { $0.clearCoreLines() } }
        }

        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
            guard let messageList, let owner else { return }
            var entries: [(Int32, String)] = []
            while messageList.hasNext() {
                if let entry = messageList.next() { entries.append((entry.level, entry.message)) }
            }
            guard !entries.isEmpty else { return }
            let token = self.token
            owner.parse.async { [weak owner] in
                let prepared = entries.map { ($0.0, Redactor.redact(LogText.clean($0.1))) }
                owner?.receive(token) { $0.appendPrepared(prepared) }
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

    /// Switches the server inside the running tunnel.
    static func select(tag: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = (try? LibboxNewStandaloneCommandClient()?.selectOutbound(ConfigBuilder.selectorTag, outboundTag: tag)) != nil
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

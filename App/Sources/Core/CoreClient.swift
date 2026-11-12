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
    private var wantsDetails = false
    private var logCounter = 0
    private var store: LibboxConnections?
    private let work = DispatchQueue(label: "personaltunnel.core-client", qos: .utility)

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
        store = nil
    }

    func resetStatistics() {
        history.value = TrafficHistory()
        connections.value = CoreConnections()
        store = nil
    }

    /// A line from the app itself; the core's own lines arrive over the socket.
    func note(_ text: String, level: Int32 = 4) {
        append([(level, "[app] " + text)])
    }

    func clearLogs() {
        logs = []
        logsChanged.fire()
    }

    /// Connection list and log are streamed only while a screen needs them.
    func setDetails(_ enabled: Bool) {
        guard wantsDetails != enabled else { return }
        wantsDetails = enabled
        if running { disconnect(); connect() }
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
        if wantsDetails {
            options.addCommand(LibboxCommandConnections)
            options.addCommand(LibboxCommandLog)
        }
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

    fileprivate func append(_ entries: [(Int32, String)]) {
        guard !logsPaused else { return }
        for (level, text) in entries {
            logCounter += 1
            logs.append(LogLine(id: logCounter, level: level, text: Redactor.redact(LogText.clean(text))))
        }
        if logs.count > 1500 { logs.removeFirst(logs.count - 1500) }
        logsChanged.fire()
    }

    fileprivate func apply(_ events: LibboxConnectionEvents) {
        if store == nil { store = LibboxNewConnections() }
        guard let store else { return }
        store.apply(events)
        var result = CoreConnections()
        if let iterator = store.iterator() {
            while iterator.hasNext() {
                guard let item = iterator.next() else { continue }
                if item.outboundType == "dns" { continue }
                if item.closedAt == 0 {
                    if item.network == "udp" { result.udp += 1 } else { result.tcp += 1 }
                }
                if item.outboundType != "direct", !item.outbound.isEmpty {
                    result.routes[item.outbound, default: 0] += item.uplinkTotal + item.downlinkTotal
                }
            }
        }
        connections.set(result)
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
            owner?.receive(token) { $0.clearLogs() }
        }

        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
            guard let messageList else { return }
            var entries: [(Int32, String)] = []
            while messageList.hasNext() {
                if let entry = messageList.next() { entries.append((entry.level, entry.message)) }
            }
            if !entries.isEmpty { owner?.receive(token) { $0.append(entries) } }
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
            guard let events else { return }
            owner?.receive(token) { $0.apply(events) }
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

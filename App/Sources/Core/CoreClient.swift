import Foundation
import Libbox
import Observation
import TunnelKit

/// Live data from the running core: speed, totals, memory, connections and
/// the log, over the Libbox command socket.
@MainActor
@Observable
final class CoreClient {
    struct Status: Equatable {
        var uplink: Int64 = 0
        var downlink: Int64 = 0
        var uplinkTotal: Int64 = 0
        var downlinkTotal: Int64 = 0
        var memory: Int64 = 0
        var connections: Int32 = 0
    }

    struct SpeedSample: Identifiable, Equatable {
        let id: Int
        let date: Date
        let up: Int64
        let down: Int64
    }

    struct ConnectionItem: Identifiable, Equatable {
        let id: String
        let destination: String
        let network: String
        let outbound: String
        let outboundType: String
        let rule: String
        let upload: Int64
        let download: Int64
        let createdAt: Date
        let isClosed: Bool
    }

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let level: Int32
        let message: String
    }

    private(set) var status: Status?
    private(set) var history: [SpeedSample] = []
    private(set) var connections: [ConnectionItem] = []
    private(set) var logs: [LogLine] = []
    private(set) var isConnected = false

    /// Analytics wants the connection list; it costs the extension some work.
    var wantsConnections = false {
        didSet { if oldValue != wantsConnections, isRunning { restart() } }
    }

    var wantsLogs = false {
        didSet { if oldValue != wantsLogs, isRunning { restart() } }
    }

    @ObservationIgnored private var client: LibboxCommandClient?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var sampleCounter = 0
    @ObservationIgnored private var logCounter = 0
    @ObservationIgnored private var connectionStore: LibboxConnections?
    @ObservationIgnored var onStatus: ((Status) -> Void)?
    /// Memory of the extension, read by the latency test from any thread.
    nonisolated let extensionMemory = AtomicInt64()
    @ObservationIgnored private var alive: AliveFlag?

    static let historyLength = 120
    static let logCapacity = 1500

    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        disconnectClient()
        status = nil
        isConnected = false
    }

    func resetSession() {
        history.removeAll()
        connections.removeAll()
        connectionStore = nil
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func restart() {
        disconnectClient()
        connect()
    }

    private func disconnectClient() {
        generation += 1
        alive?.isAlive = false
        alive = nil
        if let client {
            Task.detached { try? client.disconnect() }
        }
        client = nil
    }

    private func connect() {
        generation += 1
        let token = generation
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        if wantsConnections { options.addCommand(LibboxCommandConnections) }
        if wantsLogs { options.addCommand(LibboxCommandLog) }
        options.statusInterval = Int64(NSEC_PER_SEC)
        let handler = Handler(owner: self, token: token)
        guard let client = LibboxNewCommandClient(handler, options) else { return }
        self.client = client
        let flag = AliveFlag()
        alive = flag
        Task.detached {
            // The socket appears a moment after the tunnel reports "connected".
            for _ in 0 ..< 10 {
                guard flag.isAlive else { return }
                do {
                    try client.connect()
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    // MARK: Updates from the handler

    fileprivate func receive(_ token: Int, _ update: @MainActor (CoreClient) -> Void) {
        guard token == generation else { return }
        update(self)
    }

    fileprivate func apply(status message: Status) {
        status = message
        extensionMemory.value = message.memory
        sampleCounter += 1
        history.append(SpeedSample(id: sampleCounter, date: Date(), up: message.uplink, down: message.downlink))
        if history.count > CoreClient.historyLength { history.removeFirst(history.count - CoreClient.historyLength) }
        onStatus?(message)
    }

    fileprivate func apply(logs entries: [(Int32, String)]) {
        for (level, message) in entries {
            logCounter += 1
            logs.append(LogLine(id: logCounter, level: level, message: Redactor.redact(message)))
        }
        if logs.count > CoreClient.logCapacity { logs.removeFirst(logs.count - CoreClient.logCapacity) }
    }

    fileprivate func apply(events: LibboxConnectionEvents) {
        if connectionStore == nil { connectionStore = LibboxNewConnections() }
        guard let store = connectionStore else { return }
        store.apply(events)
        store.sortByDate()
        var items: [ConnectionItem] = []
        if let iterator = store.iterator() {
            while iterator.hasNext() {
                guard let connection = iterator.next() else { continue }
                if connection.outboundType == "dns" { continue }
                items.append(ConnectionItem(
                    id: connection.id_,
                    destination: connection.displayDestination(),
                    network: connection.network,
                    outbound: connection.outbound,
                    outboundType: connection.outboundType,
                    rule: connection.rule,
                    upload: connection.uplinkTotal,
                    download: connection.downlinkTotal,
                    createdAt: Date(timeIntervalSince1970: Double(connection.createdAt) / 1000),
                    isClosed: connection.closedAt > 0
                ))
                if items.count >= 300 { break }
            }
        }
        connections = items
    }

    fileprivate func setConnected(_ value: Bool) {
        isConnected = value
    }

    // MARK: Handler

    private final class Handler: NSObject, LibboxCommandClientHandlerProtocol {
        weak var owner: CoreClient?
        let token: Int

        init(owner: CoreClient, token: Int) {
            self.owner = owner
            self.token = token
        }

        private func deliver(_ update: @escaping @MainActor (CoreClient) -> Void) {
            let token = self.token
            let target = owner
            DispatchQueue.main.async { [weak target] in
                MainActor.assumeIsolated {
                    target?.receive(token, update)
                }
            }
        }

        func connected() {
            deliver { $0.setConnected(true) }
        }

        func disconnected(_: String?) {
            deliver { $0.setConnected(false) }
        }

        func setDefaultLogLevel(_: Int32) {}

        func clearLogs() {
            deliver { $0.clearLogs() }
        }

        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
            guard let messageList else { return }
            var entries: [(Int32, String)] = []
            while messageList.hasNext() {
                guard let entry = messageList.next() else { continue }
                entries.append((entry.level, entry.message))
            }
            guard !entries.isEmpty else { return }
            deliver { $0.apply(logs: entries) }
        }

        func writeStatus(_ message: LibboxStatusMessage?) {
            guard let message else { return }
            let status = Status(
                uplink: message.uplink,
                downlink: message.downlink,
                uplinkTotal: message.uplinkTotal,
                downlinkTotal: message.downlinkTotal,
                memory: message.memory,
                connections: message.connectionsOut
            )
            deliver { $0.apply(status: status) }
        }

        func writeGroups(_: (any LibboxOutboundGroupIteratorProtocol)?) {}

        func writeOutbounds(_: (any LibboxOutboundGroupItemIteratorProtocol)?) {}

        func initializeClashMode(_: (any LibboxStringIteratorProtocol)?, currentMode _: String?) {}

        func updateClashMode(_: String?) {}

        func write(_ events: LibboxConnectionEvents?) {
            guard let events else { return }
            deliver { $0.apply(events: events) }
        }

        func write(_: LibboxDnsQuery?) {}
    }
}

/// Tells a background connection attempt whether it is still wanted.
final class AliveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = true

    var isAlive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// A lock-protected integer shared across threads.
final class AtomicInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0

    var value: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

import Darwin
import os
import Foundation
import Libbox
import Network
import NetworkExtension
import TunnelCore

/// Runs the sing-box core inside the Network Extension.
///
/// The configuration comes from the start options when the app starts the tunnel
/// and from the shared container when the system does (on demand, Settings,
/// Control Center).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "personaltunnel.tunnel")
    private var commandServer: LibboxCommandServer?
    private lazy var platform = TunnelPlatform(provider: self)
    private var paths: SharedPaths?
    private static var coreIsSetUp = false
    /// Memory written to the service log once a minute (3.0 beta: measuring the
    /// extension with both cores linked in).
    private var memoryTimer: DispatchSourceTimer?
    #if TUNNEL_XRAY
    /// Xray-core for the servers only it can run, beside sing-box.
    private var xray: PtbridgeXrayInstance?
    #endif
    /// The physical network Xray's connections are bound to; a change restarts Xray.
    private var xrayPath: NWPathMonitor?
    private var xrayInterface: String?
    private var memoryPeak: Double = 0
    /// The last memory line written to the extension's log (3.0.6: it is sampled
    /// every 15 s, written when it moves by a megabyte or every ten minutes).
    private var memoryLogged: MemorySample?
    private var memoryFreedAt: Date?

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            let defaults = AppGroup.defaults
            do {
                try self.start(options: options)
                defaults.removeObject(forKey: SharedKey.lastTunnelError)
                defaults.set(Date().timeIntervalSince1970, forKey: SharedKey.tunnelStartedAt)
                let core = Bundle.main.object(forInfoDictionaryKey: "PersonalTunnelCore") as? String ?? "?"
                self.event("запуск, ядро \(core)")
                self.log("ядро расширения: \(core)")
                self.startMemoryLog()
                completionHandler(nil)
            } catch {
                let message = Redactor.redact(error.localizedDescription)
                defaults.set(message, forKey: SharedKey.lastTunnelError)
                self.event("запуск не удался: \(message)")
                self.shutDown()
                completionHandler(TunnelError(message))
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.log("остановка, причина \(reason.rawValue)")
            self.event("остановка, причина \(reason.rawValue)")
            self.shutDown()
            AppGroup.defaults.removeObject(forKey: SharedKey.tunnelStartedAt)
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            guard String(data: messageData, encoding: .utf8) == TunnelIPC.reloadMessage else {
                completionHandler?(Data("unknown".utf8))
                return
            }
            do {
                try self.reload()
                self.event("перезагрузка конфигурации")
                self.sampleMemory()
                completionHandler?(nil)
            } catch {
                let message = Redactor.redact(error.localizedDescription)
                AppGroup.defaults.set(message, forKey: SharedKey.lastTunnelError)
                self.event("перезагрузка не удалась: \(message)")
                completionHandler?(Data(message.utf8))
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        commandServer?.pause()
        completionHandler()
    }

    override func wake() {
        commandServer?.wake()
    }

    // MARK: Core

    private func start(options: [String: NSObject]?) throws {
        guard let container = AppGroup.containerURL else {
            throw TunnelError("Нет доступа к общей группе приложения (\(AppGroup.identifier)). Проверьте подпись приложения и расширения.")
        }
        let paths = SharedPaths(container: container)
        try paths.prepare()
        self.paths = paths
        let configuration = try loadConfiguration(options, paths: paths)
        try setUpCore(paths)
        try startCommandServer()
        try startXray(paths)
        try startService(configuration)
    }

    private func setUpCore(_ paths: SharedPaths) throws {
        guard !PacketTunnelProvider.coreIsSetUp else { return }
        let options = LibboxSetupOptions()
        options.basePath = paths.base.path
        options.workingPath = paths.working.path
        options.tempPath = paths.temp.path
        options.crashReportSource = "packet-tunnel"
        options.logMaxLines = 1000
        // The extension has about 50 MiB: let the core watch its own memory, and
        // collect garbage earlier than its default (40 MiB, 4/5 of the limit given):
        // with Xray-core linked in the footprint reached 38 MiB under load.
        options.oomKillerEnabled = true
        options.oomMemoryLimit = 42 * 1024 * 1024
        var error: NSError?
        LibboxSetup(options, &error)
        if let error { throw TunnelError("Ядро не инициализировалось: \(error.localizedDescription)") }
        #if TUNNEL_XRAY
        // 3.0.6: with a limit of its own the core leaves Go's heap growth at 100%;
        // a night of backups through the tunnel could double the heap before a
        // collection. 50% is what the core itself uses in an extension.
        _ = PtbridgeSetGCPercent(50)
        #endif
        PacketTunnelProvider.coreIsSetUp = true
    }

    private func startCommandServer() throws {
        guard commandServer == nil else { return }
        var error: NSError?
        let server = LibboxNewCommandServer(platform, platform, &error)
        if let error { throw TunnelError("Командный сервер не создан: \(error.localizedDescription)") }
        guard let server else { throw TunnelError("Командный сервер не создан.") }
        try server.start()
        commandServer = server
    }

    private func startService(_ configuration: String) throws {
        guard let commandServer else { throw TunnelError("Командный сервер не запущен.") }
        let rules = Bundle.main.resourceURL?.appendingPathComponent("Rules", isDirectory: true).path ?? ""
        let document = try JSONValue.parse(configuration)
        let relocated = ConfigBuilder.relocateRuleSets(in: document, directory: rules).serialized()
        try commandServer.startOrReloadService(relocated, options: LibboxOverrideOptions())
    }

    /// (Re)starts Xray-core when the subscription has servers only it can run.
    private func startXray(_ paths: SharedPaths) throws {
        stopXray()
        guard let data = try? Data(contentsOf: paths.activeXrayConfig), !data.isEmpty,
              let runtime = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            stopWatchingPath()
            return
        }
        #if TUNNEL_XRAY
        let interface = watchPath(paths)
        try? Data().write(to: paths.xrayLog)
        let config = XrayBacked.prepare(runtime, interface: interface, logPath: paths.xrayLog.path)
        var error: NSError?
        let instance = PtbridgeStartXray(config.serialized(), &error)
        if let error { throw TunnelError("Xray-core не запустился: \(error.localizedDescription)") }
        xray = instance
        event("Xray-core запущен, интерфейс \(interface ?? "—")")
        #else
        event("в подписке есть серверы Xray, но расширение собрано без Xray-core")
        #endif
    }

    private func stopXray() {
        #if TUNNEL_XRAY
        xray?.close()
        xray = nil
        #endif
    }

    /// The current physical interface (Wi-Fi, cellular), and a restart of Xray on
    /// the queue when it changes. Interfaces of type `other` (tunnels) never count.
    private func watchPath(_ paths: SharedPaths) -> String? {
        if xrayPath == nil {
            let monitor = NWPathMonitor()
            let first = DispatchSemaphore(value: 0)
            let once = OnceFlag()
            monitor.pathUpdateHandler = { [weak self] path in
                let name = PacketTunnelProvider.physical(path)
                if once.claim() {
                    self?.xrayInterface = name
                    first.signal()
                    return
                }
                self?.queue.async {
                    guard let self, self.xray != nil, name != self.xrayInterface, let name else { return }
                    self.xrayInterface = name
                    self.event("сеть сменилась (\(name)): перезапуск Xray-core")
                    try? self.startXray(paths)
                }
            }
            monitor.start(queue: DispatchQueue(label: "personaltunnel.xray-path", qos: .utility))
            xrayPath = monitor
            _ = first.wait(timeout: .now() + 2)
        }
        return xrayInterface ?? xrayPath.map { PacketTunnelProvider.physical($0.currentPath) } ?? nil
    }

    private func stopWatchingPath() {
        xrayPath?.cancel()
        xrayPath = nil
        xrayInterface = nil
    }

    private static func physical(_ path: Network.NWPath) -> String? {
        guard path.status != .unsatisfied else { return nil }
        return path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }?.name
    }

    /// Reads the stored configuration again; called by the app and by the core.
    func reload() throws {
        guard let paths else { throw TunnelError("Туннель не запущен.") }
        reasserting = true
        defer { reasserting = false }
        try startXray(paths)
        try startService(try readStoredConfiguration(paths))
    }

    /// Called by the core when it stops itself.
    func closeService() {
        do {
            try commandServer?.closeService()
        } catch {
            log("закрытие службы: \(error.localizedDescription)", level: .error)
        }
        platform.reset()
    }

    private func shutDown() {
        memoryTimer?.cancel()
        memoryTimer = nil
        closeService()
        stopXray()
        stopWatchingPath()
        commandServer?.close()
        commandServer = nil
    }

    /// A line in the extension's own log, which outlives it (see `TunnelEvents`).
    private func event(_ message: String) {
        guard let paths = paths ?? AppGroup.containerURL.map(SharedPaths.init) else { return }
        TunnelEvents.append(Redactor.redact(message), to: TunnelEvents.file(paths))
    }

    // MARK: Memory

    private func startMemoryLog() {
        memoryTimer?.cancel()
        memoryPeak = 0
        memoryLogged = nil
        sampleMemory()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.sampleMemory() }
        timer.resume()
        memoryTimer = timer
    }

    /// `phys_footprint` is what the system holds against the extension's limit.
    private func sampleMemory() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }
        let mib = 1024.0 * 1024.0
        let used = Double(info.phys_footprint) / mib
        memoryPeak = max(memoryPeak, used, Double(info.ledger_phys_footprint_peak) / mib)
        let available = Double(os_proc_available_memory()) / mib
        let sample = MemorySample(used: used, peak: memoryPeak, available: available)
        // Kept for the app at every sample: if the system ends the extension, the
        // last one is at most 15 s old.
        AppGroup.defaults.set(sample.encoded(), forKey: SharedKey.tunnelMemory)
        if available > 0, available < 10 { relieveMemory(sample) }
        guard memoryLogged.map({ sample.differs(from: $0) }) ?? true else { return }
        memoryLogged = sample
        commandServer?.writeMessage(4, message: sample.line)
        event(sample.line)
    }

    /// Close to the limit: the core returns what it can to the system at once,
    /// at most once a minute, and the log says so.
    private func relieveMemory(_ sample: MemorySample) {
        if let last = memoryFreedAt, Date().timeIntervalSince(last) < 60 { return }
        memoryFreedAt = Date()
        #if TUNNEL_XRAY
        PtbridgeFreeMemory()
        #endif
        log(sample.line, level: .warn)
        event(sample.line)
    }

    /// The core's numbering (sing-box `log.Level`): 0 panic, 1 fatal, 2 error,
    /// 3 warn, 4 info, 5 debug, 6 trace. The extension's own notes are info; only
    /// a real failure is an error (these lines used level 2 and so read as ERROR).
    enum LogLevel: Int32 {
        case error = 2
        case warn = 3
        case info = 4
    }

    func log(_ message: String, level: LogLevel = .info) {
        commandServer?.writeMessage(level.rawValue, message: "(tunnel) " + Redactor.redact(message))
    }

    // MARK: Configuration

    private func loadConfiguration(_ options: [String: NSObject]?, paths: SharedPaths) throws -> String {
        if let text = options?[TunnelIPC.configOption] as? String, !text.isEmpty { return text }
        return try readStoredConfiguration(paths)
    }

    private func readStoredConfiguration(_ paths: SharedPaths) throws -> String {
        guard let data = try? Data(contentsOf: paths.activeConfig), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw TunnelError("Нет сохранённой конфигурации. Откройте Personal Tunnel и выберите сервер.")
        }
        return text
    }
}

struct TunnelError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

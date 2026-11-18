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
    private let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "personaltunnel.tunnel")
        queue.setSpecific(key: PacketTunnelProvider.queueKey, value: ())
        return queue
    }()

    private static let queueKey = DispatchSpecificKey<Void>()
    /// 3.2.4: the tunnel is stopping; the cores may still be closing off the queue.
    private var stopping = false
    private var commandServer: LibboxCommandServer?
    private lazy var platform = TunnelPlatform(provider: self)
    private var paths: SharedPaths?
    private static var coreIsSetUp = false
    /// Memory written to the service log once a minute (3.0 beta: measuring the
    /// extension with both cores linked in).
    private var memoryTimer: DispatchSourceTimer?
    /// The memory sample last written for the app (3.2.9).
    private var memoryStored: MemorySample?
    #if TUNNEL_XRAY
    /// Xray-core for the servers only it can run, beside sing-box.
    private var xray: PtbridgeXrayInstance?
    #endif
    /// The Xray configuration of the running tunnel; a network change restarts
    /// Xray with it.
    private var xrayRuntime: JSONValue?
    /// The core's log level now (3.3, PT-16): «info» ends with the diagnostic half hour.
    private var logLevel: String?
    /// The physical network Xray's connections are bound to; a change restarts Xray.
    private var xrayPath: NWPathMonitor?
    private var xrayInterface: String?
    private var memoryPeak: Double = 0
    /// The last memory line written to the extension's log (3.0.6: it is sampled
    /// every 15 s, written when it moves by a megabyte or every ten minutes).
    private var memoryLogged: MemorySample?
    private var memoryFreedAt: Date?
    private var memoryStartedAt: Date?

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            let defaults = AppGroup.defaults
            // 3.1.8: an error left by an earlier start is not this start's.
            defaults.removeObject(forKey: SharedKey.lastTunnelError)
            // 3.1.12: marked before the core starts, not after. An extension that
            // died inside the start (a Go panic, the memory limit) left no trace:
            // the app showed «connecting», then «not connected», and nothing else.
            // Now the app reports the end with the core's own words.
            defaults.set(Date().timeIntervalSince1970, forKey: SharedKey.tunnelStartedAt)
            // 3.3 beta 4: an extension of an older build ended by installing a newer
            // one is not a crash.
            defaults.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, forKey: SharedKey.tunnelStartedBuild)
            do {
                try self.start(options: options)
                defaults.removeObject(forKey: SharedKey.lastTunnelError)
                let core = Bundle.main.object(forInfoDictionaryKey: "PersonalTunnelCore") as? String ?? "?"
                self.event("запуск, ядро \(core)")
                self.log("ядро расширения: \(core)")
                self.startMemoryLog()
                completionHandler(nil)
            } catch {
                let message = Redactor.redact(error.localizedDescription)
                defaults.set(message, forKey: SharedKey.lastTunnelError)
                defaults.removeObject(forKey: SharedKey.tunnelStartedAt)
                self.event("запуск не удался: \(message)")
                self.shutDown()
                completionHandler(TunnelError(message).bridged)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            // 3.3 beta 4: marked as stopped before the core is closed, not after: an
            // update (stop reason 9) ends the process while the core is closing, and
            // the app then reported a tunnel the system had ended without a stop.
            AppGroup.defaults.removeObject(forKey: SharedKey.tunnelStartedAt)
            self.stopping = true
            self.log("остановка, причина \(reason.rawValue)")
            self.event("остановка, причина \(reason.rawValue)")
            // 3.2.4: iOS shows the VPN off only after the completion handler. The
            // cores close their connections first; with connections still waiting on
            // a server (15 s each) that took seconds. They get 1.5 s, then the stop
            // goes on without them: the process ends right after anyway.
            let started = DispatchTime.now()
            let closed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                self.shutDown()
                closed.signal()
            }
            let inTime = closed.wait(timeout: .now() + 1.5) == .success
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
            let took = String(format: "%.1f", seconds)
            self.event(inTime ? "ядро закрыто за \(took) с" : "ядро закрывается дольше 1,5 с: остановка без ожидания")
            // 3.1.14: turned off by the owner (Control Center, Settings, the app) or
            // replaced by another VPN: iOS must not bring it back on demand. Control
            // Center left On Demand on, and the VPN came back a few seconds later.
            // A tunnel the system ends without stopping it (the memory limit) gets no
            // stop at all, so On Demand still restarts that one.
            guard reason == .userInitiated || reason == .superceded else {
                completionHandler()
                return
            }
            Self.disableOnDemand(completionHandler)
        }
    }

    /// Turns off this tunnel's On Demand in the system configuration, then calls back.
    private static func disableOnDemand(_ done: @escaping () -> Void) {
        let finish = OnceFlag()
        let complete = { if finish.claim() { done() } }
        // The stop is not held up for long whatever happens.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: complete)
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let own = Bundle.main.bundleIdentifier
            guard let manager = managers?.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == own }),
                  manager.isOnDemandEnabled else {
                complete()
                return
            }
            manager.isOnDemandEnabled = false
            manager.saveToPreferences { _ in complete() }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            guard String(data: messageData, encoding: .utf8) == TunnelIPC.reloadMessage else {
                completionHandler?(Data("unknown".utf8))
                return
            }
            if let message = self.reloadNoted() {
                completionHandler?(Data(message.utf8))
            } else {
                completionHandler?(Data(TunnelIPC.reloadDone.utf8))
            }
        }
    }

    /// The app asks over the core's command socket (3.3 beta 4; the system's
    /// message never arrived on the device). Runs on the queue like everything else;
    /// the app's call waits for it.
    func reloadForApp() throws {
        var failure: String?
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            failure = reloadNoted()
        } else {
            queue.sync { failure = self.reloadNoted() }
        }
        if let failure { throw TunnelError(failure).bridged }
    }

    /// Reloads and notes it in the extension's log; nil when the new configuration runs.
    private func reloadNoted() -> String? {
        do {
            try reload()
            event("перезагрузка конфигурации")
            sampleMemory()
            return nil
        } catch {
            let message = Redactor.redact(error.localizedDescription)
            AppGroup.defaults.set(message, forKey: SharedKey.lastTunnelError)
            event("перезагрузка не удалась: \(message)")
            return message
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
        let configuration = try withXray(try loadConfiguration(options, paths: paths), paths: paths)
        try setUpCore(paths)
        try startCommandServer()
        xrayRuntime = configuration.xray
        try startXray(paths)
        try startService(configuration.config)
    }

    /// sing-box's configuration and the Xray one beside it (when the subscription
    /// has servers only Xray-core runs). 3.3 beta 2: sing-box hands those servers'
    /// connections to Xray in this process (`xray-local`): no port, nothing secret.
    private func withXray(_ text: String, paths: SharedPaths) throws -> (config: JSONValue, xray: JSONValue?) {
        let config = try JSONValue.parse(text)
        guard let data = try? Data(contentsOf: paths.activeXrayConfig), !data.isEmpty,
              let runtime = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return (config, nil) }
        return (config, runtime)
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

    private func startService(_ document: JSONValue) throws {
        guard let commandServer else { throw TunnelError("Командный сервер не запущен.") }
        let rules = Bundle.main.resourceURL?.appendingPathComponent("Rules", isDirectory: true).path ?? ""
        // 3.1.7: the kill switch («include all networks») takes gVisor; sing-tun
        // refuses the `mixed` stack with it and the tunnel stopped at once.
        let until = AppGroup.defaults.double(forKey: SharedKey.diagnosticLogUntil)
        let leveled = ConfigBuilder.expireDiagnosticLog(in: document, until: until > 0 ? Date(timeIntervalSince1970: until) : nil)
        logLevel = leveled.at("log", "level")?.stringValue
        let includeAll = platform.includeAllNetworks()
        // 3.2.7: the app's loopback way out for its tests only while iOS holds the
        // kill switch on (without it the app's core leaves by the physical interface).
        let stacked = ConfigBuilder.probeExit(in: ConfigBuilder.stackForIncludeAllNetworks(in: leveled, includeAllNetworks: includeAll), keep: includeAll)
        do {
            try commandServer.startOrReloadService(ConfigBuilder.relocateRuleSets(in: stacked, directory: rules).serialized(), options: LibboxOverrideOptions())
            noteTunnelSettings(stacked)
        } catch where ConfigBuilder.hasProbeExit(stacked) {
            // Its port taken by something else: the tunnel matters more than the
            // app's tests (they then go through the connected server, as before).
            event("выход для проверок не открылся (\(Redactor.redact(error.localizedDescription))): туннель без него")
            let plain = ConfigBuilder.probeExit(in: stacked, keep: false)
            try commandServer.startOrReloadService(ConfigBuilder.relocateRuleSets(in: plain, directory: rules).serialized(), options: LibboxOverrideOptions())
            noteTunnelSettings(plain)
        }
    }

    /// 3.2.3: what the tunnel really started with — the stack and MTU the core
    /// got, and the system's «include all networks» (kill switch) and push
    /// exclusion as iOS holds them for this start, not as the app's setting says.
    private func noteTunnelSettings(_ config: JSONValue) {
        guard let tun = ConfigBuilder.tunSummary(of: config) else { return }
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        var pushExcluded = "?"
        if #available(iOS 16.4, *) { pushExcluded = (proto?.excludeAPNs ?? false) ? "on" : "off" }
        let killSwitch = (proto?.includeAllNetworks ?? false) ? "on" : "off"
        event("туннель: стек \(tun.stack), MTU \(tun.mtu), kill switch \(killSwitch), исключение push Apple \(pushExcluded)")
        if ConfigBuilder.hasProbeExit(config) { event("выход для проверок приложения открыт") }
    }

    /// (Re)starts Xray-core when the subscription has servers only it can run.
    private func startXray(_ paths: SharedPaths) throws {
        stopXray()
        guard let runtime = xrayRuntime else {
            stopWatchingPath()
            // 3.2.12: no Xray in this session: its log of an earlier one goes, or the
            // copied service log carried it as if it were now.
            try? FileManager.default.removeItem(at: paths.xrayLog)
            return
        }
        #if TUNNEL_XRAY
        let interface = watchPath(paths)
        try? Data().write(to: paths.xrayLog)
        let config = XrayBacked.prepare(runtime, interface: interface, logPath: paths.xrayLog.path)
        var error: NSError?
        let instance = PtbridgeStartXray(XrayBacked.tunnelInstance, config.serialized(), &error)
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
                    guard let self, !self.stopping, self.xray != nil, name != self.xrayInterface, let name else { return }
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
        let configuration = try withXray(try readStoredConfiguration(paths), paths: paths)
        // 3.3 beta 4: Xray-core keeps running when its part did not change (a change
        // between servers sing-box runs itself). Each restart left memory behind, and
        // five quick changes ended in a crash of the core.
        let sameXray = xray != nil && configuration.xray != nil && configuration.xray?.serialized() == xrayRuntime?.serialized()
        xrayRuntime = configuration.xray
        if !sameXray { try startXray(paths) }
        try startService(configuration.config)
        // What the previous instance held goes back to the system now, not at the
        // next collection: every reload added about 2 MiB on the device.
        #if TUNNEL_XRAY
        PtbridgeFreeMemory()
        #endif
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
        xrayRuntime = nil
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
        memoryStored = nil
        memoryStartedAt = Date()
        sampleMemory()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 3.1.6: once a minute with a generous leeway, so the system can fold the
        // wake-up into others (battery); it was every 15 s. 3.2.9: every 2
        // minutes, a minute of leeway.
        timer.schedule(deadline: .now() + 120, repeating: 120, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.sampleMemory()
            self?.endDiagnosticLogIfDue()
        }
        timer.resume()
        memoryTimer = timer
    }

    /// 3.3 (PT-16): the diagnostic half hour is over: back to «warn», even when the
    /// app is not running to say so.
    private func endDiagnosticLogIfDue() {
        guard logLevel == "info" else { return }
        let until = AppGroup.defaults.double(forKey: SharedKey.diagnosticLogUntil)
        guard until <= Date().timeIntervalSince1970 else { return }
        do {
            try reload()
            event("подробный журнал выключен: прошло 30 минут")
        } catch {
            log("подробный журнал: \(error.localizedDescription)", level: .warn)
        }
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
        // Kept for the app: if the system ends the extension, the last one says
        // how close to the limit it was. 3.2.9: written only when it changed (by
        // 1 MiB, or 10 minutes on), not at every sample — a write to the shared
        // settings file every minute, all day.
        if memoryStored.map({ sample.differs(from: $0) }) ?? true {
            AppGroup.defaults.set(sample.encoded(), forKey: SharedKey.tunnelMemory)
            memoryStored = sample
        }
        // 3.1.6: memory is handed back to the system before the limit is near
        // (iOS warns of pressure at about 40 MiB used), and every quarter of an
        // hour in a long session, so a night left on does not keep it.
        // 3.2.9: only when really near the limit (under 8 MiB left). At 13 MiB the
        // extension, sitting at 38–41 MiB with MTU 4064, forced a full collection
        // and handed its memory back every 2 minutes all day, only to take it
        // again (battery).
        if available > 0, available < 8 {
            relieveMemory(sample, every: 120)
        } else if let last = memoryFreedAt ?? memoryStartedAt, Date().timeIntervalSince(last) > 900 {
            relieveMemory(sample, every: 900, quiet: true)
        }
        guard memoryLogged.map({ sample.differs(from: $0) }) ?? true else { return }
        memoryLogged = sample
        // 3.2.12: only in the extension's own log, no longer in the service log as
        // well: a line for every megabyte crowded it out (analytics shows the memory;
        // near the limit `relieveMemory` still writes a warning there).
        event(sample.line)
    }

    /// Close to the limit: the core returns what it can to the system at once,
    /// at most once a minute, and the log says so.
    private func relieveMemory(_ sample: MemorySample, every interval: TimeInterval, quiet: Bool = false) {
        if let last = memoryFreedAt, Date().timeIntervalSince(last) < interval { return }
        memoryFreedAt = Date()
        #if TUNNEL_XRAY
        PtbridgeFreeMemory()
        #endif
        guard !quiet else { return }
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

    /// 3.1.15: the error the system hands to the app. A Swift error crossed to the
    /// app without its text (PTBeta showed «PacketTunnel.TunnelError error 1»):
    /// the text has to be in the error's own `userInfo`.
    var bridged: NSError {
        NSError(domain: "PersonalTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

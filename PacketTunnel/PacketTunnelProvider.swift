import Darwin
import os
import Foundation
import Libbox
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
    private var memoryPeak: Double = 0

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            let defaults = AppGroup.defaults
            do {
                try self.start(options: options)
                defaults.removeObject(forKey: SharedKey.lastTunnelError)
                defaults.set(Date().timeIntervalSince1970, forKey: SharedKey.tunnelStartedAt)
                self.event("запуск")
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
        try startService(configuration)
    }

    private func setUpCore(_ paths: SharedPaths) throws {
        guard !PacketTunnelProvider.coreIsSetUp else { return }
        let options = LibboxSetupOptions()
        options.basePath = paths.base.path
        options.workingPath = paths.working.path
        options.tempPath = paths.temp.path
        options.crashReportSource = "packet-tunnel"
        options.logMaxLines = 3000
        // The extension has about 50 MiB: let the core watch its own memory.
        options.oomKillerEnabled = true
        var error: NSError?
        LibboxSetup(options, &error)
        if let error { throw TunnelError("Ядро не инициализировалось: \(error.localizedDescription)") }
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

    /// Reads the stored configuration again; called by the app and by the core.
    func reload() throws {
        guard let paths else { throw TunnelError("Туннель не запущен.") }
        reasserting = true
        defer { reasserting = false }
        try startService(try readStoredConfiguration(paths))
    }

    /// Called by the core when it stops itself.
    func closeService() {
        do {
            try commandServer?.closeService()
        } catch {
            log("закрытие службы: \(error.localizedDescription)")
        }
        platform.reset()
    }

    private func shutDown() {
        memoryTimer?.cancel()
        memoryTimer = nil
        closeService()
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
        sampleMemory()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
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
        AppGroup.defaults.set(sample.encoded(), forKey: SharedKey.tunnelMemory)
        commandServer?.writeMessage(2, message: sample.line)
        event(sample.line)
    }

    func log(_ message: String) {
        // Level 2 is "warn" in the core's numbering; visible at the default log level.
        commandServer?.writeMessage(2, message: "(tunnel) " + Redactor.redact(message))
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

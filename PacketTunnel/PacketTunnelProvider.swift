import Foundation
import Libbox
import NetworkExtension
import TunnelKit

/// Runs the sing-box core inside the Network Extension.
///
/// The configuration comes from the start options when the app starts the
/// tunnel, and from the shared container when the system starts it (on
/// demand, widget, Control Center, Shortcuts).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var commandServer: LibboxCommandServer?
    private lazy var platform = LibboxPlatform(provider: self)
    private static var coreIsSetUp = false

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?) async throws {
        SharedContainer.prepareDirectories()
        let defaults = SharedContainer.defaults
        defaults.removeObject(forKey: SharedKey.lastTunnelError)
        do {
            let configuration = try loadConfiguration(options)
            let ignoreMemoryLimit = (options?[TunnelStartKey.ignoreMemoryLimit] as? NSNumber)?.boolValue ?? false
            try setUpCore(ignoreMemoryLimit: ignoreMemoryLimit)
            try startCommandServer()
            try startService(configuration)
        } catch {
            let message = Redactor.redact(error.localizedDescription)
            defaults.set(message, forKey: SharedKey.lastTunnelError)
            writeLog("start failed: \(message)")
            stopCore()
            throw TunnelError(message)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeLog("stopping, reason \(reason.rawValue)")
        stopCore()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let text = String(data: messageData, encoding: .utf8), let message = TunnelMessage(rawValue: text) else {
            return Data("unknown message".utf8)
        }
        switch message {
        case .reload:
            do {
                let configuration = try readStoredConfiguration()
                reasserting = true
                defer { reasserting = false }
                try startService(configuration)
                return nil
            } catch {
                let message = Redactor.redact(error.localizedDescription)
                SharedContainer.defaults.set(message, forKey: SharedKey.lastTunnelError)
                return Data(message.utf8)
            }
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    // MARK: Core

    private func setUpCore(ignoreMemoryLimit: Bool) throws {
        guard !PacketTunnelProvider.coreIsSetUp else { return }
        let options = LibboxSetupOptions()
        options.basePath = SharedContainer.coreBaseDirectory.path
        options.workingPath = SharedContainer.coreWorkingDirectory.path
        options.tempPath = SharedContainer.cacheDirectory.path
        options.crashReportSource = "packet-tunnel"
        options.logMaxLines = 3000
        options.oomKillerEnabled = !ignoreMemoryLimit
        options.oomKillerDisabled = ignoreMemoryLimit
        var error: NSError?
        LibboxSetup(options, &error)
        if let error { throw TunnelError("setup: \(error.localizedDescription)") }
        PacketTunnelProvider.coreIsSetUp = true
    }

    private func startCommandServer() throws {
        if commandServer != nil { return }
        var error: NSError?
        let server = LibboxNewCommandServer(platform, platform, &error)
        if let error { throw TunnelError("command server: \(error.localizedDescription)") }
        guard let server else { throw TunnelError("command server unavailable") }
        try server.start()
        commandServer = server
    }

    private func startService(_ configuration: String) throws {
        guard let commandServer else { throw TunnelError("command server is not running") }
        let ruleSets = Bundle.main.resourceURL?.appendingPathComponent("Rules", isDirectory: true).path ?? ""
        let relocated = (try? ConfigBuilder.relocatingRuleSets(in: configuration, to: ruleSets)) ?? configuration
        try commandServer.startOrReloadService(relocated, options: LibboxOverrideOptions())
    }

    /// Called by the core when it stops itself.
    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeLog("close service: \(error.localizedDescription)")
        }
        platform.reset()
    }

    func reloadService() throws {
        try startService(readStoredConfiguration())
    }

    private func stopCore() {
        stopService()
        commandServer?.close()
        commandServer = nil
    }

    func writeLog(_ message: String) {
        commandServer?.writeMessage(2, message: "(tunnel) " + Redactor.redact(message))
    }

    // MARK: Configuration

    private func loadConfiguration(_ options: [String: NSObject]?) throws -> String {
        if let configuration = options?[TunnelStartKey.configuration] as? String, !configuration.isEmpty {
            return configuration
        }
        return try readStoredConfiguration()
    }

    private func readStoredConfiguration() throws -> String {
        let url = SharedContainer.activeConfigurationURL
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
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

import Foundation
import NetworkExtension
import Observation
import TunnelKit

/// The system VPN profile of the app and the state of its connection.
@MainActor
@Observable
final class TunnelController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var connectedDate: Date?
    private(set) var hasProfile = false

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored var onStatusChange: ((NEVPNStatus, NEVPNStatus) -> Void)?

    var isConnected: Bool { status == .connected }
    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }
    var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    /// Bundle identifier of the packet tunnel inside this app.
    static let providerBundleIdentifier: String = {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        {
            for item in items where item.pathExtension == "appex" {
                guard let bundle = Bundle(url: item),
                      let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                      ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel",
                      let identifier = bundle.bundleIdentifier
                else { continue }
                return identifier
            }
        }
        return (Bundle.main.bundleIdentifier ?? "com.personaltunnelapp") + ".SingBoxPacketTunnel"
    }()

    /// The `Rules` directory of the packet tunnel bundle.
    static var ruleSetDirectory: String {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        {
            for item in items where item.pathExtension == "appex" {
                let rules = item.appendingPathComponent("Rules", isDirectory: true)
                if FileManager.default.fileExists(atPath: rules.path) { return rules.path }
            }
        }
        return SharedContainer.directory.appendingPathComponent("Rules").path
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let ours = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == TunnelController.providerBundleIdentifier }
            attach(ours ?? managers.first)
        } catch {
            attach(nil)
        }
    }

    private func attach(_ manager: NETunnelProviderManager?) {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        statusObserver = nil
        self.manager = manager
        hasProfile = manager != nil
        guard let manager else {
            update(.invalid, connectedDate: nil)
            return
        }
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let connection = self.manager?.connection else { return }
                self.update(connection.status, connectedDate: connection.connectedDate)
            }
        }
        update(manager.connection.status, connectedDate: manager.connection.connectedDate)
    }

    private func update(_ newStatus: NEVPNStatus, connectedDate: Date?) {
        let old = status
        status = newStatus
        self.connectedDate = newStatus == .connected ? connectedDate : nil
        if old != newStatus { onStatusChange?(old, newStatus) }
    }

    /// Creates or updates the VPN profile with the current Network Extension
    /// settings. The first save asks the user to allow the VPN configuration.
    private func preparedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = TunnelController.providerBundleIdentifier
        configuration.serverAddress = "Personal Tunnel"
        configuration.disconnectOnSleep = false
        let defaults = SharedContainer.defaults
        configuration.includeAllNetworks = defaults.bool(forKey: SharedKey.includeAllNetworks)
        configuration.excludeLocalNetworks = defaults.object(forKey: SharedKey.excludeLocalNetworks) as? Bool ?? true
        if #available(iOS 16.4, *) {
            configuration.excludeAPNs = defaults.object(forKey: SharedKey.excludeAPNs) as? Bool ?? true
            configuration.excludeCellularServices = defaults.object(forKey: SharedKey.excludeCellularServices) as? Bool ?? true
        }
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Personal Tunnel"
        manager.isEnabled = true
        applyOnDemand(to: manager)
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if self.manager !== manager { attach(manager) }
        return manager
    }

    private func applyOnDemand(to manager: NETunnelProviderManager) {
        let defaults = SharedContainer.defaults
        let enabled = defaults.bool(forKey: SharedKey.onDemand)
        var rules: [NEOnDemandRule] = []
        let trusted = defaults.stringArray(forKey: SharedKey.onDemandTrustedSSIDs) ?? []
        if !trusted.isEmpty {
            let disconnect = NEOnDemandRuleDisconnect()
            disconnect.interfaceTypeMatch = .wiFi
            disconnect.ssidMatch = trusted
            rules.append(disconnect)
        }
        let connect = NEOnDemandRuleConnect()
        connect.interfaceTypeMatch = .any
        rules.append(connect)
        manager.onDemandRules = rules
        manager.isOnDemandEnabled = enabled
    }

    /// Saves changed Network Extension settings (on-demand, routing) to the profile.
    func applySettings() async {
        guard manager != nil else { return }
        _ = try? await preparedManager()
    }

    func start(configuration: String, serverName: String) async throws {
        let manager = try await preparedManager()
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelError(L("VPN-профиль недоступен."))
        }
        let options: [String: NSObject] = [
            TunnelStartKey.configuration: configuration as NSString,
            TunnelStartKey.serverName: serverName as NSString,
        ]
        try session.startTunnel(options: options)
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Turns on-demand off before stopping, otherwise iOS reconnects at once.
    func stopDisablingOnDemand() async {
        if let manager, manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
        }
        stop()
    }

    func send(_ message: TunnelMessage) async -> String? {
        guard let session = manager?.connection as? NETunnelProviderSession, isActive else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(message.rawValue.utf8)) { response in
                    continuation.resume(returning: response.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }

    func removeProfile() async {
        guard let manager else { return }
        try? await manager.removeFromPreferences()
        attach(nil)
    }
}

struct TunnelError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

import Foundation
import NetworkExtension
import TunnelCore

enum TunnelState: Equatable {
    case disconnected, connecting, connected, disconnecting, reasserting

    var isOn: Bool { self == .connected || self == .reasserting }
    var isBusy: Bool { self == .connecting || self == .disconnecting || self == .reasserting }
}

struct TunnelCrash: Equatable {
    var cause: String
    var details: String
}

/// Owns the system VPN configuration and starts and stops the tunnel.
final class TunnelController {
    let state = Observable<TunnelState>(.disconnected)
    /// Time the current session started, when connected.
    let connectedSince = Observable<Date?>(nil)
    /// Last start error, shown once.
    let lastError = Observable<String?>(nil)
    /// The tunnel ended without being stopped (the system ended the extension or
    /// the core fell): why, and the extension's last lines. Shown once.
    let crash = Observable<TunnelCrash?>(nil)
    /// The system's VPN configuration has been read: `state` is the real one.
    let loaded = Observable(false)

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let connection = note.object as? NEVPNConnection, connection === self.manager?.connection else { return }
            self.sync()
        }
        load { _ in }
    }

    /// Bundle identifier of the embedded packet tunnel, read from the app itself
    /// so that a re-signed build with renamed identifiers still finds it.
    private static var providerIdentifier: String {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        {
            for item in items where item.pathExtension == "appex" {
                if let bundle = Bundle(url: item),
                   (bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel",
                   let identifier = bundle.bundleIdentifier
                {
                    return identifier
                }
            }
        }
        return (Bundle.main.bundleIdentifier ?? "com.personaltunnelapp") + ".SingBoxPacketTunnel"
    }

    private func load(_ completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.manager = managers?.first
                self.sync()
                self.loaded.set(true)
                completion(self.manager)
            }
        }
    }

    private func sync() {
        let status = manager?.connection.status ?? .disconnected
        let next: TunnelState
        switch status {
        case .connected: next = .connected
        case .connecting: next = .connecting
        case .disconnecting: next = .disconnecting
        case .reasserting: next = .reasserting
        default: next = .disconnected
        }
        if next.isOn {
            if connectedSince.value == nil { connectedSince.value = manager?.connection.connectedDate ?? Date() }
        } else if next == .disconnected, connectedSince.value != nil {
            connectedSince.value = nil
        }
        if next == .disconnected, state.value == .connecting || state.value == .connected {
            if let message = AppGroup.defaults.string(forKey: SharedKey.lastTunnelError), !message.isEmpty {
                AppGroup.defaults.removeObject(forKey: SharedKey.lastTunnelError)
                lastError.value = message
            }
        }
        state.set(next)
        if next == .disconnected { checkAbnormalEnd() }
    }

    /// The extension clears its start time when it is stopped. Still there with the
    /// tunnel down means the system ended it without a stop.
    private func checkAbnormalEnd() {
        let defaults = AppGroup.defaults
        let started = defaults.double(forKey: SharedKey.tunnelStartedAt)
        guard started > 0 else { return }
        defaults.removeObject(forKey: SharedKey.tunnelStartedAt)
        let startDate = Date(timeIntervalSince1970: started)
        let memory = MemorySample.decode(defaults.data(forKey: SharedKey.tunnelMemory))
        let paths = AppGroup.containerURL.map(SharedPaths.init)
        let events = paths.map { TunnelEvents.read(TunnelEvents.file($0)) } ?? []
        // The core writes a Go panic to this file; it is archived at the next start.
        var coreCrash: String?
        if let paths {
            let url = paths.working.appendingPathComponent("CrashReport-packet-tunnel.log")
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified >= startDate.addingTimeInterval(-60),
               let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                coreCrash = text
            }
        }
        let report = { [weak self] (reason: String?) in
            let text = CrashReport.text(startedAt: startDate, systemReason: reason, memory: memory, events: events, coreCrash: coreCrash)
            self?.crash.value = TunnelCrash(cause: text.cause, details: text.details)
        }
        guard let connection = manager?.connection else { report(nil); return }
        connection.fetchLastDisconnectError { error in
            DispatchQueue.main.async { report(error.map { Redactor.redact($0.localizedDescription) }) }
        }
    }

    /// Writes the app's routing choices into the system configuration.
    private func configure(_ manager: NETunnelProviderManager) {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelController.providerIdentifier
        proto.serverAddress = "Personal Tunnel"
        proto.includeAllNetworks = false
        proto.excludeLocalNetworks = Prefs.localNetwork
        proto.enforceRoutes = Prefs.secureDNS
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Personal Tunnel"
        manager.isEnabled = true
        if Prefs.autoConnect {
            let wifi = NEOnDemandRuleConnect()
            wifi.interfaceTypeMatch = .wiFi
            let cellular = NEOnDemandRuleConnect()
            cellular.interfaceTypeMatch = .cellular
            manager.onDemandRules = Prefs.unknownWiFi ? [wifi, cellular] : [cellular]
            manager.isOnDemandEnabled = true
        } else {
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false
        }
    }

    private func prepared(_ completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
        load { [weak self] existing in
            guard let self else { return }
            let manager = existing ?? NETunnelProviderManager()
            self.configure(manager)
            manager.saveToPreferences { error in
                if let error {
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                // A freshly saved configuration must be loaded again before use.
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        if let error { completion(.failure(error)); return }
                        self.manager = manager
                        completion(.success(manager))
                    }
                }
            }
        }
    }

    func start(config: String) {
        state.set(.connecting)
        prepared { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.lastError.value = error.localizedDescription
                self.sync()
            case let .success(manager):
                do {
                    try manager.connection.startVPNTunnel(options: [TunnelIPC.configOption: config as NSString])
                } catch {
                    self.lastError.value = error.localizedDescription
                }
                self.sync()
            }
        }
    }

    func stop() {
        guard let manager else { return }
        // Otherwise on-demand brings the tunnel straight back.
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            manager.saveToPreferences { _ in manager.connection.stopVPNTunnel() }
        } else {
            manager.connection.stopVPNTunnel()
        }
    }

    /// Applies changed routing switches to the stored configuration.
    func applySettings() {
        guard manager != nil else { return }
        prepared { _ in }
    }

    /// Asks the running tunnel to load the stored configuration again.
    func reload(_ completion: @escaping (String?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession, state.value.isOn else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(Data(TunnelIPC.reloadMessage.utf8)) { response in
                DispatchQueue.main.async {
                    completion(response.flatMap { String(data: $0, encoding: .utf8) })
                }
            }
        } catch {
            completion(error.localizedDescription)
        }
    }
}

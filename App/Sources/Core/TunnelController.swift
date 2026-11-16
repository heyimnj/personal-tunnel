import Foundation
import NetworkExtension
import TunnelCore
import UIKit

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
    /// 3.3 (PT-08): the VPN did not start even on the second try: why. Shown as
    /// «VPN не запущен, трафик не защищён», once.
    let unprotected = Observable<String?>(nil)
    /// Starts tried again after a failure since the last one asked for (at most one).
    private var retries = 0

    private var manager: NETunnelProviderManager?
    private var observers: [NSObjectProtocol] = []
    /// A start was asked for and the system has not reported the tunnel coming up
    /// yet (3.0.6): until then a «disconnected» read is the status before the start,
    /// not its end, and the button keeps showing the connection.
    private var startPending: Date?
    /// The app asked for a start that has not reached «connected» yet.
    private var startRequested = false
    private var reloading = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let connection = note.object as? NEVPNConnection else { return }
            if connection === self.manager?.connection {
                self.sync()
            } else if connection is NETunnelProviderSession {
                // 3.0.6: after an update (or a configuration saved elsewhere) the
                // system hands out a new connection object, and its news used to be
                // dropped: the tunnel ran while the app showed it off, and the next
                // press stopped it. The configuration is read again instead.
                self.reread()
            }
        })
        // Whatever happened while the app was away is read again on return.
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reread()
        })
        load { _ in }
    }

    /// Reads the system's configuration again (once at a time).
    private func reread() {
        guard !reloading else { return }
        reloading = true
        load { [weak self] _ in self?.reloading = false }
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
        var next: TunnelState
        switch status {
        case .connected: next = .connected
        case .connecting: next = .connecting
        case .disconnecting: next = .disconnecting
        case .reasserting: next = .reasserting
        default: next = .disconnected
        }
        if let pending = startPending {
            if next != .disconnected {
                // The system answered the start: from here its status is the truth.
                startPending = nil
            } else if Date().timeIntervalSince(pending) < TunnelController.startGrace {
                // Not up yet: a status read before the start reached the system.
                next = .connecting
            } else {
                startPending = nil
            }
        }
        if next.isOn {
            if connectedSince.value == nil { connectedSince.value = manager?.connection.connectedDate ?? Date() }
        } else if next == .disconnected, connectedSince.value != nil {
            connectedSince.value = nil
        }
        // 3.1.7: a failed start goes «connecting» → «disconnecting» → «disconnected»;
        // its error was only read from the first two and never shown.
        if next == .connected {
            startRequested = false
            retries = 0
        }
        if next == .disconnected, state.value != .disconnected {
            if let message = AppGroup.defaults.string(forKey: SharedKey.lastTunnelError), !message.isEmpty {
                AppGroup.defaults.removeObject(forKey: SharedKey.lastTunnelError)
                // 3.3 (PT-08): one more try, then a warning that cannot be missed;
                // On Demand is turned off only then (iOS would retry over and over, 3.1.11).
                if !retryOnce() { failed(TunnelText.localize(message)) }
            } else if startRequested, AppGroup.defaults.double(forKey: SharedKey.tunnelStartedAt) == 0 {
                // 3.1.14: the extension never ran (nothing written, no crash to
                // report): the system says why, e.g. the extension is not signed
                // for the VPN or cannot be found. PTBeta went «connecting» → «not
                // connected» with nothing shown at all.
                manager?.connection.fetchLastDisconnectError { [weak self] error in
                    guard let error else { return }
                    var text = Redactor.redact(error.localizedDescription)
                    // 3.1.15: the extension ran but could not write its error: the
                    // App Group of the build is not in the signature (PTBeta 5 had
                    // its own group, which the signing profile does not grant).
                    if AppGroup.containerURL == nil {
                        text += " " + Lf("Нет доступа к общей группе приложения (%@): проверьте подпись приложения и расширения.", AppGroup.identifier)
                    }
                    DispatchQueue.main.async {
                        guard let self, !self.retryOnce() else { return }
                        self.failed(Lf("VPN не запустился: %@", "\(text)"))
                    }
                }
            }
            startRequested = false
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
    /// `keepAlive`: the VPN is on by the owner's wish (being started, or running).
    private func configure(_ manager: NETunnelProviderManager, keepAlive: Bool) {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelController.providerIdentifier
        proto.serverAddress = TunnelController.appName
        // 3.1.6: the kill switch is the system's own: with «include all networks»
        // iOS sends nothing around the tunnel while it is not up. Push
        // notifications and the carrier's own services keep working.
        proto.includeAllNetworks = Prefs.killSwitch
        if #available(iOS 16.4, *) {
            proto.excludeAPNs = true
            proto.excludeCellularServices = true
        }
        proto.excludeLocalNetworks = Prefs.localNetwork
        proto.enforceRoutes = Prefs.secureDNS
        manager.protocolConfiguration = proto
        manager.localizedDescription = TunnelController.appName
        manager.isEnabled = true
        if keepAlive {
            // 3.1.11: while the VPN is on, iOS itself brings it back when the system
            // ends the extension (a night left on ended with «The system ended the
            // tunnel without stopping it» and no VPN in the morning). A stop from the
            // app turns this off first (`stop`); a stop in iOS Settings turns it off too.
            let any = NEOnDemandRuleConnect()
            any.interfaceTypeMatch = .any
            manager.onDemandRules = [any]
            manager.isOnDemandEnabled = true
        } else if Prefs.autoConnect {
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

    private func prepared(keepAlive: Bool, _ completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
        load { [weak self] existing in
            guard let self else { return }
            let manager = existing ?? NETunnelProviderManager()
            self.configure(manager, keepAlive: keepAlive)
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

    /// The name iOS shows for the VPN (Settings → VPN): the app's own, so the beta
    /// («PTBeta») and Personal Tunnel can be told apart.
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Personal Tunnel"
    }

    /// How long a start may take to show up in the system's status (seconds).
    private static let startGrace: TimeInterval = 10

    func start(config: String) {
        retries = 0
        // 3.1.8: an error from an earlier start that was never shown (3.1.6 lost
        // them all) would come up as this start's; only a new one counts.
        AppGroup.defaults.removeObject(forKey: SharedKey.lastTunnelError)
        startRequested = true
        state.set(.connecting)
        startPending = Date()
        load { [weak self] existing in
            guard let self else { return }
            // 3.0.6: the app may have lost the tunnel's status (see `init`). A tunnel
            // that is already up or coming up is kept: saving the configuration under
            // it would stop it.
            switch existing?.connection.status {
            case .connected?, .connecting?, .reasserting?:
                self.startPending = nil
                self.sync()
                return
            default: break
            }
            self.prepared(keepAlive: true) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.startPending = nil
                    self.lastError.value = error.localizedDescription
                    self.sync()
                case let .success(manager):
                    do {
                        try manager.connection.startVPNTunnel(options: [TunnelIPC.configOption: config as NSString])
                    } catch {
                        self.startPending = nil
                        self.lastError.value = error.localizedDescription
                    }
                    // The wait counts from the start itself, not from the save before it.
                    if self.startPending != nil { self.startPending = Date() }
                    self.sync()
                    self.recheckStart()
                }
            }
        }
    }

    /// Reads the status again while a start is pending, in case its news is lost;
    /// the last read comes after `startGrace` and ends the wait either way.
    private func recheckStart() {
        for delay in [1, 3, 6, TunnelController.startGrace + 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.startPending != nil else { return }
                self.sync()
            }
        }
    }

    func stop() {
        startPending = nil
        guard let manager else { sync(); return }
        // Otherwise on-demand brings the tunnel straight back.
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            manager.saveToPreferences { _ in manager.connection.stopVPNTunnel() }
        } else {
            manager.connection.stopVPNTunnel()
        }
    }

    /// «Удалить все данные» (3.2.1): the VPN is stopped and its configuration is
    /// removed from iOS Settings; the next connection adds it again.
    func removeConfiguration(_ done: @escaping () -> Void) {
        startPending = nil
        startRequested = false
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            let group = DispatchGroup()
            for manager in managers ?? [] {
                group.enter()
                manager.isOnDemandEnabled = false
                manager.connection.stopVPNTunnel()
                manager.removeFromPreferences { _ in group.leave() }
            }
            group.notify(queue: .main) {
                guard let self else { done(); return }
                self.manager = nil
                self.sync()
                done()
            }
        }
    }

    /// 3.3 (PT-08): a failed start is tried once more with the stored
    /// configuration, two seconds later. False when it was tried already.
    private func retryOnce() -> Bool {
        guard retries == 0, let manager else { return false }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.state.value == .disconnected else { return }
            self.startPending = Date()
            self.state.set(.connecting)
            do {
                try manager.connection.startVPNTunnel()
            } catch {
                self.startPending = nil
                self.failed(error.localizedDescription)
            }
            self.recheckStart()
        }
        return true
    }

    /// The start failed for good: On Demand off, and the owner is told the
    /// traffic is not protected.
    private func failed(_ reason: String) {
        retries = 0
        disableOnDemand()
        unprotected.value = reason
    }

    /// Turns off the system's reconnection without stopping anything.
    private func disableOnDemand() {
        guard let manager, manager.isOnDemandEnabled else { return }
        manager.isOnDemandEnabled = false
        manager.saveToPreferences { _ in }
    }

    /// Applies changed routing switches to the stored configuration.
    func applySettings() {
        guard manager != nil else { return }
        let state = self.state.value
        prepared(keepAlive: state.isOn || state == .connecting) { _ in }
    }

    /// Asks the running tunnel to load the stored configuration again.
    /// `completion(nil)` only when the extension answered that the new
    /// configuration runs (3.3 beta 3); otherwise the reason. No answer within 10
    /// seconds counts as a failure.
    func reload(_ completion: @escaping (String?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession, state.value.isOn else {
            completion(L("туннель не готов к перезагрузке"))
            return
        }
        var answered = false
        let finish = { (result: String?) in
            guard !answered else { return }
            answered = true
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(L("расширение не ответило за 10 с")) }
        do {
            try session.sendProviderMessage(Data(TunnelIPC.reloadMessage.utf8)) { response in
                let text = response.flatMap { String(data: $0, encoding: .utf8) }
                DispatchQueue.main.async {
                    if text == TunnelIPC.reloadDone {
                        finish(nil)
                    } else {
                        finish(text.map(TunnelText.localize) ?? L("расширение не ответило"))
                    }
                }
            }
        } catch {
            finish(error.localizedDescription)
        }
    }
}

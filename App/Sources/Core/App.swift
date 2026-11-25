import Foundation
import TunnelCore
import UIKit

/// The app's services and the actions screens call. Both interface styles use
/// this and nothing else to reach the core.
final class App {
    static let shared = App()

    let paths: SharedPaths?
    let store: LibraryStore
    let tunnel = TunnelController()
    let core = CoreClient()
    let latency = LatencyService()
    /// 3.5: whether traffic really goes through the connected server.
    lazy var health = ConnectionHealth(tunnel: tunnel)
    /// Subscriptions being refreshed right now.
    let refreshing = Observable<Set<Int64>>([])
    /// A short message for the user (errors, results of actions).
    let notice = Observable<String?>(nil)
    /// 3.3 beta 3: the order of servers or subscriptions changed because of the
    /// connection (a server rose or went back, a subscription rose).
    let orderChanged = Signal()
    private var lastLifted: String?
    /// 3.2.2: an update of the connected subscription changed the server the tunnel
    /// runs: «Конфиг сервера обновлён — переподключиться?» is offered at the top.
    /// The core is not restarted on its own: a call or a download would be cut.
    let serverUpdateOffered = Observable(false)
    /// What the running tunnel was given (`ConfigBuilder.runningFingerprint`).
    private var runningServers: String?
    /// The update on offer, and the one the owner put off: not offered again.
    private var offeredServers: String?
    private var declinedServers: String?

    /// The server the VPN is connected (or connecting) to: it rises in its
    /// subscription's list under the pinned ones, and goes back when the VPN is off.
    var liftedServer: String? {
        // 3.3 beta 4: it stays up while the VPN restarts on another server (stopping,
        // the beat before the start, starting): it went back and rose again in
        // that time, and the list jerked.
        guard tunnel.state.value != .disconnected || reconnecting, let subscription = library.activeSubscription,
              let node = library.selectedNodeID(in: subscription) else { return nil }
        return Arrangement.server(subscription.id, node)
    }

    /// Tells the lists when the connected server changed; a connected subscription
    /// rises for good (`Arrangement.raised`).
    private func connectionOrderChanged() {
        var changed = false
        let lifted = liftedServer
        if lifted != lastLifted {
            lastLifted = lifted
            changed = true
        }
        if tunnel.state.value == .connected, let subscription = library.activeSubscription {
            let key = Arrangement.subscription(subscription.id)
            var arrangement = Prefs.arrangement
            if arrangement.raised.first != key {
                arrangement.raise(key)
                Prefs.arrangement = arrangement
                changed = true
            }
        }
        if changed { orderChanged.fire() }
    }

    private init() {
        #if canImport(Darwin)
        paths = AppGroup.containerURL.map(SharedPaths.init)
        #else
        paths = nil
        #endif
        // 3.3 (PT-08): before the store marks this install as run.
        Prefs.seedKillSwitch(hasLegacyData: paths.map { FileManager.default.fileExists(atPath: $0.legacyDatabase.path) || FileManager.default.fileExists(atPath: $0.library.path) } ?? false)
        if let paths { LibraryStore.protectStoredData(paths) }
        store = LibraryStore(paths: paths)
        if let paths { CoreClient.setUp(paths: paths) }
        tunnel.state.observe(self) { [weak self] state in
            guard let self else { return }
            self.connectionOrderChanged()
            if self.refreshDueWhenSettled, state == .connected || state == .disconnected {
                self.refreshDueWhenSettled = false
                self.autoRefreshedAt = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + (state == .connected ? 1.5 : 0)) { [weak self] in self?.refreshDue() }
            }
            if self.refreshWhenSettled, state == .connected || state == .disconnected {
                self.refreshWhenSettled = false
                // A moment for the tunnel's routes to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + (state == .connected ? 1.5 : 0)) { [weak self] in self?.refreshAll(automatic: true) }
            }
            if state == .connected {
                // A tunnel the app did not start itself (On Demand, a launch with
                // the VPN on) runs the stored configuration.
                if self.runningServers == nil { self.runningServers = self.activeFingerprint() }
                self.core.start()
                self.retryAfterConnecting()
            } else if state == .disconnected {
                self.core.stop()
                self.latency.cancel()
                if !self.reconnecting {
                    self.runningServers = nil
                    self.withdrawServerUpdate()
                }
                if self.reconnecting {
                    // A beat for the system to release the old session. Still
                    // «reconnecting» until then: the connected server keeps its place.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, self.reconnecting else { return }
                        self.connect()
                        self.connectionOrderChanged()
                    }
                }
            }
        }
        tunnel.loaded.observe(self, fireNow: false) { [weak self] loaded in
            // The first automatic ping waits for the real tunnel state: with the VPN
            // up, the app's own core would measure through the tunnel.
            guard loaded, let self else { return }
            // 3.1.2: a new build may read subscriptions better (what a server is
            // made of is decided when it is imported): every subscription is
            // fetched again once after an update. 3.3 beta 4: and at every launch
            // while «Автообновление подписок» is on (the owner's choice).
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let newBuild = Prefs.refreshedForBuild != build
            Prefs.refreshedForBuild = build
            // 3.2.10: otherwise only the subscriptions that are due (every 24 hours,
            // or once a day after the chosen hour), not all of them at every launch.
            if newBuild, self.refreshAutomatically() { return }
            if self.refreshDue() { return }
            self.autoPing()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.core.setInBackground(false)
            self?.returnedToApp()
        }
        // 3.2.9: no status stream from the extension while nobody looks at it.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.core.setInBackground(true)
        }
        startAutoRefreshClock()
        tunnel.lastError.observe(self, fireNow: false) { [weak self] message in
            if let message { self?.notice.value = message }
        }
        if paths == nil {
            notice.value = Lf("Нет доступа к общей группе приложения (%@). Туннель не запустится: проверьте подпись.", "\(AppGroup.identifier)")
        }
    }

    var library: Library { store.library.value }

    // MARK: Connection

    func toggleConnection() {
        Haptics.tap()
        switch tunnel.state.value {
        case .disconnected:
            connect()
        default:
            reconnecting = false
            latency.cancel()
            tunnel.stop()
        }
    }

    /// The launch after an update found the VPN coming up or going down: the
    /// subscriptions are fetched once it has settled.
    private var refreshWhenSettled = false

    // MARK: Automatic subscription updates (3.3 beta 4)

    /// When subscriptions were last fetched on their own.
    private var autoRefreshedAt: Date?
    private var autoRefreshTimer: Timer?
    /// A return to the app sooner than this after the last automatic update does
    /// not fetch again (switching between apps).
    static let autoRefreshPause: TimeInterval = 5 * 60
    /// Each subscription is fetched again when its last update is this old, also
    /// while the app stays open.
    static let autoRefreshAge: TimeInterval = 24 * 60 * 60

    /// Every remote subscription is fetched, quietly (failures go to the service
    /// log), not while the VPN is coming up or going down: those downloads
    /// started on one network and timed out on the other. False: nothing to fetch.
    @discardableResult
    private func refreshAutomatically() -> Bool {
        guard library.subscriptions.contains(where: \.isRemote) else { return false }
        autoRefreshedAt = Date()
        if tunnel.state.value.isBusy {
            refreshWhenSettled = true
        } else {
            refreshAll(automatic: true)
        }
        return true
    }

    /// Back in the app: the subscriptions that are due (3.2.10: not every one at
    /// every return any more).
    private func returnedToApp() {
        guard tunnel.loaded.value else { return }
        refreshDue()
    }

    /// Subscriptions due by «Время обновления» (`SubscriptionSchedule`): at launch,
    /// on return to the app and every half hour while it is open. A failed update
    /// is tried again no sooner than 5 minutes later. False: nothing was due.
    @discardableResult
    private func refreshDue() -> Bool {
        guard Prefs.autoUpdateSubscriptions else { return false }
        if let last = autoRefreshedAt, Date().timeIntervalSince(last) < Self.autoRefreshPause { return false }
        let hour = Prefs.subscriptionUpdateHour
        let due = library.subscriptions.filter { $0.isRemote && SubscriptionSchedule.isDue(updatedAt: $0.updatedAt, hour: hour) }
        guard !due.isEmpty else { return false }
        autoRefreshedAt = Date()
        if tunnel.state.value.isBusy {
            // Not while the VPN is coming up or going down; once it has settled.
            refreshDueWhenSettled = true
            return true
        }
        for subscription in due { refresh(subscription.id, automatic: true) }
        return true
    }

    private var refreshDueWhenSettled = false

    private func refreshStale() { refreshDue() }

    private func startAutoRefreshClock() {
        autoRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refreshStale() }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    /// Set while the tunnel is stopped to come straight back with another server.
    private var reconnecting = false

    /// Stops the running tunnel and starts it again with the stored configuration:
    /// every connection, the core and Xray begin anew on the chosen server.
    func reconnect() {
        let state = tunnel.state.value
        guard state.isOn || state == .connecting else { return }
        reconnecting = true
        latency.cancel()
        tunnel.stop()
    }

    /// 3.3 (PT-07): another server (or the chosen one changed) with the VPN on:
    /// the running tunnel loads the new configuration (startOrReloadService)
    /// without going down, so nothing leaves around it in between. Only if that
    /// fails does it stop and start again as before. Call after writing the configuration.
    func switchServer() {
        guard tunnel.state.value.isOn else {
            reconnect()
            return
        }
        latency.cancel()
        let session = tunnel.connectedSince.value
        let target = activeFingerprint()
        withdrawServerUpdate()
        tunnel.reload { [weak self] error in
            guard let self else { return }
            guard let error else {
                self.runningServers = target
                self.core.note(L("Сервер сменён без перезапуска VPN."))
                return
            }
            // 3.3 beta 4: the tunnel has started again meanwhile (iOS brings it back
            // after a fall) with the stored configuration: already on this server.
            if self.tunnel.connectedSince.value != session, self.tunnel.state.value != .disconnected {
                self.core.note(Lf("Сервер не сменился без перезапуска (%@), но VPN уже запустился заново на нём.", error), level: 3)
                return
            }
            self.core.note(Lf("Сервер не сменился без перезапуска (%@): VPN перезапускается.", error), level: 3)
            self.reconnect()
        }
    }

    func connect() {
        reconnecting = false
        do {
            let config = try store.writeActiveConfig()
            runningServers = activeFingerprint()
            withdrawServerUpdate()
            tunnel.start(config: config)
        } catch {
            notice.value = error.localizedDescription
        }
    }

    /// Picks a server. With the VPN on (or coming up) the tunnel reconnects at once
    /// on the new server, so nothing keeps running on the previous one.
    func select(node: String, in subscription: Int64) {
        let current = library.activeSubscription
        let previousNode: String? = current.flatMap { library.selectedNodeID(in: $0) }
        let changed = current?.id != subscription || previousNode != node || Prefs.autoSelect
        latency.cancel()
        store.update { $0.select(node: node, in: subscription) }
        Prefs.autoSelect = false
        var arrangement = Prefs.arrangement
        arrangement.remember(Arrangement.server(subscription, node))
        Prefs.arrangement = arrangement
        guard tunnel.state.value.isOn || tunnel.state.value == .connecting else {
            _ = try? store.writeActiveConfig()
            return
        }
        do {
            try store.writeActiveConfig()
        } catch {
            notice.value = error.localizedDescription
            return
        }
        if changed { switchServer() }
        connectionOrderChanged()
    }

    /// 3.3 (PT-16): «Подробный журнал для диагностики» — the core logs at «info»
    /// (every connection) for 30 minutes, then goes back to «warn» by itself.
    func setDiagnosticLog(_ on: Bool) {
        Prefs.diagnosticLogUntil = on ? Date().addingTimeInterval(ConfigBuilder.diagnosticLogDuration) : nil
        reloadTunnel()
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + ConfigBuilder.diagnosticLogDuration + 1) { [weak self] in self?.endDiagnosticLogIfDue() }
        }
    }

    /// The half hour is over: the setting goes (the extension has switched the
    /// level itself if it was running).
    func endDiagnosticLogIfDue() {
        guard let until = Prefs.diagnosticLogUntil, until <= Date() else { return }
        Prefs.diagnosticLogUntil = nil
        reloadTunnel()
    }

    func reloadTunnel() {
        guard tunnel.state.value.isOn else { return }
        _ = try? store.writeActiveConfig()
        let target = activeFingerprint()
        // 3.3 beta 3: a reload that did not take effect leaves the old configuration
        // running; the tunnel is restarted then, as when the server changes.
        tunnel.reload { [weak self] error in
            guard let self else { return }
            guard let error else {
                // The latest stored configuration runs now, an update on offer included.
                self.runningServers = target
                self.withdrawServerUpdate()
                return
            }
            self.core.note(Lf("Настройки не применились без перезапуска (%@): VPN перезапускается.", error), level: 3)
            self.reconnect()
        }
    }

    /// Routing switches changed: rewrite the configuration and apply it.
    func networkSettingsChanged() {
        tunnel.applySettings()
        reloadTunnel()
    }

    // MARK: Subscriptions

    /// Adds what the import confirmation showed (PT-14). `sendsDeviceData`: the
    /// switch on that screen for a subscription address.
    func add(text: String, sendsDeviceData: Bool = Prefs.deviceDataForNewSubscriptions, completion: @escaping (String?) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", !trimmed.contains("\n") {
            Task { @MainActor in
                do {
                    // 3.3: a new subscription's panel gets an HWID of its own (HMAC with its host).
                    let probe = Subscription(id: 0, name: "", url: trimmed, hwidPerHost: true)
                    let device = try sendsDeviceData ? SubscriptionService.device(hwid: probe.hwid(device: DeviceIdentity.current())) : nil
                    let fetched = try await SubscriptionService.fetch(url: trimmed, device: device)
                    self.logImport(fetched, name: fetched.title ?? SubscriptionHeaders.fallbackName(url: trimmed))
                    self.store.update { library in
                        let id = library.allocateID()
                        library.subscriptions.append(Subscription(id: id, name: fetched.title ?? SubscriptionHeaders.fallbackName(url: trimmed), url: trimmed,
                                                                  nodes: fetched.nodes, updatedAt: Date(), info: fetched.info,
                                                                  sendsDeviceIdentity: sendsDeviceData, hwidPerHost: true))
                        if library.activeSubscriptionID == nil { library.activeSubscriptionID = id }
                    }
                    completion(App.joined(fetched.summary, CertificateCheck.summary(fetched.nodes)))
                } catch {
                    completion(error.localizedDescription)
                }
            }
            return
        }
        do {
            let result = try ContentImporter.parse(trimmed)
            let nodes = NodeAssembler.assemble(result.nodes)
            store.update { library in
                let id = library.allocateID()
                let name = result.suggestedName ?? nodes.first?.name ?? L("Серверы")
                library.subscriptions.append(Subscription(id: id, name: nodes.count == 1 ? name : Lf("Серверы (%@)", "\(nodes.count)"), nodes: nodes, updatedAt: Date()))
                if library.activeSubscriptionID == nil { library.activeSubscriptionID = id }
            }
            completion(App.joined(result.summary, CertificateCheck.summary(nodes)))
        } catch {
            completion(error.localizedDescription)
        }
    }

    /// Messages of an import, one after another (nil when there are none).
    static func joined(_ parts: String?...) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }

    /// A server typed in by hand: a subscription of its own, like a pasted link.
    func addManual(_ outbound: JSONValue, name: String) {
        let nodes = NodeAssembler.assemble([ParsedNode(name: name, outbound: outbound)])
        store.update { library in
            let id = library.allocateID()
            library.subscriptions.append(Subscription(id: id, name: name, nodes: nodes, updatedAt: Date()))
            if library.activeSubscriptionID == nil { library.activeSubscriptionID = id }
        }
        notice.value = Lf("Сервер «%@» добавлен.", name)
    }

    /// A server changed in the editor: same tag, new fields.
    func replace(node tag: String, in id: Int64, outbound: JSONValue, name: String) {
        store.update { library in
            guard var subscription = library.subscription(id), let index = subscription.nodes.firstIndex(where: { $0.id == tag }) else { return }
            var object = outbound
            object["tag"] = .string(tag)
            subscription.nodes[index].outbound = object
            subscription.nodes[index].members = []
            subscription.nodes[index].name = name
            // The provider's link no longer describes the server.
            subscription.nodes[index].link = nil
            library.replace(subscription)
        }
        // The server in use changed: the tunnel comes back on its new settings.
        if let active = library.activeSubscription, active.id == id {
            if library.selectedNodeID(in: active) == tag { _ = try? store.writeActiveConfig(); switchServer() } else { reloadTunnel() }
        }
    }

    /// 3.1.6: a server edited with what it is made of (a group's servers, an Xray
    /// server's outbounds) kept.
    func update(node tag: String, in id: Int64, outbound: JSONValue, members: [JSONValue], name: String) {
        store.update { library in
            guard var subscription = library.subscription(id), let index = subscription.nodes.firstIndex(where: { $0.id == tag }) else { return }
            var object = outbound
            object["tag"] = .string(tag)
            subscription.nodes[index].outbound = object
            subscription.nodes[index].members = members
            if !name.isEmpty { subscription.nodes[index].name = name }
            subscription.nodes[index].link = nil
            library.replace(subscription)
        }
        if let active = library.activeSubscription, active.id == id {
            if library.selectedNodeID(in: active) == tag { _ = try? store.writeActiveConfig(); switchServer() } else { reloadTunnel() }
        }
    }

    /// `attempt`: 1 for the quiet second try after a network error with the VPN on.
    /// `automatic`: not asked for (launch, return, a day old): its problems go to
    /// the service log, not on screen.
    func refresh(_ id: Int64, attempt: Int = 0, automatic: Bool = false) {
        guard let subscription = library.subscription(id), let url = subscription.url, !refreshing.value.contains(id) else { return }
        let say = { [weak self] (text: String, level: Int32) in
            guard let self else { return }
            if automatic { self.core.note(text, level: level) } else { self.notice.value = text }
        }
        refreshing.value.insert(id)
        Task { @MainActor in
            defer { self.refreshing.value.remove(id) }
            do {
                let device = try subscription.sendsDeviceIdentity ? SubscriptionService.device(hwid: subscription.hwid(device: DeviceIdentity.current())) : nil
                let fetched = try await SubscriptionService.fetch(url: url, device: device)
                self.logImport(fetched, name: subscription.name)
                let previous = self.library.activeSubscription?.id == id ? self.activeFingerprint() : nil
                self.store.update { library in
                    guard var current = library.subscription(id) else { return }
                    current.nodes = fetched.nodes
                    current.info = fetched.info
                    current.updatedAt = Date()
                    current.warnings = fetched.summary.map { [$0] } ?? []
                    library.replace(current)
                }
                if self.library.activeSubscription?.id == id { self.activeSubscriptionUpdated(previous: previous) }
                if let summary = App.joined(fetched.summary, CertificateCheck.summary(fetched.nodes)) { say(summary, 3) }
                if let updated = self.library.subscription(id) { self.autoPing(updated) }
            } catch let error as URLError where self.tunnel.state.value == .connecting {
                // 3.3 beta 4: the VPN is coming up under the download: again once it is up.
                self.retryThroughTunnel.insert(id)
                self.core.note(Lf("«%@»: сервер подписки не ответил (%@), пока VPN подключался: повтор после подключения.", subscription.name, error.localizedDescription), level: 4)
            } catch let error as URLError where self.tunnel.state.value.isOn && attempt == 0 {
                // 3.3 beta 4: the network changed under the download (the VPN came up
                // or was restarted): one more try a moment later, without a message.
                self.core.note(Lf("«%@»: сервер подписки не ответил (%@): ещё одна попытка.", subscription.name, error.localizedDescription), level: 4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh(id, attempt: 1, automatic: automatic) }
            } catch let error as URLError where !self.tunnel.state.value.isOn {
                // Without the VPN the subscription server may be out of reach (blocked
                // networks): try again through the tunnel once it is up.
                self.retryThroughTunnel.insert(id)
                // 3.2.1: an automatic update notes this as information: it is
                // expected on a network that blocks the panel, and taken care of.
                say(Lf("«%@»: сервер подписки не ответил (%@). Без VPN он может быть недоступен: подписка обновится сама после подключения.", subscription.name, error.localizedDescription), 4)
            } catch {
                // 3.2.5: with the device's data off, a panel's refusal most often asks
                // for exactly that: the way to turn it on is named.
                let hint = subscription.sendsDeviceIdentity ? "" : " " + L("Передача данных устройства для этой подписки выключена: многие панели без HWID не дают серверы. Включить: Конфиденциальность → «Передавать данные устройства провайдеру».")
                say("«\(subscription.name)»: \(error.localizedDescription)" + hint, 3)
            }
        }
    }

    // MARK: Updated servers of the running tunnel (3.2.2)

    /// What the tunnel would run with the stored servers and settings.
    private func activeFingerprint() -> String? {
        guard let subscription = library.activeSubscription else { return nil }
        return ConfigBuilder.runningFingerprint(subscription, selected: library.selectedNodeID(in: subscription), options: Prefs.tunnelOptions)
    }

    /// The connected subscription was updated. The new configuration is stored at
    /// once (the next connection takes it); the running core is left alone when
    /// the server it runs did not change (new names, other servers), and otherwise
    /// restarted only when the owner agrees (`applyServerUpdate`).
    private func activeSubscriptionUpdated(previous: String?) {
        let state = tunnel.state.value
        guard state.isOn || state == .connecting else {
            _ = try? store.writeActiveConfig()
            return
        }
        guard let now = activeFingerprint() else { return }
        if now == (runningServers ?? previous) {
            if offeredServers != nil { withdrawServerUpdate() }
            return
        }
        // Written for a start by the system (On Demand) or the next connection;
        // the running tunnel reads it only when it is reloaded.
        _ = try? store.writeActiveConfig()
        guard now != declinedServers, now != offeredServers else { return }
        core.note(L("Подписка обновлена: параметры текущего сервера изменились. Новые применятся после переподключения."), level: 4)
        offeredServers = now
        serverUpdateOffered.set(true)
    }

    /// «Переподключиться»: the tunnel loads the updated server.
    func applyServerUpdate() {
        withdrawServerUpdate()
        do {
            try store.writeActiveConfig()
        } catch {
            notice.value = error.localizedDescription
            return
        }
        switchServer()
    }

    /// «Позже»: this update is not offered again; the next connection takes it.
    func declineServerUpdate() {
        declinedServers = offeredServers
        withdrawServerUpdate()
    }

    private func withdrawServerUpdate() {
        offeredServers = nil
        if serverUpdateOffered.value { serverUpdateOffered.set(false) }
    }

    /// What the subscription served, and every server that was skipped with why
    /// (names only: never addresses or keys).
    private func logImport(_ fetched: SubscriptionService.Fetched, name: String) {
        core.note(Redactor.redact(Lf("Подписка «%@»: %@ (User-Agent %@), серверов %@, пропущено %@.", name, fetched.format, fetched.agent, "\(fetched.nodes.count)", "\(fetched.issues.count)")), level: 4)
        if fetched.added > 0 {
            core.note(Lf("Подписка «%@»: ещё %@ серверов есть только в обычном списке ссылок — добавлены.", name, "\(fetched.added)"), level: 4)
        }
        for issue in fetched.issues {
            core.note(Redactor.redact(Lf("Пропущен «%@»: %@", issue.name, issue.reason)), level: 3)
        }
    }

    /// Subscriptions whose download failed without the VPN; refreshed once it connects.
    private var retryThroughTunnel: Set<Int64> = []

    private func retryAfterConnecting() {
        let ids = retryThroughTunnel
        retryThroughTunnel = []
        guard !ids.isEmpty else { return }
        // A moment for the tunnel's routes to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            // 3.2.1: quietly; the first failure has already been reported.
            for id in ids { self?.refresh(id, automatic: true) }
        }
    }

    func refreshAll(automatic: Bool = false) {
        for subscription in library.subscriptions where subscription.isRemote { refresh(subscription.id, automatic: automatic) }
    }

    /// «Удалить все данные» (3.2.1): the VPN is stopped and its configuration
    /// removed, then subscriptions and servers, statistics, results, logs, crash
    /// reports and the HWID are erased. Interface and network settings stay.
    func eraseAllData(_ done: @escaping () -> Void) {
        reconnecting = false
        retryThroughTunnel = []
        latency.clearResults()
        tunnel.removeConfiguration { [weak self] in
            guard let self else { done(); return }
            self.core.stop()
            self.core.clearLogs()
            self.core.resetStatistics()
            DeviceIdentity.erase()
            Prefs.eraseServerData()
            let group = AppGroup.defaults
            for key in [SharedKey.lastTunnelError, SharedKey.tunnelStartedAt, SharedKey.tunnelMemory, SharedKey.diagnosticLogUntil] { group.removeObject(forKey: key) }
            // 3.3: a link the app copied may still be on the clipboard (two minutes at most).
            Clipboard.clearOwn()
            // A beat for the extension to finish writing its last lines before they go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.store.eraseAll {
                    self.tunnel.crash.value = nil
                    self.tunnel.lastError.value = nil
                    self.notice.value = L("Все данные удалены.")
                    done()
                }
            }
        }
    }

    func delete(subscription id: Int64) {
        let wasActive = library.activeSubscription?.id == id
        store.update { $0.remove(subscription: id) }
        if wasActive, tunnel.state.value.isOn { tunnel.stop() }
    }

    func delete(node tag: String, in id: Int64) {
        guard var subscription = library.subscription(id) else { return }
        subscription.nodes.removeAll { $0.id == tag }
        if subscription.nodes.isEmpty { delete(subscription: id); return }
        store.update { $0.replace(subscription) }
        if library.activeSubscription?.id == id { reloadTunnel() }
    }

    func rename(subscription id: Int64, to name: String) {
        store.update { library in
            guard var subscription = library.subscription(id), !name.isEmpty else { return }
            subscription.name = name
            library.replace(subscription)
        }
    }

    // MARK: Latency

    /// The subscription whose servers can be URL-tested: the one in the running tunnel.
    var tunnelSubscription: Int64? { tunnel.state.value == .connected ? library.activeSubscription?.id : nil }

    func ping(_ subscriptions: [Subscription]) {
        let items = subscriptions.flatMap { subscription in subscription.nodes.map { (subscription: subscription, node: $0) } }
        latency.test(items, tunnelSubscription: tunnelSubscription, tunnelUp: tunnel.state.value != .disconnected)
    }

    private var lastAutoPing: Date?

    /// «Автопинг»: every subscription when the app opens (at most every 3 minutes),
    /// one subscription after its update. A test already running is left alone.
    func autoPing(_ only: Subscription? = nil) {
        guard Prefs.autoPing, tunnel.loaded.value, !tunnel.state.value.isBusy, tunnel.state.value != .connecting,
              !latency.progress.value.running else { return }
        if only == nil {
            // 3.2.9: with the VPN on every test is a connection in the extension
            // (the kill switch's way out, or the tunnel itself): at most every
            // 10 minutes then, every 3 without it.
            let gap: TimeInterval = tunnel.state.value == .disconnected ? 180 : 600
            if let last = lastAutoPing, Date().timeIntervalSince(last) < gap { return }
            lastAutoPing = Date()
        }
        let subscriptions = only.map { [$0] } ?? library.subscriptions
        let withServers = subscriptions.filter { !$0.nodes.isEmpty }
        guard !withServers.isEmpty else { return }
        ping(withServers)
    }

    func ping(nodes: [(Subscription, ServerNode)]) {
        guard !nodes.isEmpty else { return }
        latency.test(nodes.map { (subscription: $0.0, node: $0.1) }, tunnelSubscription: tunnelSubscription, tunnelUp: tunnel.state.value != .disconnected)
    }

    /// One server's ping: joins a running test instead of stopping it.
    func ping(node: ServerNode, in subscription: Subscription) {
        latency.add([(subscription: subscription, node: node)], tunnelSubscription: tunnelSubscription, tunnelUp: tunnel.state.value != .disconnected)
    }
}

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let picker = UISelectionFeedbackGenerator()

    static func tap() { if Prefs.hapticsEnabled { light.impactOccurred() } }
    /// Wakes the haptic engine before a gesture that will tap (3.1.7): the first
    /// tap of a cold engine cost the main thread a few frames mid-swipe.
    static func prepare() {
        guard Prefs.hapticsEnabled else { return }
        light.prepare()
        softGenerator.prepare()
    }
    /// 3.5.14 (the owner): servers, subscriptions and the tab bar — lighter than
    /// the settings' `tap`, yet clearly felt (3.5.13's soft 0.3 was barely there).
    static func item() { if Prefs.hapticsEnabled { light.impactOccurred(intensity: 0.65) } }
    static func soft(_ intensity: CGFloat = 0.6) { if Prefs.hapticsEnabled { softGenerator.impactOccurred(intensity: intensity) } }
    static func selection() { if Prefs.hapticsEnabled { picker.selectionChanged() } }
    static func result(_ ok: Bool) {
        guard Prefs.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
    }
}

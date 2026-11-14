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
    /// Subscriptions being refreshed right now.
    let refreshing = Observable<Set<Int64>>([])
    /// A short message for the user (errors, results of actions).
    let notice = Observable<String?>(nil)

    private init() {
        #if canImport(Darwin)
        paths = AppGroup.containerURL.map(SharedPaths.init)
        #else
        paths = nil
        #endif
        store = LibraryStore(paths: paths)
        if let paths { CoreClient.setUp(paths: paths) }
        tunnel.state.observe(self) { [weak self] state in
            guard let self else { return }
            if state == .connected {
                self.core.start()
                self.retryAfterConnecting()
            } else if state == .disconnected {
                self.core.stop()
                self.latency.cancel()
                if self.reconnecting {
                    self.reconnecting = false
                    // A beat for the system to release the old session.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.connect() }
                }
            }
        }
        tunnel.loaded.observe(self, fireNow: false) { [weak self] loaded in
            // The first automatic ping waits for the real tunnel state: with the VPN
            // up, the app's own core would measure through the tunnel.
            guard loaded, let self else { return }
            // 3.1.2: a new build may read subscriptions better (what a server is
            // made of is decided when it is imported): every subscription is
            // fetched again once after an update.
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            if Prefs.refreshedForBuild != build {
                Prefs.refreshedForBuild = build
                if self.library.subscriptions.contains(where: \.isRemote) {
                    self.refreshAll()
                    return
                }
            }
            self.autoPing()
        }
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

    func connect() {
        do {
            let config = try store.writeActiveConfig()
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
        Haptics.selection()
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
        if changed { reconnect() }
    }

    func reloadTunnel() {
        guard tunnel.state.value.isOn else { return }
        _ = try? store.writeActiveConfig()
        tunnel.reload { [weak self] error in
            if let error, !error.isEmpty { self?.notice.value = error }
        }
    }

    /// Routing switches changed: rewrite the configuration and apply it.
    func networkSettingsChanged() {
        tunnel.applySettings()
        reloadTunnel()
    }

    // MARK: Subscriptions

    func add(text: String, completion: @escaping (String?) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", !trimmed.contains("\n") {
            Task { @MainActor in
                do {
                    let fetched = try await SubscriptionService.fetch(url: trimmed, sendIdentity: true)
                    self.logImport(fetched, name: fetched.title ?? SubscriptionHeaders.fallbackName(url: trimmed))
                    self.store.update { library in
                        let id = library.allocateID()
                        library.subscriptions.append(Subscription(id: id, name: fetched.title ?? SubscriptionHeaders.fallbackName(url: trimmed), url: trimmed,
                                                                  nodes: fetched.nodes, updatedAt: Date(), info: fetched.info))
                        if library.activeSubscriptionID == nil { library.activeSubscriptionID = id }
                    }
                    completion(fetched.summary)
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
            completion(result.summary)
        } catch {
            completion(error.localizedDescription)
        }
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
            if library.selectedNodeID(in: active) == tag { reconnect() } else { reloadTunnel() }
        }
    }

    func refresh(_ id: Int64) {
        guard let subscription = library.subscription(id), let url = subscription.url, !refreshing.value.contains(id) else { return }
        refreshing.value.insert(id)
        Task { @MainActor in
            defer { self.refreshing.value.remove(id) }
            do {
                let fetched = try await SubscriptionService.fetch(url: url, sendIdentity: subscription.sendsDeviceIdentity)
                self.logImport(fetched, name: subscription.name)
                self.store.update { library in
                    guard var current = library.subscription(id) else { return }
                    current.nodes = fetched.nodes
                    current.info = fetched.info
                    current.updatedAt = Date()
                    current.warnings = fetched.summary.map { [$0] } ?? []
                    library.replace(current)
                }
                if self.library.activeSubscription?.id == id { self.reloadTunnel() }
                if let summary = fetched.summary { self.notice.value = summary }
                if let updated = self.library.subscription(id) { self.autoPing(updated) }
            } catch let error as URLError where !self.tunnel.state.value.isOn {
                // Without the VPN the subscription server may be out of reach (blocked
                // networks): try again through the tunnel once it is up.
                self.retryThroughTunnel.insert(id)
                self.notice.value = Lf("«%@»: сервер подписки не ответил (%@). Без VPN он может быть недоступен: подписка обновится сама после подключения.", subscription.name, error.localizedDescription)
            } catch {
                self.notice.value = "«\(subscription.name)»: \(error.localizedDescription)"
            }
        }
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
            for id in ids { self?.refresh(id) }
        }
    }

    func refreshAll() {
        for subscription in library.subscriptions where subscription.isRemote { refresh(subscription.id) }
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
            if let last = lastAutoPing, Date().timeIntervalSince(last) < 180 { return }
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
    static func soft(_ intensity: CGFloat = 0.6) { if Prefs.hapticsEnabled { softGenerator.impactOccurred(intensity: intensity) } }
    static func selection() { if Prefs.hapticsEnabled { picker.selectionChanged() } }
    static func result(_ ok: Bool) {
        guard Prefs.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
    }
}

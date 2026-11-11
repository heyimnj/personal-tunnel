import Foundation
import TunnelCore

/// The user's subscriptions and servers. One file in the shared container,
/// written off the main thread; views observe `library`.
final class LibraryStore {
    let library: Observable<Library>
    let paths: SharedPaths?
    private let queue = DispatchQueue(label: "personaltunnel.library", qos: .utility)
    private var labelCache: [Int64: (stamp: Int, labels: [String: ServerLabels.Label])] = [:]

    init(paths: SharedPaths?) {
        self.paths = paths
        var loaded = Library()
        if let paths {
            try? paths.prepare()
            if let data = try? Data(contentsOf: paths.library), let value = try? JSONDecoder().decode(Library.self, from: data) {
                loaded = value
            } else if !Prefs.migratedFrom1x, let snapshot = LegacyDatabase.read(paths: paths) {
                loaded = LibraryStore.migrate(snapshot)
            }
        }
        Prefs.migratedFrom1x = true
        library = Observable(loaded)
        if paths != nil, !loaded.subscriptions.isEmpty { save() }
    }

    private static func migrate(_ snapshot: LegacyDatabase.Snapshot) -> Library {
        let prefs = snapshot.preferences
        let selected = LegacyMigration.decodeInt(prefs["selected_profile_id"])
        let tag = prefs["preferred_outbound_tag"].flatMap { String(data: $0, encoding: .utf8) }
        let library = LegacyMigration.library(from: snapshot.profiles, selectedProfileID: selected, preferredTag: tag)
        // Network switches lived in the database.
        func seed(_ key: String, _ apply: (Bool) -> Void) {
            if let value = LegacyMigration.decodeBool(prefs[key]) { apply(value) }
        }
        seed("ad_blocking_enabled") { Prefs.adBlocking = $0 }
        seed("bypass_russian_sites") { Prefs.bypassRussia = $0 }
        seed("exclude_local_networks") { Prefs.localNetwork = $0 }
        seed("enforce_routes") { Prefs.secureDNS = $0 }
        seed("unknown_wifi_connect") { Prefs.unknownWiFi = $0 }
        seed("auto_failover") { Prefs.autoFailover = $0 }
        seed("app_lock_enabled") { Prefs.appLock = $0 }
        let onDemand = LegacyMigration.decodeBool(prefs["on_demand_enabled"]) ?? false
        let alwaysOn = LegacyMigration.decodeBool(prefs["always_on"]) ?? false
        Prefs.autoConnect = onDemand || alwaysOn
        if let mode = prefs["connection_mode"].flatMap({ String(data: $0, encoding: .utf8) }) { Prefs.autoSelect = mode == "Авто" && tag?.isEmpty != false }
        return library
    }

    // MARK: Mutations

    func update(_ change: (inout Library) -> Void) {
        var copy = library.value
        change(&copy)
        guard copy != library.value else { return }
        library.value = copy
        save()
    }

    private func save() {
        guard let paths else { return }
        let snapshot = library.value
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: paths.library, options: .atomic)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: paths.library.path)
        }
    }

    /// List labels and flags of a subscription, cached until its servers change.
    func labels(for subscription: Subscription) -> [String: ServerLabels.Label] {
        var hasher = Hasher()
        for node in subscription.nodes { hasher.combine(node.id); hasher.combine(node.name) }
        let stamp = hasher.finalize()
        if let cached = labelCache[subscription.id], cached.stamp == stamp { return cached.labels }
        let labels = ServerLabels.make(for: subscription.nodes)
        labelCache[subscription.id] = (stamp, labels)
        return labels
    }

    func label(of node: ServerNode, in subscription: Subscription) -> ServerLabels.Label {
        labels(for: subscription)[node.id] ?? ServerLabels.Label(text: node.name, countryCode: nil)
    }

    /// Writes the configuration the tunnel should run. Returns its text.
    @discardableResult
    func writeActiveConfig() throws -> String {
        let current = library.value
        guard let subscription = current.activeSubscription else {
            throw ImportError(L("Сначала добавьте сервер или подписку."))
        }
        let config = try ConfigBuilder.build(subscription: subscription, selected: current.selectedNodeID(in: subscription), options: Prefs.tunnelOptions)
        let text = config.serialized()
        if let paths {
            try Data(text.utf8).write(to: paths.activeConfig, options: .atomic)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: paths.activeConfig.path)
        }
        return text
    }
}
